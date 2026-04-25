#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-Reconcile in switch_claude_account.ps1.
#
# Reconcile is the heart of the new robust active-slot tracking model: on
# every credentials-touching action it brings the saved slot file in line
# with .credentials.json (which Claude Code may have rewritten via an
# atomic-rename refresh since the last sca call). The tests below exercise
# all four documented outcomes plus the offline-tolerance and missing-slot
# fallbacks. Per-test sandbox setup lives in tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')

        $script:CD = Join-Path $script:SandboxHome '.claude'
        New-Item -ItemType Directory -Path $script:CD -Force | Out-Null

        # An OAuth-shaped credentials body. The exact tokens are irrelevant
        # because Get-SlotProfile is stubbed at the HTTP layer; the JSON
        # only needs to be parseable by Get-SlotOAuth so the function gets
        # past the HasOAuth guard.
        $script:CredsBody = '{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"sk-ant-ort-x","expiresAt":9999999999999}}'
    }

    # ----- noop branches -------------------------------------------------

    Context 'Invoke-Reconcile (noop)' {
        It 'returns noop when .credentials.json is missing' {
            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'noop'
            $r.Reason | Should -Be 'no-active-credentials'

            # No state file should have been written by a noop.
            Test-Path -LiteralPath $StateFile | Should -BeFalse
        }

        It 'returns noop when hash matches state.last_sync_hash' {
            $credFile = Join-Path $script:CD '.credentials.json'
            $slotFile = Join-Path $script:CD '.credentials.work.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline
            Set-Content -LiteralPath $slotFile -Value $script:CredsBody -NoNewline

            # Seed state with the current hash (matching .credentials.json).
            $hash = (Get-FileHash -LiteralPath $credFile -Algorithm SHA256).Hash
            Update-ScaState -ActiveSlot 'work' -LastSyncHash $hash | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'noop'
            $r.Reason | Should -Be 'hash-match'
        }
    }

    # ----- mirror branch -------------------------------------------------

    Context 'Invoke-Reconcile (mirror)' {
        It 'mirrors .credentials.json into the tracked slot when emails match' {
            $credFile = Join-Path $script:CD '.credentials.json'
            $slotFile = Join-Path $script:CD '.credentials.work(alice@example.com).json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody     -NoNewline
            Set-Content -LiteralPath $slotFile -Value 'STALE_OLD_CONTENT'   -NoNewline

            # Seed state pointing at the slot, with a stale hash so the
            # noop fast-path doesn't fire.
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE_HASH' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{ account = [pscustomobject]@{ email = 'alice@example.com' } }
            }

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'mirror'
            $r.Slot   | Should -Be 'work'

            # Slot file now byte-equal to .credentials.json.
            Get-Content -LiteralPath $slotFile -Raw | Should -Be $script:CredsBody

            # state.last_sync_hash updated to the current hash.
            $expectedHash = (Get-FileHash -LiteralPath $credFile -Algorithm SHA256).Hash
            (Read-ScaState).last_sync_hash | Should -Be $expectedHash
        }

        # Offline tolerance: profile fetch failure is treated as "unknown
        # new identity" and falls into the mirror branch rather than
        # triggering an over-eager auto-save. Documented in the function
        # header. The default Common.ps1 mock makes Get-SlotProfile fail.
        It 'mirrors when profile fetch fails (offline / no-oauth tolerance)' {
            $credFile = Join-Path $script:CD '.credentials.json'
            $slotFile = Join-Path $script:CD '.credentials.work(alice@example.com).json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody   -NoNewline
            Set-Content -LiteralPath $slotFile -Value 'STALE'             -NoNewline

            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE' | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'mirror'
            $r.Slot   | Should -Be 'work'

            Get-Content -LiteralPath $slotFile -Raw | Should -Be $script:CredsBody
        }

        It 'mirrors when the slot is unlabeled (no embedded email)' {
            $credFile = Join-Path $script:CD '.credentials.json'
            $slotFile = Join-Path $script:CD '.credentials.work.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline
            Set-Content -LiteralPath $slotFile -Value 'STALE'           -NoNewline

            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{ account = [pscustomobject]@{ email = 'someone@example.com' } }
            }

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'mirror'
            Get-Content -LiteralPath $slotFile -Raw | Should -Be $script:CredsBody
        }
    }

    # ----- identity-change branch ----------------------------------------

    Context 'Invoke-Reconcile (identity-change)' {
        It 'auto-saves under a new name when emails differ; preserves previous slot' {
            $credFile = Join-Path $script:CD '.credentials.json'
            $slotFile = Join-Path $script:CD '.credentials.work(alice@example.com).json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody  -NoNewline
            Set-Content -LiteralPath $slotFile -Value 'OLD_ALICE_TOKENS' -NoNewline

            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{ account = [pscustomobject]@{ email = 'bob@example.com' } }
            }

            $r = Invoke-Reconcile 6>$null
            $r.Action       | Should -Be 'identity-change'
            $r.PreviousSlot | Should -Be 'work'
            $r.Email        | Should -Be 'bob@example.com'
            $r.Slot         | Should -Match '^auto-\d{8}T\d{6}Z$'

            # Original slot file (alice's tokens) preserved untouched.
            Get-Content -LiteralPath $slotFile -Raw | Should -Be 'OLD_ALICE_TOKENS'

            # New auto-save slot exists, labeled with bob's email.
            $autoPath = Join-Path $script:CD ".credentials.$($r.Slot)(bob@example.com).json"
            Test-Path -LiteralPath $autoPath | Should -BeTrue
            Get-Content -LiteralPath $autoPath -Raw | Should -Be $script:CredsBody

            # state.active_slot points at the new auto slot.
            (Read-ScaState).active_slot | Should -Be $r.Slot
        }
    }

    # ----- auto-save branch ----------------------------------------------

    Context 'Invoke-Reconcile (auto-save)' {
        It 'auto-saves when no state file exists and no slot hash matches' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{ account = [pscustomobject]@{ email = 'fresh@example.com' } }
            }

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'auto-save'
            $r.Email  | Should -Be 'fresh@example.com'
            $r.Slot   | Should -Match '^auto-\d{8}T\d{6}Z$'

            # Auto-saved slot file with labeled form.
            $autoPath = Join-Path $script:CD ".credentials.$($r.Slot)(fresh@example.com).json"
            Test-Path -LiteralPath $autoPath | Should -BeTrue
            Get-Content -LiteralPath $autoPath -Raw | Should -Be $script:CredsBody

            (Read-ScaState).active_slot | Should -Be $r.Slot
        }

        It 'auto-saves with unlabeled form when profile fetch fails (offline)' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'auto-save'
            $r.Email  | Should -BeNullOrEmpty

            $autoPath = Join-Path $script:CD ".credentials.$($r.Slot).json"
            Test-Path -LiteralPath $autoPath | Should -BeTrue
        }

        # state.active_slot was set on a previous run, but the slot file
        # has since been deleted (e.g. user manually rm'd it). Reconcile
        # must not crash; it falls through to auto-save so the new bytes
        # are still captured under a generated name.
        It 'auto-saves when state.active_slot points at a missing slot file' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            Update-ScaState -ActiveSlot 'gone-slot' -LastSyncHash 'STALE' | Out-Null

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'auto-save'
            $r.Slot   | Should -Match '^auto-\d{8}T\d{6}Z$'

            (Read-ScaState).active_slot | Should -Be $r.Slot
        }

        It 'prints a yellow advisory line for auto-save' {
            $credFile = Join-Path $script:CD '.credentials.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline

            $out = Invoke-Reconcile 6>&1 | Out-String
            $out | Should -Match '\[Sync\] Auto-saved unknown active credentials as'
        }

        It 'prints a yellow advisory line for identity-change' {
            $credFile = Join-Path $script:CD '.credentials.json'
            $slotFile = Join-Path $script:CD '.credentials.work(alice@example.com).json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline
            Set-Content -LiteralPath $slotFile -Value 'OLD'             -NoNewline

            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'STALE' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{ account = [pscustomobject]@{ email = 'bob@example.com' } }
            }

            $out = Invoke-Reconcile 6>&1 | Out-String
            $out | Should -Match "\[Sync\] Active credentials are now bob@example\.com"
            $out | Should -Match "previous slot 'work' \(alice@example\.com\) preserved"
        }
    }

    # ----- migration via Read-ScaState's hash-bootstrap ------------------

    Context 'Invoke-Reconcile (migration)' {
        # Read-ScaState auto-migrates by hash on first call when the state
        # file is missing. Reconcile sees the result as a normal state and
        # branches into noop because the hash matches what the migration
        # just wrote. Verifies migration -> noop integrates cleanly.
        It 'noops on first run when hash matches an existing slot (silent migration)' {
            $credFile = Join-Path $script:CD '.credentials.json'
            $slotFile = Join-Path $script:CD '.credentials.work.json'
            Set-Content -LiteralPath $credFile -Value $script:CredsBody -NoNewline
            Set-Content -LiteralPath $slotFile -Value $script:CredsBody -NoNewline

            $r = Invoke-Reconcile 6>$null
            $r.Action | Should -Be 'noop'
            $r.Reason | Should -Be 'hash-match'

            (Read-ScaState).active_slot | Should -Be 'work'
        }
    }

    AfterAll {
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
