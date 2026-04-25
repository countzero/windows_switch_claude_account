#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-ListAction in switch_claude_account.ps1, including
# the hardlink self-check warning. Per-test sandbox setup lives in
# tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')
    }

    Context 'Invoke-ListAction' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
        }

        It 'prints the empty-directory message when no slots are saved' {
            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Match 'No slots saved yet'
        }

        It 'lists slot names and marks the active slot with *' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.bravo.json') -Value 'B' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                      -Value 'B' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            # Table-shape rows: leading ` ` (inactive) or `*` (active),
            # then the slot name. The `(active)` suffix is gone now —
            # the `*` marker plus row coloring is the single source of
            # truth, matching the usage table.
            $out | Should -Match '(?m)^\s+alpha\s'
            $out | Should -Match '(?m)^\s+\*\s+bravo\s'
            $out | Should -Not -Match '\(active\)'
            # Header row present with both column labels.
            $out | Should -Match 'Slot'
            $out | Should -Match 'Account'
        }

        It 'lists slots without * when no active file exists' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+alpha\s'
            $out | Should -Not -Match '\(active\)'
            # No row carries a `*` marker when no active file exists.
            $out | Should -Not -Match '(?m)^\s+\*\s+\w'
        }

        It 'excludes .credentials.json itself from the slot listing' {
            Set-Content -LiteralPath $script:CredFilePath                                      -Value 'X' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.work.json') -Value 'W' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match 'work'
            # If the Where-Object filter in Get-Slots ever regresses,
            # .credentials.json itself leaks as a slot whose rendered name is
            # the literal '.credentials'. Anchor to the list-row shape
            # (leading ' * ' or '   ' indent) so this assertion catches the
            # leak without false-positiving on legitimate slot names.
            $out | Should -Not -Match '(?m)^\s*\*?\s+\.credentials(\s|$)'
        }

        # Email column rendering: parallels the Invoke-UsageAction email
        # rendering tests below. The list table now carries the email
        # inline in an Account column instead of the old `└─ <email>`
        # continuation line.
        It 'renders the email in the Account column when slot is labeled' {
            $labeled = '.credentials.work(finn.kumkar@stadtwerk.org).json'
            Set-Content -LiteralPath (Join-Path $script:CredDirPath $labeled) -Value 'X' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            # Slot name and email on the same row; no '└─' continuation.
            $out | Should -Match '(?m)^\s+work\s+finn\.kumkar@stadtwerk\.org\b'
            $out | Should -Not -Match '└─'
        }

        It "renders '-' in the Account column when slot name equals the embedded email (dedup form)" {
            $email = 'alice@example.com'
            Set-Content -LiteralPath (Join-Path $script:CredDirPath ".credentials.$email.json") -Value 'X' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            # The whole-email slot name appears, then the em-dash sentinel
            # in place of a redundant Account cell.
            $out | Should -Match "(?m)^\s+$([regex]::Escape($email))\s+—\s*$"
            $out | Should -Not -Match '└─'
        }

        It "renders '-' in the Account column for unlabeled slot" {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.pending.json') -Value 'X' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+pending\s+—\s*$'
            $out | Should -Not -Match '└─'
        }

        It 'middle-truncates long emails in the Account column' {
            $longEmail = 'extremely.long.local.part@extraordinarily-long-domain.example.com'
            $longEmail.Length | Should -BeGreaterThan $Script:AccountColumnMaxWidth

            $labeled = ".credentials.longslot($longEmail).json"
            Set-Content -LiteralPath (Join-Path $script:CredDirPath $labeled) -Value 'X' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match '…'
            $out | Should -Not -Match ([regex]::Escape($longEmail))
        }
    }

    Context 'Invoke-ListAction (hardlink self-check)' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
        }

        It 'no warning when .credentials.json is a hardlink to the active slot' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.bravo.json') -Value 'B' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                      -Value 'B' -NoNewline

            # Establish hardlink
            Remove-Item -LiteralPath $script:CredFilePath -Force
            New-Item -ItemType HardLink -Path $script:CredFilePath -Target (Join-Path $script:CredDirPath '.credentials.bravo.json') | Out-Null

            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Not -Match 'Warning'
        }

        It 'warns when .credentials.json is a regular file that matches a slot' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.bravo.json') -Value 'B' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                      -Value 'B' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Match 'Warning'
            $out | Should -Match 'bravo'
        }

        It 'warns when .credentials.json is a regular file that matches no slot' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                      -Value 'UNKNOWN' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Match 'Warning'
            # The "no slot" warning says "not hardlinked to any slot" — no specific name.
            $out | Should -Match 'not hardlinked to any slot'
        }

        It 'no warning when no .credentials.json exists' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Not -Match 'Warning'
        }

        It 'no warning when no slots saved (early return)' {
            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Not -Match 'Warning'
        }
    }

    AfterAll {
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
