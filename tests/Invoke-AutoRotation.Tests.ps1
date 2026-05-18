#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for the `sca usage -Watch -Auto` auto-rotation helpers
# in switch_claude_account.ps1:
#
#   * Get-AutoRotationDecision  - pure: snapshot + threshold -> decision
#   * Get-RowMaxUtilization     - pure: row -> max(five_hour, seven_day)
#   * Format-AutoCooldownDelta  - pure: reset timestamp -> 'Xh Ym'
#   * Invoke-AutoRotationStep   - per-tick wrapper used by the watch loop
#
# Per-test sandbox setup lives in tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')
    }

    Context 'Get-RowMaxUtilization' {
        It 'returns max of two non-null utilizations' {
            $row = [pscustomobject]@{
                Status = 'ok'
                Data   = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 30.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 80.0; resets_at = $null }
                }
            }
            Get-RowMaxUtilization -Row $row | Should -Be 80.0
        }

        It 'treats null five_hour as 0 and returns seven_day' {
            $row = [pscustomobject]@{
                Status = 'ok'
                Data   = [pscustomobject]@{
                    five_hour = $null
                    seven_day = [pscustomobject]@{ utilization = 99.0; resets_at = $null }
                }
            }
            Get-RowMaxUtilization -Row $row | Should -Be 99.0
        }

        It 'treats both buckets null as 0' {
            $row = [pscustomobject]@{
                Status = 'ok'
                Data   = [pscustomobject]@{
                    five_hour = $null
                    seven_day = $null
                }
            }
            Get-RowMaxUtilization -Row $row | Should -Be 0.0
        }

        It 'returns 0 for non-ok HTTP rows regardless of Data' {
            $row = [pscustomobject]@{
                Status = 'expired'
                Data   = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 99.0; resets_at = $null }
                    seven_day = $null
                }
            }
            Get-RowMaxUtilization -Row $row | Should -Be 0.0
        }
    }

    Context 'Format-AutoCooldownDelta' {
        It 'renders an under-1h future delta as "Xm"' {
            $reset = [DateTimeOffset]::UtcNow.AddMinutes(42).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $out = Format-AutoCooldownDelta $reset
            # Allow 41..42m slack for clock drift between test setup and helper call.
            $out | Should -Match '^(41|42)m$'
        }

        It 'renders a 1h..24h future delta as "Xh Ym"' {
            $reset = [DateTimeOffset]::UtcNow.AddMinutes(134).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $out = Format-AutoCooldownDelta $reset
            $out | Should -Match '^2h (13|14)m$'
        }

        It 'renders a >=24h future delta as integer "Xh"' {
            # Use a generous 42h + 1m offset so clock drift between test
            # setup and the helper call never makes the floored hours
            # tick down to 41. Format-AutoCooldownDelta floors total
            # hours, so 42:00.99 -> 42; the test asserts on the format
            # shape and the exact value 42h within that 1-minute window.
            $reset = [DateTimeOffset]::UtcNow.AddHours(42).AddMinutes(1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-AutoCooldownDelta $reset | Should -Be '42h'
        }

        It 'returns "less than a minute" for a non-positive delta' {
            $reset = [DateTimeOffset]::UtcNow.AddSeconds(-30).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-AutoCooldownDelta $reset | Should -Be 'less than a minute'
        }

        It 'returns "unknown" for unparseable / null input' {
            Format-AutoCooldownDelta $null     | Should -Be 'unknown'
            Format-AutoCooldownDelta ''        | Should -Be 'unknown'
            Format-AutoCooldownDelta 'garbage' | Should -Be 'unknown'
        }
    }

    Context 'Get-AutoRotationDecision' {
        # Build a synthetic snapshot resembling Get-UsageSnapshot's output
        # shape without hitting the network or filesystem. Each row mirrors
        # the fields the pure decision logic reads: Name, IsActive, Status,
        # Data.five_hour.utilization / .resets_at, Data.seven_day.{same}.
        BeforeAll {
            function New-Row {
                Param (
                    [string] $Name,
                    [bool]   $IsActive = $false,
                    [string] $Status   = 'ok',
                    $FiveUtil          = 0.0,
                    $FiveResetsAt      = $null,
                    $SevenUtil         = 0.0,
                    $SevenResetsAt     = $null
                )

                $data = $null
                if ($Status -eq 'ok') {
                    $data = [pscustomobject]@{
                        five_hour = [pscustomobject]@{ utilization = $FiveUtil;  resets_at = $FiveResetsAt }
                        seven_day = [pscustomobject]@{ utilization = $SevenUtil; resets_at = $SevenResetsAt }
                    }
                }

                return [pscustomobject]@{
                    Name     = $Name
                    IsActive = $IsActive
                    Status   = $Status
                    Data     = $data
                    Error    = $null
                    Email    = "$Name@test.local"
                }
            }

            function New-Snapshot {
                Param ([object[]] $Rows)
                return [pscustomobject]@{
                    Results          = @($Rows)
                    NoSlots          = ($null -eq $Rows -or $Rows.Count -eq 0)
                    HasCacheFallback = $false
                }
            }
        }

        It 'returns noop when snapshot is empty (NoSlots)' {
            $snap = New-Snapshot @()
            $d = Get-AutoRotationDecision -Snapshot $snap -Threshold 100
            $d.Action | Should -Be 'noop'
        }

        It 'returns noop when no row is active' {
            $rows = @(
                (New-Row -Name 'a' -FiveUtil 50.0 -SevenUtil 50.0),
                (New-Row -Name 'b' -FiveUtil 50.0 -SevenUtil 50.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action | Should -Be 'noop'
        }

        It 'returns noop when active slot is below threshold' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 30.0 -SevenUtil 50.0),
                (New-Row -Name 'b' -FiveUtil 10.0 -SevenUtil 10.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action   | Should -Be 'noop'
            $d.FromName | Should -Be 'a'
        }

        It 'rotates to the next eligible peer in alphabetical wrap order' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 100.0 -SevenUtil 50.0),
                (New-Row -Name 'b' -FiveUtil 18.0 -SevenUtil 31.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action   | Should -Be 'rotate'
            $d.FromName | Should -Be 'a'
            $d.ToName   | Should -Be 'b'
        }

        It 'rotation wraps from last slot back to first' {
            $rows = @(
                (New-Row -Name 'a' -FiveUtil 20.0 -SevenUtil 20.0),
                (New-Row -Name 'b' -IsActive $true -FiveUtil 100.0 -SevenUtil 50.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action | Should -Be 'rotate'
            $d.ToName | Should -Be 'a'
        }

        It 'skips peers that are themselves at or above threshold' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 100.0 -SevenUtil 50.0),
                (New-Row -Name 'b' -FiveUtil 100.0 -SevenUtil 80.0),    # also limited; skip
                (New-Row -Name 'c' -FiveUtil 20.0  -SevenUtil 30.0)     # eligible
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action | Should -Be 'rotate'
            $d.ToName | Should -Be 'c'
        }

        It 'skips peers with non-ok HTTP status (expired)' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 100.0),
                (New-Row -Name 'b' -Status 'expired'),
                (New-Row -Name 'c' -FiveUtil 20.0 -SevenUtil 30.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action | Should -Be 'rotate'
            $d.ToName | Should -Be 'c'
        }

        It 'returns no-eligible when all peers are also at or above threshold' {
            $futureA = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $futureB = [DateTimeOffset]::UtcNow.AddHours(3).ToString('o', [Globalization.CultureInfo]::InvariantCulture)

            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 100.0 -FiveResetsAt $futureA -SevenUtil 80.0),
                (New-Row -Name 'b' -FiveUtil 100.0 -FiveResetsAt $futureB -SevenUtil 90.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100

            $d.Action             | Should -Be 'no-eligible'
            $d.FromName           | Should -Be 'a'
            $d.SuggestionName     | Should -Be 'a'
            $d.SuggestionBucket   | Should -Be 'Session'
            $d.SuggestionResetsAt | Should -Not -BeNullOrEmpty
        }

        It 'no-eligible picks the soonest FUTURE reset across all slots and buckets' {
            $soon       = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $later      = [DateTimeOffset]::UtcNow.AddHours(5).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $past       = [DateTimeOffset]::UtcNow.AddMinutes(-30).ToString('o', [Globalization.CultureInfo]::InvariantCulture)

            $rows = @(
                # Active 'a': past 5h reset (must be ignored), future 7d.
                (New-Row -Name 'a' -IsActive $true `
                    -FiveUtil 100.0  -FiveResetsAt $past `
                    -SevenUtil 100.0 -SevenResetsAt $later),
                # Peer 'b' also at threshold: its 5h reset is the soonest future reset overall.
                (New-Row -Name 'b' `
                    -FiveUtil 100.0  -FiveResetsAt $soon `
                    -SevenUtil 100.0 -SevenResetsAt $later)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100

            $d.Action           | Should -Be 'no-eligible'
            $d.SuggestionName   | Should -Be 'b'
            $d.SuggestionBucket | Should -Be 'Session'
        }

        It 'threshold uses max(5h, 7d): 5h=10, 7d=99, threshold=95 -> rotate' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 10.0 -SevenUtil 99.0),
                (New-Row -Name 'b' -FiveUtil 20.0 -SevenUtil 30.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 95
            $d.Action | Should -Be 'rotate'
            $d.ToName | Should -Be 'b'
        }

        It 'null bucket on active counts as 0% for max(util)' {
            # Active row's seven_day is missing; max(util) falls to five_hour=50.
            # Threshold 60 -> below -> noop.
            $row = [pscustomobject]@{
                Name     = 'a'
                IsActive = $true
                Status   = 'ok'
                Data     = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 50.0; resets_at = $null }
                    seven_day = $null
                }
                Email    = 'a@test.local'
            }
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot @($row)) -Threshold 60
            $d.Action | Should -Be 'noop'
        }

        It 'threshold 100 with active at exactly 100 triggers rotation (boundary inclusive)' {
            $rows = @(
                (New-Row -Name 'a' -IsActive $true -FiveUtil 100.0 -SevenUtil 50.0),
                (New-Row -Name 'b' -FiveUtil 10.0 -SevenUtil 10.0)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action | Should -Be 'rotate'
        }

        It 'single-slot pool at threshold -> no-eligible (cannot rotate to self)' {
            $future = [DateTimeOffset]::UtcNow.AddHours(2).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $rows = @(
                (New-Row -Name 'only' -IsActive $true -FiveUtil 100.0 -FiveResetsAt $future)
            )
            $d = Get-AutoRotationDecision -Snapshot (New-Snapshot $rows) -Threshold 100
            $d.Action         | Should -Be 'no-eligible'
            $d.SuggestionName | Should -Be 'only'
        }
    }

    Context 'Invoke-AutoRotationStep' {
        # The step wraps Get-AutoRotationDecision + Test-ClaudeRunning re-check
        # + Find-SlotByName + Invoke-SlotSwap. Tests mock the decision and the
        # swap so each branch can be exercised without filesystem state.
        BeforeAll {
            function New-EmptySnapshot {
                return [pscustomobject]@{
                    Results          = @()
                    NoSlots          = $true
                    HasCacheFallback = $false
                }
            }
        }

        It 'on noop preserves the current latch verbatim' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{ Action = 'noop' } }
            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Auto] Automatic slot switching is enabled.'
            $out | Should -Be '[Auto] Automatic slot switching is enabled.'
        }

        It 'on noop preserves a previously-latched Rotated line' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{ Action = 'noop' } }
            $prev = '[Auto] Rotated from "a" to "b" at 12:00:00'
            $out  = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch $prev
            $out | Should -Be $prev
        }

        It 'on rotate calls Invoke-SlotSwap and returns a quoted+timestamped Rotated line' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action   = 'rotate'
                FromName = 'work'
                ToName   = 'personal'
            } }
            Mock Find-SlotByName  { return [pscustomobject]@{ Name = 'personal'; Path = 'x'; Sidecar = $null } }
            Mock Invoke-SlotSwap  { }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Auto] Automatic slot switching is enabled.'

            Should -Invoke Invoke-SlotSwap -Times 1
            $out | Should -Match '^\[Auto\] Rotated from "work" to "personal" at \d{2}:\d{2}:\d{2}$'
        }

        It 'on rotate with Claude Code running: refuses, does NOT call Invoke-SlotSwap' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action   = 'rotate'
                FromName = 'work'
                ToName   = 'personal'
            } }
            Mock Test-ClaudeRunning { $true }
            Mock Invoke-SlotSwap    { }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Auto] Automatic slot switching is enabled.'

            Should -Invoke Invoke-SlotSwap -Times 0
            $out | Should -Be '[Auto] Rotation refused! Claude Code is running.'
        }

        It 'on rotate when swap throws, returns Rotation failed!' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action   = 'rotate'
                FromName = 'work'
                ToName   = 'personal'
            } }
            Mock Find-SlotByName { return [pscustomobject]@{ Name = 'personal'; Path = 'x'; Sidecar = $null } }
            Mock Invoke-SlotSwap { throw [System.IO.IOException]::new('locked file') }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Auto] Automatic slot switching is enabled.'
            $out | Should -Match '^\[Auto\] Rotation failed! .*locked file'
        }

        It 'on rotate when slot lookup returns null, returns Rotation failed!' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action   = 'rotate'
                FromName = 'work'
                ToName   = 'personal'
            } }
            Mock Find-SlotByName { return $null }
            Mock Invoke-SlotSwap { }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Auto] Automatic slot switching is enabled.'
            Should -Invoke Invoke-SlotSwap -Times 0
            $out | Should -Match '^\[Auto\] Rotation failed! Slot ''personal'' not found'
        }

        It 'on no-eligible with a future reset, returns cooldown line with a delta' {
            $future = [DateTimeOffset]::UtcNow.AddMinutes(72).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action             = 'no-eligible'
                SuggestionResetsAt = $future
            } }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Auto] Automatic slot switching is enabled.'
            $out | Should -Match '^\[Auto\] No free slot available! Cooling down for 1h (11|12)m\.$'
        }

        It 'on no-eligible without any future reset, returns a generic line' {
            Mock Get-AutoRotationDecision { return [pscustomobject]@{
                Action             = 'no-eligible'
                SuggestionResetsAt = $null
            } }

            $out = Invoke-AutoRotationStep -Snapshot (New-EmptySnapshot) -Threshold 100 -CurrentLatch '[Auto] Automatic slot switching is enabled.'
            $out | Should -Be '[Auto] No free slot available! Waiting for the next poll.'
        }
    }
}
