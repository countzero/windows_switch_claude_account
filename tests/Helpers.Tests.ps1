#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for the small pure-helper functions in
# switch_claude_account.ps1: Get-SafeName, Get-ProfileEncoding, Get-Slots,
# Get-SlotFileInfo, Test-HardlinkSupport, Show-Help.
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
        # hashed correctly so IsActive is true when that slot's content
        # matches the active credentials. Before the -LiteralPath fix,
        # Get-FileHash -Path wildcard-expanded the path and silently
        # mis-identified which slot was active (or threw).
        It 'marks a literal bracket slot as active when its hash matches .credentials.json' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.fooa.json')    -Value 'A'  -NoNewline
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.foo[bar].json') -Value 'BR' -NoNewline
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.json')         -Value 'BR' -NoNewline

            $info   = Get-Slots
            $active = @($info.Slots | Where-Object { $_.IsActive })

            $active.Count    | Should -Be 1
            $active[0].Name  | Should -Be 'foo[bar]'
            $info.ActiveLocked | Should -BeFalse
        }

        # One-time migration from the pre-filename-encoding version:
        # Get-Slots opportunistically sweeps away any leftover
        # `.credentials.*.profile.json` sidecar files from the previous
        # cache-based implementation. Runs on every call but is cheap
        # once the directory is clean.
        It 'silently removes orphan .profile.json sidecars on first enumeration' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.work.json')         -Value 'W'                -NoNewline
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
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.work(alice@example.com).json') -Value 'W' -NoNewline
            Set-Content -LiteralPath (Join-Path $credDir '.credentials.solo.json')                    -Value 'S' -NoNewline

            $slots = @((Get-Slots).Slots)
            $bySlotName = @{}
            foreach ($s in $slots) { $bySlotName[$s.Name] = $s }

            $bySlotName.ContainsKey('work') | Should -BeTrue
            $bySlotName['work'].Email       | Should -Be 'alice@example.com'
            $bySlotName.ContainsKey('solo') | Should -BeTrue
            $bySlotName['solo'].Email       | Should -BeNullOrEmpty
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
            @{ Case = 'labeled: dotted local-part';     File = '.credentials.work(finn.kumkar@stadtwerk.org).json';      SlotName = 'work';                  Email = 'finn.kumkar@stadtwerk.org' }
            @{ Case = 'dotted slot name + labeled';     File = '.credentials.work.backup(alice@example.com).json';       SlotName = 'work.backup';           Email = 'alice@example.com' }
            @{ Case = 'slot name is an email';          File = '.credentials.finn.kumkar@stadtwerk.org.json';            SlotName = 'finn.kumkar@stadtwerk.org'; Email = $null }
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

    Context 'Test-HardlinkSupport' {
        It 'does not throw and cleans up sentinel files on success' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null

            { Test-HardlinkSupport 6>$null } | Should -Not -Throw

            Join-Path $credDir '.scahardlink.source'  | Test-Path | Should -BeFalse
            Join-Path $credDir '.scahardlink.target'  | Test-Path | Should -BeFalse
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
    }

    AfterAll {
        # Restore the two globals BeforeEach mutated so this suite leaves
        # the caller's session clean. Pester runs AfterAll even if tests
        # throw, so this covers the mid-suite-failure case too.
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
