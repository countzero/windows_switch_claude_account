#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-ListAction in switch_claude_account.ps1.
# After the state-file redesign Invoke-ListAction is a pure offline
# render: no network, no hashing, no hardlink self-check. The active
# marker `*` is sourced from .sca-state.json (with one-time hash-based
# migration on first call). Per-test sandbox setup lives in tests/Common.ps1.

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
            $labeled = '.credentials.work(ada.lovelace@arpa.net).json'
            Set-Content -LiteralPath (Join-Path $script:CredDirPath $labeled) -Value 'X' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            # Slot name and email on the same row; no '└─' continuation.
            $out | Should -Match '(?m)^\s+work\s+ada\.lovelace@arpa\.net\b'
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

    Context 'Invoke-ListAction (state file)' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
        }

        # The hardlink-broken / ActiveLocked / "not hardlinked to any
        # slot" advisories are gone with the rest of the hardlink
        # mechanism. List is now a pure offline render: NO advisories
        # under any state. The pending-state cases the old advisories
        # warned about are now handled silently by reconcile next time
        # the user runs `sca usage` or `sca switch`.

        It 'no advisory output ever, regardless of .credentials.json state' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.bravo.json') -Value 'B' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                      -Value 'UNKNOWN' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Not -Match 'Warning'
            $out | Should -Not -Match 'not hardlinked'
            $out | Should -Not -Match 'auto-sync'
        }

        # Active marker comes from the state file when it exists.
        It 'IsActive marker reflects state.active_slot' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.bravo.json') -Value 'B' -NoNewline

            Update-ScaState -ActiveSlot 'alpha' -LastSyncHash 'X' | Out-Null

            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+\*\s+alpha\s'
            $out | Should -Not -Match '(?m)^\s+\*\s+bravo\s'
        }

        # Auto-migration on first call (no state file): hash-match
        # .credentials.json against existing slot files and seed state
        # transparently. This keeps `sca list` correct after upgrading
        # from the previous hardlink-based version.
        It 'auto-migrates state on first call by hash-matching .credentials.json' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.bravo.json') -Value 'B' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                      -Value 'B' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            # Migration silently identifies bravo as active.
            $out | Should -Match '(?m)^\s+\*\s+bravo\s'
            # And persists for fast subsequent reads.
            (Read-ScaState).active_slot | Should -Be 'bravo'
        }

        # No content-hash to compute when no .credentials.json exists.
        # state.active_slot stays whatever it was (maybe null on a fresh
        # install with no prior saves). Either way, no advisory.
        It 'list works without .credentials.json (no active marker; no advisory)' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+alpha\s'
            $out | Should -Not -Match '(?m)^\s+\*\s+\w'
            $out | Should -Not -Match 'Warning'
        }
    }

    AfterAll {
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
