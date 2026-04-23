#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 test suite for switch_claude_account.ps1.
#
# Sandboxing: each test runs with $env:USERPROFILE pointed at $TestDrive and
# $PROFILE.CurrentUserAllHosts stubbed to a file inside $TestDrive. The script
# is dot-sourced after setting those globals; its dot-source guard
# (`if ($MyInvocation.InvocationName -ne '.')`) prevents Invoke-Main from
# running, so we can exercise individual internal functions directly without
# spawning a subprocess.
#
# All top-level Describe blocks are nested inside a single outer Describe
# so a single BeforeEach can feed them all. Pester 5 forbids BeforeEach at
# file root.

BeforeAll {
    $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\switch_claude_account.ps1')).Path
}

Describe 'switch_claude_account' {

    BeforeEach {
        # Fresh sandbox per test: isolated user profile + fake PS profile path.
        # $TestDrive is persistent within a Describe/Context in Pester 5, so
        # we explicitly wipe the sandbox to prevent test-to-test leakage.
        $script:SandboxHome = Join-Path $TestDrive 'home'
        if (Test-Path -LiteralPath $script:SandboxHome) {
            Remove-Item -LiteralPath $script:SandboxHome -Recurse -Force
        }
        New-Item -ItemType Directory -Path $script:SandboxHome -Force | Out-Null
        $env:USERPROFILE = $script:SandboxHome

        $script:FakeProfilePath = Join-Path $TestDrive 'profile.ps1'
        if (Test-Path -LiteralPath $script:FakeProfilePath) {
            Remove-Item -LiteralPath $script:FakeProfilePath -Force
        }
        $global:PROFILE = [pscustomobject]@{ CurrentUserAllHosts = $script:FakeProfilePath }

        # Dot-sourcing rebinds script-scope $CredDir / $CredFile / $ProfilePath
        # against the sandboxed environment. The dot-source guard stops
        # Invoke-Main from running, so tests drive individual functions.
        . $script:ScriptPath
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

    Context 'Test-IsMarkerLine' {
        It '<Case>' -ForEach @(
            @{ Case = 'exact match';         Line = '# === X ===';        Expected = $true  }
            @{ Case = 'leading whitespace';  Line = '   # === X ===';     Expected = $true  }
            @{ Case = 'trailing whitespace'; Line = '# === X ===   ';     Expected = $true  }
            @{ Case = 'tabs around';         Line = "`t# === X ===`t";    Expected = $true  }
            @{ Case = 'different case';      Line = '# === x ===';        Expected = $false }
            @{ Case = 'empty';               Line = '';                   Expected = $false }
            @{ Case = 'substring only';      Line = 'echo "# === X ==="'; Expected = $false }
            @{ Case = 'marker with suffix';  Line = '# === X === extra';  Expected = $false }
        ) {
            Test-IsMarkerLine -Line $Line -Marker '# === X ===' | Should -Be $Expected
        }

        It 'returns false for $null' {
            Test-IsMarkerLine -Line $null -Marker '# === X ===' | Should -BeFalse
        }
    }

    Context 'Invoke-SaveAction' {
        It 'copies active credentials to named slot byte-for-byte' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            [System.IO.File]::WriteAllBytes($credFile, [byte[]](0x7B,0x22,0x74,0x22,0x3A,0x31,0x7D))

            Invoke-SaveAction -Name 'work' 6>$null

            $slot = Join-Path $credDir '.credentials.work.json'
            Test-Path $slot | Should -BeTrue
            [System.IO.File]::ReadAllBytes($slot) | Should -Be ([System.IO.File]::ReadAllBytes($credFile))
        }

        It 'throws when active credentials file is missing' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null

            { Invoke-SaveAction -Name 'work' 6>$null } | Should -Throw -ExpectedMessage '*not found. Log in*'
        }

        It 'sanitizes the slot name before creating the file' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            Set-Content -LiteralPath $credFile -Value '{"t":1}' -NoNewline

            Invoke-SaveAction -Name 'my work' 6>$null

            Test-Path (Join-Path $credDir '.credentials.my_work.json') | Should -BeTrue
        }

        It 'overwrites an existing slot file' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            $slot     = Join-Path $credDir '.credentials.work.json'
            Set-Content -LiteralPath $credFile -Value 'NEW' -NoNewline
            Set-Content -LiteralPath $slot     -Value 'OLD' -NoNewline

            Invoke-SaveAction -Name 'work' 6>$null

            Get-Content -LiteralPath $slot -Raw | Should -Be 'NEW'
        }
    }

    Context 'Invoke-SwitchAction' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
        }

        It 'copies named slot to active credentials byte-for-byte' {
            $slot = Join-Path $script:CredDirPath '.credentials.work.json'
            [System.IO.File]::WriteAllBytes($slot, [byte[]](0xDE,0xAD,0xBE,0xEF))

            Invoke-SwitchAction -Name 'work' 6>$null

            [System.IO.File]::ReadAllBytes($script:CredFilePath) | Should -Be ([byte[]](0xDE,0xAD,0xBE,0xEF))
        }

        It 'throws when the named slot does not exist' {
            { Invoke-SwitchAction -Name 'missing' 6>$null } | Should -Throw -ExpectedMessage "*Slot 'missing' not found*"
        }

        It 'overwrites an existing active credentials file' {
            $slot = Join-Path $script:CredDirPath '.credentials.work.json'
            Set-Content -LiteralPath $slot                -Value 'NEW' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath -Value 'OLD' -NoNewline

            Invoke-SwitchAction -Name 'work' 6>$null

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'NEW'
        }

        It 'rotates to the next slot alphabetically when called without a name' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.a.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.b.json') -Value 'B' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.c.json') -Value 'C' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                  -Value 'B' -NoNewline

            Invoke-SwitchAction -Name '' 6>$null

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'C'
        }

        It 'rotation wraps from the last slot back to the first' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.a.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.b.json') -Value 'B' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                  -Value 'B' -NoNewline

            Invoke-SwitchAction -Name '' 6>$null

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'A'
        }

        It 'rotation throws when no slots are saved' {
            { Invoke-SwitchAction -Name '' 6>$null } | Should -Throw -ExpectedMessage '*No slots saved*'
        }

        It 'rotation is a no-op when only one slot exists and it is active' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.only.json') -Value 'X' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                     -Value 'X' -NoNewline

            { Invoke-SwitchAction -Name '' 6>$null } | Should -Not -Throw

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'X'
        }

        It 'rotation falls back to first slot when active file does not match any slot' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.a.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.b.json') -Value 'B' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                  -Value 'UNKNOWN' -NoNewline

            Invoke-SwitchAction -Name '' 6>$null

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'A'
        }
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

            $out | Should -Match 'alpha'
            $out | Should -Match '\* bravo \(active\)'
        }

        It 'lists slots without * when no active file exists' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match 'alpha'
            $out | Should -Not -Match '\(active\)'
        }

        It 'excludes .credentials.json itself from the slot listing' {
            Set-Content -LiteralPath $script:CredFilePath                                      -Value 'X' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.work.json') -Value 'W' -NoNewline

            $out = Invoke-ListAction 6>&1 | Out-String

            $out | Should -Match 'work'
            # A raw ".credentials" entry would show as an empty slot name;
            # make sure none of that leaks through.
            $out | Should -Not -Match '(?m)^\s*\*?\s{3}\s*\(active\)'
        }
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
    }

    Context 'Add-To-Profile / Remove-From-Profile' {
        It 'install creates the profile and writes both markers' {
            Add-To-Profile 6>$null

            Test-Path -LiteralPath $script:FakeProfilePath | Should -BeTrue
            $content = Get-Content -LiteralPath $script:FakeProfilePath -Raw
            $content | Should -Match '# === Claude Account Switcher ==='
            $content | Should -Match '# === End Claude Account Switcher ==='
            $content | Should -Match 'switch_claude_account_caller'
            $content | Should -Match 'Set-Alias -Name sca'
            $content | Should -Match 'Set-Alias -Name switch-claude-account'
        }

        It 'install separates the block with a blank line when profile is non-empty' {
            # Pre-existing content ends in \r\n. Add-To-Profile prepends another
            # \r\n to its block, producing a blank line between the two.
            Set-Content -LiteralPath $script:FakeProfilePath -Value "Write-Host 'existing'`r`n" -NoNewline

            Add-To-Profile 6>$null

            $content = Get-Content -LiteralPath $script:FakeProfilePath -Raw
            $content | Should -Match "existing'\r?\n\r?\n# === Claude Account Switcher ==="
        }

        It 'install is byte-idempotent (two runs produce identical files)' {
            Add-To-Profile 6>$null
            $bytes1 = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            Add-To-Profile 6>$null
            $bytes2 = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            $bytes1.Length | Should -Be $bytes2.Length
            for ($i = 0; $i -lt $bytes1.Length; $i++) {
                if ($bytes1[$i] -ne $bytes2[$i]) {
                    throw "Byte mismatch at offset $i"
                }
            }
        }

        It 'install + uninstall round-trip preserves pre-existing UTF-8 content byte-for-byte' {
            $pre = "# my profile`r`nWrite-Host 'hello'`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $pre -Encoding utf8NoBOM -NoNewline
            $preBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            Add-To-Profile 6>$null
            Remove-From-Profile 6>$null

            $postBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            $postBytes.Length | Should -Be $preBytes.Length
            for ($i = 0; $i -lt $preBytes.Length; $i++) {
                if ($preBytes[$i] -ne $postBytes[$i]) {
                    throw "Byte mismatch at offset $i"
                }
            }
        }

        It 'install + uninstall round-trip preserves UTF-16 LE BOM and content' {
            $pre = "# umlauts: ä ö ü`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $pre -Encoding unicode -NoNewline
            $preBom = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)[0..1]

            Add-To-Profile 6>$null
            Remove-From-Profile 6>$null

            $postBom = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)[0..1]
            $postBom[0] | Should -Be $preBom[0]
            $postBom[1] | Should -Be $preBom[1]

            $post = Get-Content -LiteralPath $script:FakeProfilePath -Encoding unicode -Raw
            $post | Should -Match 'ä ö ü'
            $post | Should -Not -Match 'Claude Account Switcher'
        }

        It 'install + uninstall round-trip preserves UTF-8 with BOM' {
            $pre = "# bom test`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $pre -Encoding utf8BOM -NoNewline

            Add-To-Profile 6>$null
            Remove-From-Profile 6>$null

            $postBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            $postBytes[0] | Should -Be 0xEF
            $postBytes[1] | Should -Be 0xBB
            $postBytes[2] | Should -Be 0xBF

            $post = Get-Content -LiteralPath $script:FakeProfilePath -Raw
            $post | Should -Match 'bom test'
            $post | Should -Not -Match 'Claude Account Switcher'
        }

        It 'uninstall throws and leaves file byte-identical when only start marker is present' {
            $orphan = "# stuff`r`n# === Claude Account Switcher ===`r`nWrite-Host 'dangling'`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $orphan -Encoding utf8NoBOM -NoNewline
            $before = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            { Remove-From-Profile 6>$null } | Should -Throw -ExpectedMessage '*orphan*'

            $after = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            $after.Length | Should -Be $before.Length
            for ($i = 0; $i -lt $before.Length; $i++) {
                if ($before[$i] -ne $after[$i]) {
                    throw "Byte mismatch at offset $i"
                }
            }
        }

        It 'uninstall throws when only end marker is present' {
            $orphan = "# stuff`r`n# === End Claude Account Switcher ===`r`nWrite-Host 'x'`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $orphan -Encoding utf8NoBOM -NoNewline

            { Remove-From-Profile 6>$null } | Should -Throw -ExpectedMessage '*orphan*'
        }

        It 'uninstall on a profile without our block is a no-op' {
            $content = "# user profile`r`nWrite-Host 'unchanged'`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $content -Encoding utf8NoBOM -NoNewline
            $before = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            { Remove-From-Profile 6>$null } | Should -Not -Throw

            $after = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            $after.Length | Should -Be $before.Length
            for ($i = 0; $i -lt $before.Length; $i++) {
                if ($before[$i] -ne $after[$i]) {
                    throw "Byte mismatch at offset $i"
                }
            }
        }
    }

    Context 'Show-Help' {
        It 'prints the ACTIONS header and lists all 7 actions' {
            $out = Show-Help 6>&1 | Out-String

            $out | Should -Match 'ACTIONS'
            $out | Should -Match 'save <name>'
            $out | Should -Match 'switch \[name\]'
            $out | Should -Match 'list'
            $out | Should -Match 'remove <name>'
            $out | Should -Match 'install'
            $out | Should -Match 'uninstall'
            $out | Should -Match 'help, -h'
        }
    }
}
