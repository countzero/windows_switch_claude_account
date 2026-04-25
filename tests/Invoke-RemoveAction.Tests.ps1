#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-RemoveAction in switch_claude_account.ps1,
# including its hardlink behavior. Per-test sandbox setup lives in
# tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')
    }

    Context 'Invoke-RemoveAction' {
        It 'deletes the slot file' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot    = Join-Path $credDir '.credentials.work.json'
            Set-Content -LiteralPath $slot -Value 'X' -NoNewline

            Invoke-RemoveAction -Name 'work' 6>$null

            Test-Path -LiteralPath $slot | Should -BeFalse
        }

        # Regression for the filename-encoded-email feature: remove must
        # work by slot-name alone regardless of whether the on-disk file
        # uses the labeled `.credentials.<slot>(<email>).json` form or
        # the unlabeled `.credentials.<slot>.json` form.
        It 'removes a labeled slot file by slot-name argument' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $labeled = Join-Path $credDir '.credentials.work(alice@example.com).json'
            Set-Content -LiteralPath $labeled -Value 'X' -NoNewline

            Invoke-RemoveAction -Name 'work' 6>$null

            Test-Path -LiteralPath $labeled | Should -BeFalse
        }

        It 'throws when the slot does not exist' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null

            { Invoke-RemoveAction -Name 'missing' 6>$null } | Should -Throw -ExpectedMessage "*Slot 'missing' not found*"
        }

        It 'sanitizes the name before deletion' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot    = Join-Path $credDir '.credentials.my_work.json'
            Set-Content -LiteralPath $slot -Value 'X' -NoNewline

            Invoke-RemoveAction -Name 'my work' 6>$null

            Test-Path -LiteralPath $slot | Should -BeFalse
        }

        # Regression: a user typing `sca remove foo[bar]` must NOT cause
        # wildcard expansion of `foo[bar]` into a character class that
        # matches unrelated slot files (fooa, foob, foor). Get-SafeName
        # sanitizes brackets to _ so the user-facing name becomes
        # foo_bar_; the lookup then misses and throws. The key assertions
        # are that the unrelated slots survive and the throw message
        # references the sanitized name.
        It 'user-supplied bracket name is sanitized and does not wildcard-delete sibling slots' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.fooa.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.foob.json') -Value 'B' -NoNewline

            { Invoke-RemoveAction -Name 'foo[bar]' 6>$null } |
                Should -Throw -ExpectedMessage "*Slot 'foo_bar_' not found*"

            Test-Path -LiteralPath (Join-Path $credDir '.credentials.fooa.json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $credDir '.credentials.foob.json') | Should -BeTrue
        }
    }

    Context 'Invoke-RemoveAction (hardlink)' {
        It 'removing the active slot leaves .credentials.json intact as a regular file' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            $slot     = Join-Path $credDir '.credentials.work.json'
            Set-Content -LiteralPath $credFile -Value 'DATA' -NoNewline
            Set-Content -LiteralPath $slot     -Value 'DATA' -NoNewline

            # Establish the hardlink (simulate a prior switch)
            Remove-Item -LiteralPath $credFile -Force
            New-Item -ItemType HardLink -Path $credFile -Target $slot | Out-Null
            (Get-Item -LiteralPath $credFile).LinkType | Should -Be 'HardLink'

            Invoke-RemoveAction -Name 'work' 6>$null

            Test-Path -LiteralPath $slot | Should -BeFalse
            Test-Path -LiteralPath $credFile | Should -BeTrue
            Get-Content -LiteralPath $credFile -Raw | Should -Be 'DATA'
            (Get-Item -LiteralPath $credFile).LinkType | Should -Not -Be 'HardLink'
        }
    }

    AfterAll {
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
