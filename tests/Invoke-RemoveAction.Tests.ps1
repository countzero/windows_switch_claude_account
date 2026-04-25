#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-RemoveAction in switch_claude_account.ps1.
# After the state-file redesign Invoke-RemoveAction refuses to remove
# the currently-tracked active slot (the user must `sca switch` first)
# and there is no longer any hardlink involvement to verify. Per-test
# sandbox setup lives in tests/Common.ps1.

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

    Context 'Invoke-RemoveAction (state file)' {
        # Refusing to remove the active slot forces the user to switch
        # away first. Without this guard, the user could delete the slot
        # whose tokens .credentials.json depends on, leaving the script
        # with a state file pointing at a now-missing slot.
        It 'refuses to remove the slot tracked as active in state' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.work.json')  -Value 'W' -NoNewline
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.other.json') -Value 'O' -NoNewline
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'X' | Out-Null

            { Invoke-RemoveAction -Name 'work' 6>$null } |
                Should -Throw -ExpectedMessage "*Cannot remove active slot 'work'*"

            # Slot file untouched.
            Test-Path -LiteralPath (Join-Path $credDir '.credentials.work.json') | Should -BeTrue
        }

        It 'removes a non-active slot without disturbing state.active_slot' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.work.json')  -Value 'W' -NoNewline
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.other.json') -Value 'O' -NoNewline
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'X' | Out-Null

            Invoke-RemoveAction -Name 'other' 6>$null

            Test-Path -LiteralPath (Join-Path $credDir '.credentials.other.json') | Should -BeFalse
            (Read-ScaState).active_slot | Should -Be 'work'
        }
    }

    AfterAll {
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
