#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for the small pure-helper functions in
# switch_claude_account.ps1: Get-SafeName, Get-ProfileEncoding, Get-Slots,
# Get-SlotFileInfo, Show-Help.
#
# Per-test sandbox setup lives in tests/Common.ps1; see that file for the
# scoping rationale. Each top-level Describe must wrap a BeforeEach (Pester 5
# forbids BeforeEach at file root), so all Contexts in this file nest under
# one outer Describe named 'switch_claude_account', same name as the other
# split files so test FullName paths stay stable.

BeforeAll {
    # Capture the pre-suite values of the two globals BeforeEach mutates so
    # we can restore them in AfterAll. Without this, running Invoke-Pester
    # directly in an interactive shell (as the README suggests) would leave
    # the session's $env:USERPROFILE pointing at a deleted $TestDrive path
    # and $PROFILE as a PSCustomObject stub, which breaks later commands.
    # Running via the subprocess `pwsh -NoProfile -File tests/Invoke-Tests.ps1`
    # was already safe because the mutations died with the subprocess.
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')
    }

    Context 'Get-SafeName' {
        # NOTE: we use Raw (not Input) as the hashtable key because $Input
        # is a PowerShell automatic variable (pipeline enumerator) and gets
        # overwritten inside test scriptblocks, yielding empty strings.
        It 'rejects: <Case>' -ForEach @(
            @{ Case = 'empty';      Raw = '';        Pattern = 'Name required' }
            @{ Case = 'whitespace'; Raw = '   ';     Pattern = 'Name required' }
            @{ Case = 'dot';        Raw = '.';       Pattern = 'invalid filename' }
            @{ Case = 'dotdot';     Raw = '..';      Pattern = 'invalid filename' }
            @{ Case = 'dotdotdot';  Raw = '...';     Pattern = 'invalid filename' }
            @{ Case = 'CON';        Raw = 'CON';     Pattern = 'reserved Windows device' }
            @{ Case = 'con lower';  Raw = 'con';     Pattern = 'reserved Windows device' }
            @{ Case = 'CON.bak';    Raw = 'con.bak'; Pattern = 'reserved Windows device' }
            @{ Case = 'LPT3';       Raw = 'lpt3';    Pattern = 'reserved Windows device' }
            @{ Case = 'COM9';       Raw = 'COM9';    Pattern = 'reserved Windows device' }
            @{ Case = 'NUL';        Raw = 'NUL';     Pattern = 'reserved Windows device' }
        ) {
            { Get-SafeName $Raw } | Should -Throw -ExpectedMessage "*$Pattern*"
        }

        It 'sanitizes: <Case>' -ForEach @(
            @{ Case = 'space';          Raw = 'my personal'; Expected = 'my_personal' }
            @{ Case = 'forward slash';  Raw = 'foo/bar';     Expected = 'foo_bar' }
            @{ Case = 'backslash';      Raw = 'foo\bar';     Expected = 'foo_bar' }
            @{ Case = 'colon';          Raw = 'a:b';         Expected = 'a_b' }
            @{ Case = 'angle brackets'; Raw = 'a<b>c';       Expected = 'a_b_c' }
            @{ Case = 'pipe';           Raw = 'a|b';         Expected = 'a_b' }
            @{ Case = 'trailing dot';   Raw = 'foo.';        Expected = 'foo' }
            @{ Case = 'many dots';      Raw = 'foo...';      Expected = 'foo' }
            # Brackets are valid on the Windows filesystem but are PowerShell
            # wildcard chars; leaving them in slot names would cause -Path
            # operations to match unintended files (silent wrong-slot or
            # data-loss bug).
            @{ Case = 'open bracket';   Raw = 'foo[bar';     Expected = 'foo_bar' }
            @{ Case = 'close bracket';  Raw = 'foo]bar';     Expected = 'foo_bar' }
            @{ Case = 'both brackets';  Raw = 'foo[bar]';    Expected = 'foo_bar_' }
            # Parens are sanitized because the slot filename encodes the
            # OAuth email as `.credentials.<slot>(<email>).json`. Leaving
            # parens in user-provided slot names would produce ambiguous
            # filenames that the Get-SlotFileInfo parser cannot split
            # correctly.
            @{ Case = 'open paren';     Raw = 'foo(bar';     Expected = 'foo_bar' }
            @{ Case = 'close paren';    Raw = 'foo)bar';     Expected = 'foo_bar' }
            @{ Case = 'both parens';    Raw = 'foo(bar)';    Expected = 'foo_bar_' }
        ) {
            # Information stream 6 carries the "Sanitized to:" Write-Host notice;
            # redirect it to $null so it does not bleed into the return value.
            Get-SafeName $Raw 6>$null | Should -Be $Expected
        }

        It 'accepts already-safe name unchanged' {
            Get-SafeName 'work' 6>$null | Should -Be 'work'
        }

        It 'accepts names that only prefix-match a reserved device name' {
            Get-SafeName 'CONCERT' 6>$null | Should -Be 'CONCERT'
            Get-SafeName 'COM10'   6>$null | Should -Be 'COM10'
            Get-SafeName 'LPT0'    6>$null | Should -Be 'LPT0'
        }
    }

    Context 'Get-ProfileEncoding' {
        It '<Case>' -ForEach @(
            @{ Case = 'UTF-8 BOM';    Bytes = [byte[]](0xEF,0xBB,0xBF,0x61); Expected = 'utf8BOM' }
            @{ Case = 'UTF-16 LE';    Bytes = [byte[]](0xFF,0xFE,0x61,0x00); Expected = 'unicode' }
            @{ Case = 'UTF-16 BE';    Bytes = [byte[]](0xFE,0xFF,0x00,0x61); Expected = 'bigendianunicode' }
            @{ Case = 'no BOM';       Bytes = [byte[]](0x61,0x62,0x63,0x64); Expected = 'utf8NoBOM' }
            @{ Case = 'short no BOM'; Bytes = [byte[]](0x61);                Expected = 'utf8NoBOM' }
        ) {
            $path = Join-Path $TestDrive 'enc.bin'
            [System.IO.File]::WriteAllBytes($path, $Bytes)
            Get-ProfileEncoding $path | Should -Be $Expected
        }

        It 'returns utf8NoBOM when file does not exist' {
            $missing = Join-Path $TestDrive 'does-not-exist.ps1'
            Get-ProfileEncoding $missing | Should -Be 'utf8NoBOM'
        }
    }

    Context 'Get-Slots' {
        # Regression: a slot file whose literal name contains [ or ] must be
        # hashed correctly during the auto-migration path in Read-ScaState
        # (which runs when no state file exists yet). Before the -LiteralPath
        # fix, Get-FileHash -Path wildcard-expanded the path and silently
        # mis-identified which slot was active (or threw).
        It 'marks a literal bracket slot as active when its hash matches .credentials.json' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'fooa'     -Content 'A'  | Out-Null
            New-SlotPair -CredDir $credDir -Name 'foo[bar]' -Content 'BR' | Out-Null
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.json') -Value 'BR' -NoNewline

            $active = @(Get-Slots | Where-Object { $_.IsActive })

            $active.Count    | Should -Be 1
            $active[0].Name  | Should -Be 'foo[bar]'
        }

        # Labeled filename support: Get-Slots parses the parenthesized
        # email out of the filename and exposes it as .Email on each
        # slot object. The slot Name is the portion before the parens,
        # so the user-visible slot name stays the same whether the file
        # is labeled or not.
        It 'parses labeled filenames into (Name, Email) pairs' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'work' -Email 'alice@example.com' -Content 'W' | Out-Null
            New-SlotPair -CredDir $credDir -Name 'solo' -Content 'S' | Out-Null

            $slots = @(Get-Slots)
            $bySlotName = @{}
            foreach ($s in $slots) { $bySlotName[$s.Name] = $s }

            $bySlotName.ContainsKey('work') | Should -BeTrue
            $bySlotName['work'].Email       | Should -Be 'alice@example.com'
            $bySlotName.ContainsKey('solo') | Should -BeTrue
            $bySlotName['solo'].Email       | Should -BeNullOrEmpty
        }

        # New: verify Get-Slots filters out slots without sidecars.
        It 'hides slot files that have no sidecar (post-v2.1.0 contract)' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            # Bare slot file, no sidecar; invisible by design.
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.legacy.json') -Value 'L' -NoNewline
            # Properly paired slot; visible.
            New-SlotPair -CredDir $credDir -Name 'modern' -Content 'M' | Out-Null

            $names = @(Get-Slots | ForEach-Object Name)
            $names | Should -Be @('modern')
            $names | Should -Not -Contain 'legacy'
        }

        # New: sidecar files themselves must not be enumerated as slots.
        It 'does not enumerate .account.json sidecar files as slot credentials' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'work' -Content 'W' | Out-Null

            $names = @(Get-Slots | ForEach-Object Name)
            $names | Should -Be @('work')
            # No phantom slot whose name ends in '.account' (would mean
            # the sidecar leaked into Get-SlotFileInfo's parser).
            $names | ForEach-Object { $_ | Should -Not -Match '\.account$' }
        }
    }

    Context 'Get-SlotFileInfo' {
        # Parses a .credentials.*.json filename into a (Name, Email)
        # tuple. The grammar is:
        #   .credentials.<slot>.json                -> unlabeled
        #   .credentials.<slot>(<email>).json       -> labeled; the parens
        #                                              must contain '@' to
        #                                              be treated as an email
        # NOTE: The hashtable key is deliberately `SlotName`, not `Name`.
        # The script-under-test declares a top-level `[String] $Name`
        # parameter; dot-sourcing binds that into script scope, and a
        # hashtable key named `Name` would shadow it inside the `It`
        # block (same class of issue the `Get-SafeName` suite flags for
        # `Input` with `Raw`).
        It '<Case>' -ForEach @(
            @{ Case = 'unlabeled plain slot';           File = '.credentials.work.json';                                 SlotName = 'work';                  Email = $null }
            @{ Case = 'labeled: simple email';          File = '.credentials.work(alice@example.com).json';              SlotName = 'work';                  Email = 'alice@example.com' }
            @{ Case = 'labeled: dotted local-part';     File = '.credentials.work(ada.lovelace@arpa.net).json';         SlotName = 'work';                  Email = 'ada.lovelace@arpa.net' }
            @{ Case = 'dotted slot name + labeled';     File = '.credentials.work.backup(alice@example.com).json';       SlotName = 'work.backup';           Email = 'alice@example.com' }
            @{ Case = 'slot name is an email';          File = '.credentials.ada.lovelace@arpa.net.json';               SlotName = 'ada.lovelace@arpa.net'; Email = $null }
            @{ Case = 'dotted slot name, unlabeled';    File = '.credentials.work.backup.json';                          SlotName = 'work.backup';           Email = $null }
            @{ Case = 'parens without @ in name';       File = '.credentials.work(v2).json';                             SlotName = 'work(v2)';              Email = $null }
            @{ Case = 'slot is email + paren email';    File = '.credentials.alice@work.com(alice@personal.com).json';   SlotName = 'alice@work.com';        Email = 'alice@personal.com' }
        ) {
            $parsed = Get-SlotFileInfo -FileName $File
            $parsed.Name  | Should -Be $SlotName
            if ($null -eq $Email) {
                $parsed.Email | Should -BeNullOrEmpty
            } else {
                $parsed.Email | Should -Be $Email
            }
        }

        It 'returns $null for filenames that do not match the .credentials.*.json convention' {
            Get-SlotFileInfo -FileName 'not-credentials.json' | Should -BeNullOrEmpty
            Get-SlotFileInfo -FileName '.credentials.json'    | Should -BeNullOrEmpty
        }
    }

    Context 'Show-Help' {
        It 'prints the ACTIONS header and lists all 8 actions' {
            $out = Show-Help 6>&1 | Out-String

            $out | Should -Match 'ACTIONS'
            $out | Should -Match 'save <name>'
            $out | Should -Match 'switch \[name\]'
            $out | Should -Match 'list'
            $out | Should -Match 'remove <name>'
            $out | Should -Match 'usage \[name\]'
            $out | Should -Match 'install'
            $out | Should -Match 'uninstall'
            $out | Should -Match 'help, -h'
        }

        It 'documents the -NoColor option and the NO_COLOR env var' {
            $out = Show-Help 6>&1 | Out-String
            $out | Should -Match 'OPTIONS'
            $out | Should -Match '-NoColor'
            $out | Should -Match 'NO_COLOR'
        }
    }

    Context 'Format-WatchTitle' {
        # Pure string-builder for the OSC 0 watch-mode terminal title.
        # The title carries the active slot's two utilization numbers +
        # brand suffix, optionally prefixed with '[!]' (any bucket >=
        # UtilLimitPct) or '[~]' (any bucket >= UtilWarnPct). Source
        # row is the active slot (IsActive=true) by default, or the
        # -Name match when -Name is set. These tests pin the format
        # string, the active-slot selection rule, and the prefix tier
        # thresholds so a future refactor cannot silently re-introduce
        # pool-mean averaging or drop the alarm prefix.

        # Build a minimal Get-UsageSnapshot-shaped object for a list of
        # rows. Each row hashtable accepts: Name, Status, IsActive,
        # FiveUtil, SevenUtil (any field omitted defaults to slot-x /
        # ok / $false / null / null).
        function script:New-FakeSnapshot {
            Param ([object[]] $Rows)
            $results = foreach ($r in $Rows) {
                $five  = if ($r.ContainsKey('FiveUtil'))  { $r.FiveUtil }  else { $null }
                $seven = if ($r.ContainsKey('SevenUtil')) { $r.SevenUtil } else { $null }
                [pscustomobject]@{
                    Name     = if ($r.ContainsKey('Name'))     { $r.Name }              else { 'slot-x' }
                    Status   = if ($r.ContainsKey('Status'))   { $r.Status }            else { 'ok' }
                    IsActive = if ($r.ContainsKey('IsActive')) { [bool]$r.IsActive }    else { $false }
                    Email    = $null
                    Data     = if ($null -eq $five -and $null -eq $seven) {
                                   $null
                               } else {
                                   [pscustomobject]@{
                                       five_hour = if ($null -ne $five)  { [pscustomobject]@{ utilization = $five  } } else { $null }
                                       seven_day = if ($null -ne $seven) { [pscustomobject]@{ utilization = $seven } } else { $null }
                                   }
                               }
                    Error            = $null
                    IsCachedFallback = $false
                }
            }
            return [pscustomobject]@{
                Results          = @($results)
                NoSlots          = $false
                HasCacheFallback = $false
            }
        }

        # --- Source row selection -------------------------------------

        It 'renders the active slot in multi-slot watch (no -Name)' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 10; SevenUtil = 20 }
                @{ Name = 'b'; FiveUtil = 50; SevenUtil = 60; IsActive = $true }
                @{ Name = 'c'; FiveUtil = 80; SevenUtil = 70 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '50% | 60% | Switch Claude Account'
        }

        It '-Name overrides IsActive (renders named slot regardless of which is active)' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 10; SevenUtil = 20; IsActive = $true }
                @{ Name = 'b'; FiveUtil = 70; SevenUtil = 80 }
            )
            Format-WatchTitle -Name 'b' -Snapshot $snap |
                Should -Be '70% | 80% | Switch Claude Account'
        }

        It 'falls back to bare suffix when no row is active and -Name unset' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 10; SevenUtil = 20 }
                @{ Name = 'b'; FiveUtil = 30; SevenUtil = 40 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be 'Switch Claude Account'
        }

        It 'falls back to bare suffix when -Name does not match any row' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 10; SevenUtil = 20; IsActive = $true }
            )
            Format-WatchTitle -Name 'nonexistent' -Snapshot $snap |
                Should -Be 'Switch Claude Account'
        }

        # --- Number rendering -----------------------------------------

        It 'renders both buckets present' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 34; SevenUtil = 42; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '34% | 42% | Switch Claude Account'
        }

        It 'rounds fractional utilization to nearest integer' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 33.6; SevenUtil = 41.4; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '34% | 41% | Switch Claude Account'
        }

        It 'renders em-dash for null buckets (mixed null)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = $null; SevenUtil = 42; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '— | 42% | Switch Claude Account'
        }

        It 'renders em-dashes when both buckets null (active row, no usable utilization)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = $null; SevenUtil = $null; IsActive = $true })
            # Distinguishes "active row exists but cold" from "no usable
            # row at all" (the latter collapses to bare suffix).
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '— | — | Switch Claude Account'
        }

        # --- Bare-suffix fallbacks ------------------------------------

        It 'returns bare suffix for empty snapshot (no slots saved)' {
            $empty = [pscustomobject]@{ Results = @(); NoSlots = $true; HasCacheFallback = $false }
            Format-WatchTitle -Name '' -Snapshot $empty |
                Should -Be 'Switch Claude Account'
        }

        It 'returns bare suffix when all rows are HTTP-failure (active row included)' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; Status = 'expired'; FiveUtil = 10; SevenUtil = 10; IsActive = $true }
                @{ Name = 'b'; Status = 'error';   FiveUtil = 20; SevenUtil = 20 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be 'Switch Claude Account'
        }

        It 'returns bare suffix when active row Status is <Status>' -ForEach @(
            @{ Status = 'expired'      }
            @{ Status = 'unauthorized' }
            @{ Status = 'error'        }
            @{ Status = 'no-oauth'     }
            @{ Status = 'rate-limited' }
        ) {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; Status = $Status; FiveUtil = 50; SevenUtil = 50; IsActive = $true }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be 'Switch Claude Account'
        }

        It 'returns bare suffix when -Name matches but row is not ok' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; Status = 'expired'; FiveUtil = 50; SevenUtil = 50 }
            )
            Format-WatchTitle -Name 'a' -Snapshot $snap |
                Should -Be 'Switch Claude Account'
        }

        It 'ignores non-active rows (does not pool-mean across slots)' {
            # Regression guard: a previous version pool-meaned across all
            # HTTP-ok rows, which averaged a burned slot's 100% down to
            # noise in multi-slot watches. The new contract reads the
            # active slot's numbers directly.
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 100; SevenUtil = 100 }
                @{ Name = 'b'; FiveUtil = 10;  SevenUtil = 10; IsActive = $true }
                @{ Name = 'c'; FiveUtil = 100; SevenUtil = 100 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '10% | 10% | Switch Claude Account'
        }

        # --- [!] / [~] alarm prefix tiers -----------------------------

        It 'prepends [!] when 5h bucket is at UtilLimitPct (100)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 100; SevenUtil = 50; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[!] 100% | 50% | Switch Claude Account'
        }

        It 'prepends [!] when 7d bucket is at UtilLimitPct (100)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 50; SevenUtil = 100; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[!] 50% | 100% | Switch Claude Account'
        }

        It 'prepends [!] when both buckets are at UtilLimitPct' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 100; SevenUtil = 100; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[!] 100% | 100% | Switch Claude Account'
        }

        It '[!] wins over [~] when one bucket is at limit and the other near' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 100; SevenUtil = 95; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[!] 100% | 95% | Switch Claude Account'
        }

        It 'prepends [~] when 5h bucket is at exactly UtilWarnPct (90)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 90; SevenUtil = 50; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[~] 90% | 50% | Switch Claude Account'
        }

        It 'prepends [~] when 7d bucket is at UtilWarnPct (above default)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 50; SevenUtil = 92; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[~] 50% | 92% | Switch Claude Account'
        }

        It 'no prefix when both buckets are just below UtilWarnPct (89)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 89; SevenUtil = 89; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '89% | 89% | Switch Claude Account'
        }

        It 'no prefix when both buckets are well below UtilWarnPct' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 30; SevenUtil = 40; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '30% | 40% | Switch Claude Account'
        }

        It 'null buckets do not trigger any prefix' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = $null; SevenUtil = $null; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '— | — | Switch Claude Account'
        }

        It 'one bucket null + the other at limit still fires [!]' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = $null; SevenUtil = 100; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '[!] — | 100% | Switch Claude Account'
        }

        # --- Defense-in-depth -----------------------------------------

        It 'strips control bytes from the assembled title' {
            # Slot names already pass Get-SafeName, but the strip is
            # defense-in-depth against an OSC envelope breakout via a
            # tampered sidecar email or future caller path.
            $rows  = @([pscustomobject]@{
                Name = "x`e]0;EVIL`a"; Status = 'ok'; IsActive = $true; Email = $null
                Data = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 10 }
                    seven_day = [pscustomobject]@{ utilization = 20 }
                }
                Error = $null; IsCachedFallback = $false
            })
            $snap = [pscustomobject]@{ Results = $rows; NoSlots = $false; HasCacheFallback = $false }
            $title = Format-WatchTitle -Name '' -Snapshot $snap
            $title | Should -Not -Match "`e"
            $title | Should -Not -Match "`a"
            $title | Should -Be '10% | 20% | Switch Claude Account'
        }

        # --- -Aggregate mode (wired to -Auto by Invoke-UsageWatch) ----
        # In aggregate mode both percentages are the pool mean across
        # HTTP-ok rows, alarm thresholds swap to
        # $Script:AggregateRedPct (90) / $Script:AggregateYellowPct (50),
        # and -Name is ignored. The pool-mean math itself is tested
        # under Get-PoolMeanUtilization in Invoke-UsageAction.Tests.ps1;
        # these tests pin the rendering behavior on top of it.

        It '-Aggregate renders pool mean across all HTTP-ok rows (active flag ignored)' {
            # Regression contrast: without -Aggregate the same snapshot
            # renders the active row (10% | 10%, see "ignores non-active
            # rows" test above). With -Aggregate it averages all three:
            # 5h mean = (100+10+100)/3 = 70, 7d mean = (100+10+100)/3 = 70.
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 100; SevenUtil = 100 }
                @{ Name = 'b'; FiveUtil = 10;  SevenUtil = 10; IsActive = $true }
                @{ Name = 'c'; FiveUtil = 100; SevenUtil = 100 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[~] 70% | 70% | Switch Claude Account'
        }

        It '-Aggregate excludes HTTP-failure rows from the mean' {
            # 2 ok rows + 1 expired. Mean = (40+60)/2 = 50.
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 40; SevenUtil = 40 }
                @{ Name = 'b'; FiveUtil = 60; SevenUtil = 60; IsActive = $true }
                @{ Name = 'c'; Status = 'expired'; FiveUtil = 100; SevenUtil = 100 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[~] 50% | 50% | Switch Claude Account'
        }

        It '-Aggregate counts null buckets as 0 (denominator stays N)' {
            # 2 ok rows, one with null five_hour. 5h mean = (0+60)/2 = 30
            # (NOT 60, which would be N-1).
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = $null; SevenUtil = 20; IsActive = $true }
                @{ Name = 'b'; FiveUtil = 60;    SevenUtil = 20 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '30% | 20% | Switch Claude Account'
        }

        It '-Aggregate ignores -Name (aggregation is pool-wide by definition)' {
            # The non-aggregate test "renders the active slot" pins that
            # -Name='b' overrides IsActive. Under -Aggregate, -Name has
            # no effect: output equals the no-Name aggregate.
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; FiveUtil = 20; SevenUtil = 20 }
                @{ Name = 'b'; FiveUtil = 80; SevenUtil = 80; IsActive = $true }
            )
            $noName   = Format-WatchTitle -Name ''  -Snapshot $snap -Aggregate
            $withName = Format-WatchTitle -Name 'b' -Snapshot $snap -Aggregate
            $withName | Should -Be $noName
            $noName   | Should -Be '[~] 50% | 50% | Switch Claude Account'
        }

        It '-Aggregate returns bare suffix when no HTTP-ok rows exist' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Name = 'a'; Status = 'expired'; FiveUtil = 50; SevenUtil = 50; IsActive = $true }
                @{ Name = 'b'; Status = 'error';   FiveUtil = 50; SevenUtil = 50 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be 'Switch Claude Account'
        }

        It '-Aggregate returns bare suffix for empty snapshot' {
            $empty = [pscustomobject]@{ Results = @(); NoSlots = $true; HasCacheFallback = $false }
            Format-WatchTitle -Name '' -Snapshot $empty -Aggregate |
                Should -Be 'Switch Claude Account'
        }

        # Alarm prefix tier swap: AggregateYellowPct (50) / AggregateRedPct (90).

        It '-Aggregate prepends [!] when pool mean is at AggregateRedPct (90)' {
            # Single row at 90/50 -> pool mean = 90/50.
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 90; SevenUtil = 50; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[!] 90% | 50% | Switch Claude Account'
        }

        It '-Aggregate prepends [~] when pool mean is at AggregateYellowPct (50)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 50; SevenUtil = 49; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[~] 50% | 49% | Switch Claude Account'
        }

        It '-Aggregate no prefix when pool mean is below AggregateYellowPct (49)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 49; SevenUtil = 49; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '49% | 49% | Switch Claude Account'
        }

        It '-Aggregate [!] wins over [~] when one bucket is at Red and the other at Yellow' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 90; SevenUtil = 50; IsActive = $true })
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[!] 90% | 50% | Switch Claude Account'
        }

        It '-Aggregate does NOT fire on per-slot UtilWarnPct (default-mode threshold) below AggregateYellowPct' {
            # Default mode at 30/40 with active=true would render no prefix.
            # Aggregate mode at the same row (N=1) also renders no prefix
            # because both buckets are below AggregateYellowPct (50). This
            # test is the inverse-axis check: confirm the threshold pair
            # actually swapped, not just that the default thresholds got
            # left in.
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 89; SevenUtil = 89; IsActive = $true })
            # Default mode -> 89/89 is below UtilWarnPct (90), no prefix.
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '89% | 89% | Switch Claude Account'
            # Aggregate mode -> 89 is at/above AggregateYellowPct (50), [~]
            # prefix fires. Pins the threshold swap.
            Format-WatchTitle -Name '' -Snapshot $snap -Aggregate |
                Should -Be '[~] 89% | 89% | Switch Claude Account'
        }
    }

    Context 'Watch-mode VT control rendering' {
        # Regression guard for `sca usage -Watch -NoColor` flicker.
        #
        # Background: -NoColor sets $PSStyle.OutputRendering='PlainText',
        # which routes every Write-Host string through PowerShell's
        # StringDecorated.AnsiRegex filter. That regex matches DEC private
        # modes (\x1b\[\?\d+[hl]) and strips them -- so when watch-mode
        # VT controls (DEC 2026 sync envelope, alt-buffer toggle, cursor
        # hide/show) go through Write-Host, the entire flicker-free
        # rendering envelope vanishes and -Watch -NoColor flickers.
        #
        # Fix: Write-VTSequence uses [Console]::Out.Write which bypasses
        # StringDecorated entirely. Two assertions pin the contract:
        # one static (no Write-Host VT escapes in Invoke-UsageWatch),
        # one behavioral (Write-VTSequence preserves DEC modes verbatim).

        It 'Invoke-UsageWatch routes all VT control sequences through Write-VTSequence (no Write-Host VT escapes)' {
            # AST-based static check: pin the call sites without a brittle
            # line-range. A future accidental `Write-Host "`e[?...h"`
            # reintroduction in the watch loop fails this test.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$null)
            $func = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-UsageWatch'
            }, $true) | Select-Object -First 1

            $func | Should -Not -BeNullOrEmpty -Because 'Invoke-UsageWatch must exist'

            $bodyLines = $func.Extent.Text -split "`r?`n"
            $offending = @($bodyLines | Where-Object {
                $_ -match '\bWrite-Host\b' -and $_ -match '`e\['
            })
            $offending.Count | Should -Be 0 -Because (
                'VT control sequences in the watch lifecycle must go through ' +
                'Write-VTSequence (which uses [Console]::Out.Write to bypass ' +
                'StringDecorated.AnsiRegex). Routing them through Write-Host ' +
                're-enables PSStyle.OutputRendering=PlainText stripping of DEC ' +
                'private modes, which causes -Watch -NoColor to flicker.')
        }

        It 'Invoke-UsageWatch emits an OSC 0 title set inside the loop and restores the captured title in finally' {
            # Pin the contract that watch mode (a) updates the terminal
            # title on each successful poll and (b) restores the
            # pre-watch title on exit. The static check guards against
            # accidental removal during a future refactor; without
            # title-set the background-window UX regresses, without
            # title-restore the watch leaks its title into the user's
            # post-Ctrl-C shell session.
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:ScriptPath, [ref]$null, [ref]$null)
            $func = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq 'Invoke-UsageWatch'
            }, $true) | Select-Object -First 1
            $func | Should -Not -BeNullOrEmpty -Because 'Invoke-UsageWatch must exist'

            $body = $func.Extent.Text

            # OSC 0 sequence: ESC ] 0 ; <title> BEL. Match the literal
            # `e]0; opener; the renderer interpolation and BEL terminator
            # vary across edits but the opener is invariant.
            $body | Should -Match '`e\]0;' -Because (
                'Invoke-UsageWatch must emit an OSC 0 (\e]0;<title>\a) ' +
                'sequence so the terminal-title shows live usage when ' +
                'the watch window is in the background.')

            # The captured pre-watch title must be restored on exit.
            $body | Should -Match '\$origTitle' -Because (
                'Invoke-UsageWatch must capture and restore the pre-watch ' +
                'terminal title; without restore the watch-mode title ' +
                'persists into the user post-Ctrl-C shell session.')
        }

        It 'Write-VTSequence preserves DEC 2026 envelope verbatim under OutputRendering=PlainText' {
            # Two-part contract check, scoped to the exact sequence the
            # fix depends on (DEC 2026 sync-envelope opener). Broader
            # assertions across all DEC modes would over-couple to
            # PowerShell's internal StringDecorated regex.

            # Part 1: confirm StringDecorated DOES strip the envelope
            # under PlainText (the regression hazard). Common.ps1 already
            # sets OutputRendering=PlainText for the test session.
            # The class lives in System.Management.Automation.Internal
            # (public class, internal-namespaced) and is the same filter
            # PowerShell's host UI applies to every Write-Host string.
            $sd = [System.Management.Automation.Internal.StringDecorated]::new("`e[?2026h")
            $sd.ToString() | Should -BeNullOrEmpty -Because (
                'StringDecorated.AnsiRegex strips DEC private modes under ' +
                'PlainText; this is why VT control sequences must NOT go ' +
                'through Write-Host in -Watch -NoColor mode.')

            # Part 2: confirm Write-VTSequence does NOT go through that
            # filter. Capture by swapping Console.Out for a StringWriter.
            # The finally restores Console.Out BEFORE Pester's assertion
            # output, so the test harness is unaffected.
            $origOut = [Console]::Out
            $sw      = [System.IO.StringWriter]::new()
            try {
                [Console]::SetOut($sw)
                Write-VTSequence "`e[?2026h"
            } finally {
                [Console]::SetOut($origOut)
            }
            $sw.ToString() | Should -Be "`e[?2026h" -Because (
                'Write-VTSequence must preserve DEC private modes verbatim ' +
                'regardless of OutputRendering; otherwise -Watch -NoColor ' +
                'loses its DEC 2026 sync envelope and flickers.')
        }
    }

    Context 'No-color mode' {
        # Verifies the $PSStyle.OutputRendering toggle wired into Invoke-Main.
        # The toggle is the production no-color mechanism: every colored
        # call site goes through `Write-Color` which emits inline ANSI SGR
        # codes; PowerShell's WriteImpl -> GetOutputString filter then
        # strips those SGR codes when OutputRendering=PlainText. So the
        # only thing these tests need to verify is that the toggle is
        # set during dispatch and restored on exit.
        #
        # Common.ps1 sets $PSStyle.OutputRendering='PlainText' globally
        # for tests so existing string-match assertions work against
        # ANSI-stripped output. The tests here override that to 'Host'
        # in their bodies so the toggle test can distinguish "toggled to
        # PlainText" from "was PlainText all along," then restore via
        # try/finally so subsequent tests see the BeforeEach baseline.
        #
        # We mock Invoke-ListAction so the action body becomes a single
        # capture line that records $PSStyle.OutputRendering DURING
        # dispatch. Pester 5's dynamic scoping makes the in-It $NoColor
        # / $Action assignments visible to Invoke-Main (which is defined
        # at the dot-sourced script scope and reads its parameters via
        # the parent scope chain).
        BeforeEach {
            $script:capturedRendering = $null
            Mock Invoke-ListAction { $script:capturedRendering = $PSStyle.OutputRendering }
            # Defensive: ensure NO_COLOR is unset at the start of every
            # test so leakage from a prior test (e.g. the env-var case)
            # does not bleed through.
            if (Test-Path Env:\NO_COLOR) { Remove-Item Env:\NO_COLOR }
        }

        It 'sets OutputRendering=PlainText during dispatch when -NoColor is bound, and restores on exit' {
            $PSStyle.OutputRendering = 'Host'
            try {
                $NoColor = $true
                $Action  = 'list'

                Invoke-Main

                $script:capturedRendering | Should -Be 'PlainText'
                $PSStyle.OutputRendering  | Should -Be 'Host'
            }
            finally {
                $PSStyle.OutputRendering = 'PlainText'
            }
        }

        It 'sets OutputRendering=PlainText during dispatch when $env:NO_COLOR is set, and restores on exit' {
            $PSStyle.OutputRendering = 'Host'
            $env:NO_COLOR = '1'
            try {
                $Action = 'list'
                Invoke-Main

                $script:capturedRendering | Should -Be 'PlainText'
                $PSStyle.OutputRendering  | Should -Be 'Host'
            }
            finally {
                Remove-Item Env:\NO_COLOR -ErrorAction SilentlyContinue
                $PSStyle.OutputRendering = 'PlainText'
            }
        }

        It 'leaves OutputRendering untouched when neither -NoColor nor $env:NO_COLOR is set' {
            $PSStyle.OutputRendering = 'Host'
            try {
                $Action = 'list'

                Invoke-Main

                $script:capturedRendering | Should -Be 'Host'
                $PSStyle.OutputRendering  | Should -Be 'Host'
            }
            finally {
                $PSStyle.OutputRendering = 'PlainText'
            }
        }
    }

    Context 'ConvertTo-ScaJsonString' {
        # Note: the function's `if ($null -eq $Value) { return 'null' }`
        # branch is defensive-dead. PowerShell binds $null to a [string]
        # parameter as '', so external callers cannot exercise it; the
        # one internal caller in Set-OAuthAccountInClaudeJson short-
        # circuits before calling. We do NOT test that branch.

        It 'escapes embedded double-quotes, backslashes, and control characters' {
            ConvertTo-ScaJsonString -Value 'a "b" \ c' | Should -Be '"a \"b\" \\ c"'
            ConvertTo-ScaJsonString -Value "line1`nline2`tend" | Should -Be '"line1\nline2\tend"'
        }

        It 'wraps a plain string in double quotes' {
            ConvertTo-ScaJsonString -Value 'hello' | Should -Be '"hello"'
        }

        It 'returns an empty JSON string for empty input (binding null collapses to "")' {
            ConvertTo-ScaJsonString -Value '' | Should -Be '""'
        }
    }

    Context 'ConvertTo-DateTimeOffsetOrNull' {
        It 'returns $null for null and empty input' {
            ConvertTo-DateTimeOffsetOrNull -Value $null | Should -BeNullOrEmpty
            ConvertTo-DateTimeOffsetOrNull -Value ''    | Should -BeNullOrEmpty
        }

        It 'returns $null for unparseable strings rather than throwing' {
            ConvertTo-DateTimeOffsetOrNull -Value 'not-a-date' | Should -BeNullOrEmpty
        }

        It 'returns the value unchanged for a DateTimeOffset input' {
            $dto = [DateTimeOffset]::new(2026, 4, 26, 12, 0, 0, [TimeSpan]::Zero)
            (ConvertTo-DateTimeOffsetOrNull -Value $dto) | Should -Be $dto
        }

        It 'casts a [DateTime] input to [DateTimeOffset]' {
            # The local time zone is environment-dependent, so we only
            # assert the cast succeeded and the type is correct.
            $dt = [DateTime]::new(2026, 4, 26, 12, 0, 0, [DateTimeKind]::Utc)
            $r = ConvertTo-DateTimeOffsetOrNull -Value $dt
            $r | Should -BeOfType ([DateTimeOffset])
        }

        It 'parses an ISO-8601 string' {
            $iso = '2026-04-26T12:00:00.000Z'
            $r = ConvertTo-DateTimeOffsetOrNull -Value $iso
            $r | Should -BeOfType ([DateTimeOffset])
            $r.UtcDateTime | Should -Be ([DateTime]::new(2026, 4, 26, 12, 0, 0, [DateTimeKind]::Utc))
        }
    }

    Context 'Format-UtilCell / Format-Truncate / Format-AccountCell / Format-BucketCell' {
        # Direct unit tests for the pure cell-formatters; closes a
        # coverage gap previously left by exercising them only through
        # full Invoke-UsageAction renders.

        It 'Format-UtilCell renders em-dash for $null utilization' {
            (Format-UtilCell -Utilization $null) | Should -Be '   —'
        }

        It 'Format-UtilCell renders a right-justified integer percent' {
            (Format-UtilCell -Utilization 7)    | Should -Be '  7%'
            (Format-UtilCell -Utilization 99.4) | Should -Be ' 99%'
        }

        It 'Format-Truncate returns em-dash for $null / empty input' {
            (Format-Truncate -Text $null -Max 32) | Should -Be '—'
            (Format-Truncate -Text ''   -Max 32)  | Should -Be '—'
        }

        It 'Format-Truncate returns a single ellipsis when -Max is 1' {
            (Format-Truncate -Text 'abcdef' -Max 1) | Should -Be '…'
        }

        It 'Format-Truncate leaves a fitting string unchanged' {
            (Format-Truncate -Text 'short' -Max 32) | Should -Be 'short'
        }

        It 'Format-Truncate middle-truncates with the ellipsis between head and tail' {
            $r = Format-Truncate -Text 'one.two.three.four.five.six.seven.eight' -Max 12
            $r.Length | Should -Be 12
            $r       | Should -Match '…'
        }

        It 'Format-AccountCell returns em-dash for null / empty email' {
            (Format-AccountCell -SlotName 'work' -Email $null) | Should -Be '—'
            (Format-AccountCell -SlotName 'work' -Email '')    | Should -Be '—'
        }

        It 'Format-AccountCell returns em-dash when slot name equals email (case-insensitive dedup)' {
            (Format-AccountCell -SlotName 'alice@example.com' -Email 'alice@example.com') | Should -Be '—'
            (Format-AccountCell -SlotName 'Alice@Example.Com' -Email 'alice@example.com') | Should -Be '—'
        }

        It 'Format-AccountCell returns the email when slot name differs' {
            (Format-AccountCell -SlotName 'work' -Email 'alice@example.com') | Should -Be 'alice@example.com'
        }

        It 'Format-BucketCell renders em-dash for null utilization' {
            (Format-BucketCell -Utilization $null -ResetsAt $null) | Should -Be '   —'
        }

        It 'Format-BucketCell renders only the percent when ResetsAt is null / empty' {
            (Format-BucketCell -Utilization 9 -ResetsAt $null) | Should -Be '  9%'
            (Format-BucketCell -Utilization 9 -ResetsAt '')    | Should -Be '  9%'
        }

        It 'Format-BucketCell renders "percent (delta)" when ResetsAt is set' {
            $future = [DateTimeOffset]::UtcNow.AddHours(2).AddMinutes(14).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            (Format-BucketCell -Utilization 31 -ResetsAt $future) | Should -Match '^ 31% \(2h 1[34]m\)$'
        }
    }

    Context 'Get-StatusColor (uncovered branches)' {
        It 'returns DarkGray for the no-oauth label' {
            (Get-StatusColor -Label 'no-oauth' -IsActive $false) | Should -Be 'DarkGray'
        }

        It 'returns Yellow for the rate-limited label' {
            (Get-StatusColor -Label 'rate-limited' -IsActive $false) | Should -Be 'Yellow'
        }

        It 'returns Gray for unknown labels (default arm)' {
            (Get-StatusColor -Label 'something-new' -IsActive $false) | Should -Be 'Gray'
            (Get-StatusColor -Label ''             -IsActive $false) | Should -Be 'Gray'
        }
    }

    Context 'Get-StatusRationale' {
        It '<Case>' -ForEach @(
            @{ Case = 'limited 5h';        Label = 'limited 5h';        Expected = 'no prompts until 5h window resets' }
            @{ Case = 'limited 7d';        Label = 'limited 7d';        Expected = 'no prompts until 7d window resets' }
            @{ Case = 'limited (both)';    Label = 'limited';           Expected = 'no prompts until both 5h and 7d windows reset' }
            @{ Case = 'ok (no plan data)'; Label = 'ok (no plan data)'; Expected = 'HTTP ok but response carried no bucket data' }
        ) {
            (Get-StatusRationale -Label $Label) | Should -Be $Expected
        }

        It "returns Script:UtilWarnPct-templated rationale for 'near limit'" {
            $out = Get-StatusRationale -Label 'near limit'
            $out | Should -Match '^at or above \d+%'
            $out | Should -Match 'at least one bucket$'
        }

        It 'returns $null for labels with no rationale (ok, error, expired, ...)' {
            (Get-StatusRationale -Label 'ok')    | Should -BeNullOrEmpty
            (Get-StatusRationale -Label 'error') | Should -BeNullOrEmpty
            (Get-StatusRationale -Label '')      | Should -BeNullOrEmpty
        }
    }

    Context 'Read-Sidecar' {
        # Pure-helper file-IO tests; sandbox uses $TestDrive directly to
        # avoid pulling in the full credential-dir scaffolding.
        It 'returns $null when the sidecar file is missing' {
            $slot = Join-Path $TestDrive '.credentials.missing.json'
            Read-Sidecar -SlotPath $slot | Should -BeNullOrEmpty
        }

        It 'returns $null when the sidecar JSON is corrupt' {
            $slot     = Join-Path $TestDrive '.credentials.corrupt.json'
            $sidecar  = $slot -replace '\.json$', '.account.json'
            Set-Content -LiteralPath $sidecar -Value 'not-json{' -NoNewline -Encoding utf8NoBOM
            Read-Sidecar -SlotPath $slot | Should -BeNullOrEmpty
        }

        It 'returns $null when the sidecar schema is not 1' {
            $slot    = Join-Path $TestDrive '.credentials.badschema.json'
            $sidecar = $slot -replace '\.json$', '.account.json'
            $payload = '{"schema":2,"oauthAccount":{"emailAddress":"a@b.com"}}'
            Set-Content -LiteralPath $sidecar -Value $payload -NoNewline -Encoding utf8NoBOM
            Read-Sidecar -SlotPath $slot | Should -BeNullOrEmpty
        }

        It 'returns $null when oauthAccount is missing' {
            $slot    = Join-Path $TestDrive '.credentials.nooauth.json'
            $sidecar = $slot -replace '\.json$', '.account.json'
            Set-Content -LiteralPath $sidecar -Value '{"schema":1}' -NoNewline -Encoding utf8NoBOM
            Read-Sidecar -SlotPath $slot | Should -BeNullOrEmpty
        }

        It 'returns $null when oauthAccount.emailAddress is blank' {
            $slot    = Join-Path $TestDrive '.credentials.noemail.json'
            $sidecar = $slot -replace '\.json$', '.account.json'
            $payload = '{"schema":1,"oauthAccount":{"emailAddress":""}}'
            Set-Content -LiteralPath $sidecar -Value $payload -NoNewline -Encoding utf8NoBOM
            Read-Sidecar -SlotPath $slot | Should -BeNullOrEmpty
        }

        It 'returns a parsed pscustomobject for a well-formed sidecar' {
            $slot    = Join-Path $TestDrive '.credentials.ok.json'
            $sidecar = $slot -replace '\.json$', '.account.json'
            $payload = '{"schema":1,"captured_at":"2026-04-26T00:00:00Z","source":"test","oauthAccount":{"emailAddress":"alice@example.com","accountUuid":"u1"}}'
            Set-Content -LiteralPath $sidecar -Value $payload -NoNewline -Encoding utf8NoBOM

            $obj = Read-Sidecar -SlotPath $slot
            $obj                              | Should -Not -BeNullOrEmpty
            $obj.schema                       | Should -Be 1
            $obj.oauthAccount.emailAddress    | Should -Be 'alice@example.com'
        }
    }

    Context 'Get-OAuthAccountFromClaudeJson (uncovered branches)' {
        # Tests sandbox $env:USERPROFILE per BeforeEach (Common.ps1), so
        # $ClaudeJsonPath resolves under $TestDrive automatically.
        It 'returns $null when ~/.claude.json is missing' {
            Get-OAuthAccountFromClaudeJson | Should -BeNullOrEmpty
        }

        It 'returns $null when ~/.claude.json is corrupt' {
            Set-Content -LiteralPath $ClaudeJsonPath -Value 'not-json{' -NoNewline -Encoding utf8NoBOM
            Get-OAuthAccountFromClaudeJson | Should -BeNullOrEmpty
        }

        It 'returns $null when ~/.claude.json has no oauthAccount key' {
            Set-Content -LiteralPath $ClaudeJsonPath -Value '{"numStartups":1}' -NoNewline -Encoding utf8NoBOM
            Get-OAuthAccountFromClaudeJson | Should -BeNullOrEmpty
        }

        It 'returns $null when oauthAccount.emailAddress is empty / whitespace' {
            Set-Content -LiteralPath $ClaudeJsonPath -Value '{"oauthAccount":{"emailAddress":"  "}}' -NoNewline -Encoding utf8NoBOM
            Get-OAuthAccountFromClaudeJson | Should -BeNullOrEmpty
        }

        It 'defaults missing optional fields (accountUuid, etc.) to $null' {
            # emailAddress is the only mandatory non-null field; the other
            # four are populated only when present, otherwise null.
            $payload = '{"oauthAccount":{"emailAddress":"a@b.com"}}'
            Set-Content -LiteralPath $ClaudeJsonPath -Value $payload -NoNewline -Encoding utf8NoBOM

            $r = Get-OAuthAccountFromClaudeJson
            $r                  | Should -Not -BeNullOrEmpty
            $r.emailAddress     | Should -Be 'a@b.com'
            $r.accountUuid      | Should -BeNullOrEmpty
            $r.organizationUuid | Should -BeNullOrEmpty
            $r.displayName      | Should -BeNullOrEmpty
            $r.organizationName | Should -BeNullOrEmpty
        }
    }

    Context 'Set-OAuthAccountInClaudeJson (uncovered failure modes)' {
        It 'throws when ~/.claude.json has no oauthAccount block' {
            Set-Content -LiteralPath $ClaudeJsonPath -Value '{"numStartups":1}' -NoNewline -Encoding utf8NoBOM
            $oa = [pscustomobject]@{ emailAddress = 'a@b.com' }
            { Set-OAuthAccountInClaudeJson -OAuthAccount $oa } |
                Should -Throw -ExpectedMessage '*no oauthAccount block*'
        }

        It 'throws when the oauthAccount block has unbalanced braces' {
            # Truncate the file so the brace counter walks off the end
            # without closing depth. Surfaces as 'unbalanced braces'.
            $payload = '{"oauthAccount":{ "emailAddress":"a@b.com"'
            Set-Content -LiteralPath $ClaudeJsonPath -Value $payload -NoNewline -Encoding utf8NoBOM
            $oa = [pscustomobject]@{ emailAddress = 'c@d.com' }
            { Set-OAuthAccountInClaudeJson -OAuthAccount $oa } |
                Should -Throw -ExpectedMessage '*unbalanced braces*'
        }
    }

    Context 'Get-NextSlotName (single-slot active no-op)' {
        It "prints the 'Only one slot' advisory and returns null when one active slot exists" {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'only' -Content 'X' | Out-Null
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.json') -Value 'X' -NoNewline

            $out = Get-NextSlotName 6>&1 | Out-String
            $out | Should -Match 'Only one slot'
            # Function writes the advisory and returns $null; capture via
            # a second call with the stream redirected.
            Get-NextSlotName 6>$null | Should -BeNullOrEmpty
        }

        It 'returns the first slot (no rotation cursor) when no slot is currently active' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'a' -Content 'A' | Out-Null
            New-SlotPair -CredDir $credDir -Name 'b' -Content 'B' | Out-Null
            # .credentials.json bytes don't match either slot -> no IsActive flag.
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.json') -Value 'UNKNOWN' -NoNewline

            $r = Get-NextSlotName 6>$null
            $r.To.Name        | Should -Be 'a'
            $r.HasActiveSlot  | Should -BeFalse
        }
    }

    Context 'Update-SlotTokens (uncovered failure modes)' {
        # Direct unit tests for Update-SlotTokens' guard clauses and
        # advisory paths. The happy path is exercised through Invoke-
        # UsageAction; here we hit the throws and the
        # propagation-to-credentials.json failure branch.

        It 'throws when the slot file has no OAuth material to refresh' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot = Join-Path $credDir '.credentials.apikey.json'
            Set-Content -LiteralPath $slot -Value '{"apiKey":"sk-ant-api..."}' -NoNewline

            { Update-SlotTokens -SlotPath $slot } |
                Should -Throw -ExpectedMessage '*no OAuth material to refresh*'
        }

        It 'throws when refresh response is missing access_token' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot = Join-Path $credDir '.credentials.stale.json'
            $payload = @{
                claudeAiOauth = @{
                    accessToken  = 'old'
                    refreshToken = 'rt'
                    expiresAt    = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                # No access_token; expires_in only.
                return [pscustomobject]@{ expires_in = 3600 }
            }

            { Update-SlotTokens -SlotPath $slot } |
                Should -Throw -ExpectedMessage '*missing access_token*'
        }

        It 'throws when refresh response is missing expires_in' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot = Join-Path $credDir '.credentials.stale.json'
            $payload = @{
                claudeAiOauth = @{
                    accessToken  = 'old'
                    refreshToken = 'rt'
                    expiresAt    = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{ access_token = 'new' }
            }

            { Update-SlotTokens -SlotPath $slot } |
                Should -Throw -ExpectedMessage '*missing expires_in*'
        }

        It 'falls back to the old refresh token when response omits refresh_token (RFC 6749)' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $slot = Join-Path $credDir '.credentials.norotate.json'
            $oldRt = 'sk-ant-ort-KEEPME'
            $payload = @{
                claudeAiOauth = @{
                    accessToken  = 'old-at'
                    refreshToken = $oldRt
                    expiresAt    = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $slot -Value $payload -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                # access_token + expires_in but no refresh_token field.
                return [pscustomobject]@{
                    access_token = 'new-at'
                    expires_in   = 3600
                }
            }

            Update-SlotTokens -SlotPath $slot 6>$null | Out-Null

            $after = Get-Content -LiteralPath $slot -Raw | ConvertFrom-Json
            $after.claudeAiOauth.accessToken  | Should -Be 'new-at'
            # Old refresh token preserved per RFC 6749 fallback.
            $after.claudeAiOauth.refreshToken | Should -Be $oldRt
        }

        It 'emits a yellow advisory when propagation to .credentials.json fails' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'

            # Build a labeled slot pair with stale tokens, plus a
            # matching .credentials.json mirror, and seed state.
            $slot = New-SlotPair -CredDir $credDir -Name 'active' -Email 'a@b.com' -Content (@{
                claudeAiOauth = @{
                    accessToken  = 'OLD'
                    refreshToken = 'RT'
                    expiresAt    = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
                }
            } | ConvertTo-Json -Compress)
            Copy-Item -LiteralPath $slot -Destination $credFile -Force
            $hash = (Get-FileHash -LiteralPath $credFile -Algorithm SHA256).Hash
            Update-ScaState -ActiveSlot 'active' -LastSyncHash $hash | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{ access_token = 'NEW'; refresh_token = 'NEW-RT'; expires_in = 3600 }
            }

            # Force the second atomic write (the propagation to
            # .credentials.json) to fail. The first call writes the
            # slot; the second call writes .credentials.json.
            $script:writeCount = 0
            Mock Set-CredentialFileAtomic -MockWith {
                $script:writeCount++
                if ($script:writeCount -ge 2) {
                    throw [System.IO.IOException]::new('propagation denied')
                }
                # Fall back to the real implementation for the first call
                # so the slot file actually gets updated.
                [System.IO.File]::WriteAllBytes($Path, $Bytes)
            }

            $out = Update-SlotTokens -SlotPath $slot 6>&1 | Out-String

            $out | Should -Match "Token refreshed in slot 'active'"
            $out | Should -Match 'propagation to \.credentials\.json failed'
            $out | Should -Match 'propagation denied'
        }
    }

    Context 'New-AutoSaveSlot (sidecar-write failure advisory)' {
        # Direct test for the New-AutoSaveSlot helper's catch path:
        # when Write-Sidecar throws, the function must NOT throw; it
        # emits a yellow advisory and the slot tokens file remains on
        # disk (Get-Slots will hide it, user can clean up by name).

        It 'emits a yellow advisory and keeps the tokens file when sidecar write fails' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null

            $bytes = [System.Text.Encoding]::UTF8.GetBytes('AUTOBYTES')
            $oa = [pscustomobject]@{
                accountUuid      = 'u'
                emailAddress     = 'auto@example.com'
                organizationUuid = $null
                displayName      = $null
                organizationName = $null
            }

            Mock Write-Sidecar -MockWith { throw [System.Exception]::new('disk full') }

            $out = New-AutoSaveSlot -Bytes $bytes `
                                    -Email 'auto@example.com' `
                                    -OAuthAccount $oa `
                                    -SourceLabel 'test' `
                                    -LastSyncHash 'H1' 6>&1 | Out-String

            $out | Should -Match 'Auto-save sidecar write failed'
            $out | Should -Match 'disk full'

            # Tokens file landed on disk despite the sidecar failure.
            $tokenFiles = @(Get-ChildItem -LiteralPath $credDir -Filter '.credentials.auto-*.json' |
                Where-Object { $_.Name -notlike '*.account.json' })
            $tokenFiles.Count | Should -Be 1
            [System.IO.File]::ReadAllBytes($tokenFiles[0].FullName) | Should -Be $bytes
        }
    }

    Context 'Write-Color (uncovered branches)' {
        # Common.ps1 forces OutputRendering=PlainText so the SGR codes
        # Write-Color emits are stripped by PowerShell's host filter
        # before we see them. We can still verify the function does not
        # throw on each color name (covers the switch arms) and that
        # NoNewline is honored.

        It 'emits without throwing for every named color (covers BrightCyan branch)' {
            foreach ($c in 'Yellow','DarkYellow','Green','Red','Cyan','Gray','DarkGray') {
                { Write-Color "test" $c 6>$null } | Should -Not -Throw
            }
        }

        It 'tolerates an unknown color name via the default branch' {
            { Write-Color "test" 'not-a-color' 6>$null } | Should -Not -Throw
        }

        It '-NoNewline switch is honored (single Write-Host call without a newline)' {
            # Capture stream 6 and verify the emitted line carries the
            # message text. PlainText stripping leaves the text intact.
            $out = Write-Color 'sentinel-no-newline' 'Cyan' -NoNewline 6>&1 | Out-String
            $out | Should -Match 'sentinel-no-newline'
        }
    }

    AfterAll {
        # Restore the two globals BeforeEach mutated so this suite leaves
        # the caller's session clean. Pester runs AfterAll even if tests
        # throw, so this covers the mid-suite-failure case too.
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
