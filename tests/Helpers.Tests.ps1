#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for the small pure-helper functions in
# switch_claude_account.ps1: Get-SafeName, Get-ProfileEncoding, Get-Slots,
# Get-SlotFileInfo, Show-Help.
#
# Per-test sandbox setup lives in tests/Common.ps1; see that file for the
# scoping rationale. Each top-level Describe must wrap a BeforeEach (Pester 5
# forbids BeforeEach at file root), so all Contexts in this file nest under
# one outer Describe named 'switch_claude_account' — same name as the other
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

            $info   = Get-Slots
            $active = @($info.Slots | Where-Object { $_.IsActive })

            $active.Count    | Should -Be 1
            $active[0].Name  | Should -Be 'foo[bar]'
        }

        # One-time migration from the pre-filename-encoding version:
        # Get-Slots opportunistically sweeps away any leftover
        # `.credentials.*.profile.json` sidecar files from the previous
        # cache-based implementation. Runs on every call but is cheap
        # once the directory is clean.
        It 'silently removes orphan .profile.json sidecars on first enumeration' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'work' -Content 'W' | Out-Null
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.work.profile.json') -Value '{"email":"w@x"}' -NoNewline
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.profile.json')      -Value '{"email":"a@x"}' -NoNewline

            $info  = Get-Slots
            $names = @($info.Slots | ForEach-Object Name)

            # Saved slot is enumerated (unlabeled form).
            $names | Should -Be @('work')
            # Sidecars have been silently removed during enumeration.
            Test-Path -LiteralPath (Join-Path $credDir '.credentials.work.profile.json') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $credDir '.credentials.profile.json')      | Should -BeFalse
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

            $slots = @((Get-Slots).Slots)
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
            # Bare slot file, no sidecar — invisible by design.
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.legacy.json') -Value 'L' -NoNewline
            # Properly paired slot — visible.
            New-SlotPair -CredDir $credDir -Name 'modern' -Content 'M' | Out-Null

            $names = @((Get-Slots).Slots | ForEach-Object Name)
            $names | Should -Be @('modern')
            $names | Should -Not -Contain 'legacy'
        }

        # New: sidecar files themselves must not be enumerated as slots.
        It 'does not enumerate .account.json sidecar files as slot credentials' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-SlotPair -CredDir $credDir -Name 'work' -Content 'W' | Out-Null

            $names = @((Get-Slots).Slots | ForEach-Object Name)
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
        # The title carries only "two numbers + brand suffix" by design
        # (KISS) — every richer signal already lives in the watch body.
        # These tests pin the format string and the pool-mean formula so
        # a future refactor cannot silently start emitting status words,
        # slot names, or reset countdowns into the title.

        # Build a minimal Get-UsageSnapshot-shaped object for a list of
        # rows. Each row hashtable accepts: Status, FiveUtil, SevenUtil
        # (any field omitted defaults to ok / null).
        function script:New-FakeSnapshot {
            Param ([object[]] $Rows)
            $results = foreach ($r in $Rows) {
                $five  = if ($r.ContainsKey('FiveUtil'))  { $r.FiveUtil }  else { $null }
                $seven = if ($r.ContainsKey('SevenUtil')) { $r.SevenUtil } else { $null }
                [pscustomobject]@{
                    Name     = if ($r.ContainsKey('Name')) { $r.Name } else { 'slot-x' }
                    Status   = if ($r.ContainsKey('Status')) { $r.Status } else { 'ok' }
                    IsActive = $false
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

        It 'renders both buckets present (single-slot)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 34; SevenUtil = 42 })
            Format-WatchTitle -Name 'slot-1' -Snapshot $snap |
                Should -Be '34% | 42% | Switch Claude Account'
        }

        It 'rounds fractional utilization to nearest integer' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = 33.6; SevenUtil = 41.4 })
            Format-WatchTitle -Name 'slot-1' -Snapshot $snap |
                Should -Be '34% | 41% | Switch Claude Account'
        }

        It 'renders em-dash for null buckets (single-slot, mixed null)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = $null; SevenUtil = 42 })
            Format-WatchTitle -Name 'slot-1' -Snapshot $snap |
                Should -Be '— | 42% | Switch Claude Account'
        }

        It 'renders bare suffix when both buckets null (single-slot)' {
            $snap = New-FakeSnapshot -Rows @(@{ FiveUtil = $null; SevenUtil = $null })
            # Single-slot null/null still renders the em-dashes; bare
            # suffix is reserved for "no usable rows at all" (no slots /
            # all-error). Documents the intended distinction.
            Format-WatchTitle -Name 'slot-1' -Snapshot $snap |
                Should -Be '— | — | Switch Claude Account'
        }

        It 'returns bare suffix for empty snapshot (no slots saved)' {
            $empty = [pscustomobject]@{ Results = @(); NoSlots = $true; HasCacheFallback = $false }
            Format-WatchTitle -Name '' -Snapshot $empty |
                Should -Be 'Switch Claude Account'
        }

        It 'returns bare suffix when all rows are HTTP-failure (multi-slot)' {
            $snap = New-FakeSnapshot -Rows @(
                @{ Status = 'expired'; FiveUtil = 10; SevenUtil = 10 }
                @{ Status = 'error';   FiveUtil = 20; SevenUtil = 20 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be 'Switch Claude Account'
        }

        It 'computes pool mean across HTTP-ok rows (multi-slot)' {
            # 50 + 100 over N=2 → mean 75% Session, 0 + 40 → mean 20% Week
            $snap = New-FakeSnapshot -Rows @(
                @{ FiveUtil = 50;  SevenUtil = 0 }
                @{ FiveUtil = 100; SevenUtil = 40 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '75% | 20% | Switch Claude Account'
        }

        It 'pool mean ignores non-ok rows but counts null buckets as 0' {
            # Two ok rows (one with null Week → 0 used in pool), one
            # error row excluded entirely. Five: (60 + 90) / 200 = 75%.
            # Week: (40 + 0) / 200 = 20%.
            $snap = New-FakeSnapshot -Rows @(
                @{ FiveUtil = 60;  SevenUtil = 40 }
                @{ FiveUtil = 90;  SevenUtil = $null }
                @{ Status = 'expired'; FiveUtil = 100; SevenUtil = 100 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '75% | 20% | Switch Claude Account'
        }

        It 'pool mean clamps per-slot utilization to [0, 100]' {
            # Anomalous 150% from the API is clamped to 100 before pool
            # averaging — mirrors Format-AggregateBars semantics.
            $snap = New-FakeSnapshot -Rows @(
                @{ FiveUtil = 150; SevenUtil = -10 }
                @{ FiveUtil = 50;  SevenUtil = 50 }
            )
            Format-WatchTitle -Name '' -Snapshot $snap |
                Should -Be '75% | 25% | Switch Claude Account'
        }

        It 'strips control bytes from the assembled title' {
            # Slot names already pass Get-SafeName, but the strip is
            # defense-in-depth against an OSC envelope breakout via a
            # tampered sidecar email or future caller path.
            $rows  = @([pscustomobject]@{
                Name = "x`e]0;EVIL`a"; Status = 'ok'; IsActive = $false; Email = $null
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
            # `e]0; opener — the renderer interpolation and BEL terminator
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

    AfterAll {
        # Restore the two globals BeforeEach mutated so this suite leaves
        # the caller's session clean. Pester runs AfterAll even if tests
        # throw, so this covers the mid-suite-failure case too.
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
