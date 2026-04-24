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

    # Capture the pre-suite values of the two globals BeforeEach mutates so
    # we can restore them in AfterAll. Without this, running Invoke-Pester
    # directly in an interactive shell (as the README suggests) would leave
    # the session's $env:USERPROFILE pointing at a deleted $TestDrive path
    # and $PROFILE as a PSCustomObject stub, which breaks later commands.
    # Running via the subprocess `pwsh -NoProfile -File tests/Invoke-Tests.ps1`
    # was already safe because the mutations died with the subprocess.
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE

    # Shared helper for install/uninstall round-trip tests. Throws with a
    # precise offset on first mismatch so Pester shows exactly where the
    # byte sequences diverge instead of a generic "not equal" failure.
    function Assert-BytesEqual ([byte[]] $Expected, [byte[]] $Actual) {
        $Actual.Length | Should -Be $Expected.Length
        for ($i = 0; $i -lt $Expected.Length; $i++) {
            if ($Expected[$i] -ne $Actual[$i]) {
                throw "Byte mismatch at offset $i"
            }
        }
    }
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

        # Default /api/oauth/profile mock: fails so rows have no email
        # and the two-line display short-circuits. Tests that exercise
        # email display override this with their own ParameterFilter
        # mock. The filter makes sure we do not accidentally swallow
        # usage/token-endpoint calls.
        Mock Invoke-RestMethod -ParameterFilter {
            $Uri -eq 'https://api.anthropic.com/api/oauth/profile'
        } -MockWith {
            throw [System.Exception]::new('profile endpoint unmocked in this test')
        }
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

        # Filename-encoded-email feature: on successful profile fetch
        # Invoke-SaveAction renames the slot file from
        #   .credentials.<slot>.json -> .credentials.<slot>(<email>).json
        # The hardlink from .credentials.json follows the inode through
        # the rename, so active-slot semantics are preserved.
        It 'writes the labeled filename when the profile fetch succeeds' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            Set-Content -LiteralPath $credFile -Value '{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"sk-ant-ort-x","expiresAt":9999999999999}}' -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'alice@example.com' }
                    organization = [pscustomobject]@{ name  = 'example'; organization_type = 'claude_team' }
                }
            }

            Invoke-SaveAction -Name 'work' 6>$null

            Test-Path -LiteralPath (Join-Path $credDir '.credentials.work(alice@example.com).json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $credDir '.credentials.work.json')                    | Should -BeFalse
            # Hardlink from .credentials.json survives the rename.
            (Get-Item -LiteralPath $credFile).LinkType | Should -Be 'HardLink'
        }

        It 'keeps the unlabeled filename when profile fetch fails (fail-open)' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            Set-Content -LiteralPath $credFile -Value '{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"sk-ant-ort-x","expiresAt":9999999999999}}' -NoNewline

            # The outer Describe's BeforeEach already mocks the profile
            # endpoint to throw; save must still succeed.
            Invoke-SaveAction -Name 'work' 6>$null

            Test-Path -LiteralPath (Join-Path $credDir '.credentials.work.json') | Should -BeTrue
            # No labeled file created.
            @(Get-ChildItem -LiteralPath $credDir -Filter '.credentials.work(*).json').Count | Should -Be 0
        }

        It 'dedups the label when slot name equals the resolved email' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            Set-Content -LiteralPath $credFile -Value '{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"sk-ant-ort-x","expiresAt":9999999999999}}' -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'alice@example.com' }
                    organization = [pscustomobject]@{ name  = 'example'; organization_type = 'claude_team' }
                }
            }

            Invoke-SaveAction -Name 'alice@example.com' 6>$null

            # Slot name == email -> no parenthesized suffix; file stays
            # at `.credentials.<email>.json`.
            Test-Path -LiteralPath (Join-Path $credDir '.credentials.alice@example.com.json') | Should -BeTrue
            @(Get-ChildItem -LiteralPath $credDir -Filter '.credentials.alice@example.com(*).json').Count | Should -Be 0
        }

        # When re-saving a slot whose account has changed (labeled form
        # differs), the old labeled file must be removed so we do not
        # accumulate one file per historical account under the same name.
        It 'removes a pre-existing labeled file when re-saving with a different email' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            $oldPath  = Join-Path $credDir '.credentials.work(old@example.com).json'
            Set-Content -LiteralPath $credFile -Value '{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"sk-ant-ort-x","expiresAt":9999999999999}}' -NoNewline
            Set-Content -LiteralPath $oldPath  -Value 'stale' -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'new@example.com' }
                    organization = [pscustomobject]@{ name  = 'example'; organization_type = 'claude_team' }
                }
            }

            Invoke-SaveAction -Name 'work' 6>$null

            Test-Path -LiteralPath $oldPath | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $credDir '.credentials.work(new@example.com).json') | Should -BeTrue
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

        # `sca switch <name>` must find the slot file whether it was saved
        # with the labeled form `.credentials.<slot>(<email>).json` or the
        # unlabeled form. User types the slot-name only; Find-SlotByName
        # resolves to the right file by parsing the filename.
        It 'finds a labeled slot file by slot-name only' {
            $labeled = Join-Path $script:CredDirPath '.credentials.work(alice@example.com).json'
            [System.IO.File]::WriteAllBytes($labeled, [byte[]](0xBE,0xEF))

            Invoke-SwitchAction -Name 'work' 6>$null

            [System.IO.File]::ReadAllBytes($script:CredFilePath) | Should -Be ([byte[]](0xBE,0xEF))
            (Get-Item -LiteralPath $script:CredFilePath).LinkType | Should -Be 'HardLink'
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

        # Regression: if a literal bracket-containing slot file exists on disk
        # (e.g., from a pre-sanitization version or manual placement), rotation
        # must land on it without PowerShell's -Path wildcard expansion
        # matching unrelated slots. Proves Test-Path and Copy-Item use
        # -LiteralPath on the target slot.
        It 'rotation onto a literal bracket slot copies the correct bytes' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.a.json')      -Value 'A'  -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.b[c].json')   -Value 'BC' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                       -Value 'A'  -NoNewline

            Invoke-SwitchAction -Name '' 6>$null

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'BC'
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
            # If the Where-Object filter in Get-Slots ever regresses,
            # .credentials.json itself leaks as a slot whose rendered name is
            # the literal '.credentials'. Anchor to the list-row shape
            # (leading ' * ' or '   ' indent) so this assertion catches the
            # leak without false-positiving on legitimate slot names.
            $out | Should -Not -Match '(?m)^\s*\*?\s+\.credentials(\s|$)'
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

            Assert-BytesEqual $bytes1 $bytes2
        }

        It 'install + uninstall round-trip preserves pre-existing UTF-8 content byte-for-byte' {
            $pre = "# my profile`r`nWrite-Host 'hello'`r`n"
            Set-Content -LiteralPath $script:FakeProfilePath -Value $pre -Encoding utf8NoBOM -NoNewline
            $preBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            Add-To-Profile 6>$null
            Remove-From-Profile 6>$null

            $postBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            Assert-BytesEqual $preBytes $postBytes
        }

        It 'install + uninstall round-trip preserves LF-only line endings byte-for-byte' {
            # Write raw bytes so PowerShell does not normalize LF to CRLF.
            $pre = "line1`nline2`n"
            [System.IO.File]::WriteAllBytes(
                $script:FakeProfilePath,
                [System.Text.Encoding]::UTF8.GetBytes($pre))
            $preBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            Add-To-Profile 6>$null
            Remove-From-Profile 6>$null

            $postBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            Assert-BytesEqual $preBytes $postBytes
        }

        It 'install + uninstall round-trip preserves mixed LF/CRLF line endings byte-for-byte' {
            $pre = "line1`r`nline2`nline3`r`n"
            [System.IO.File]::WriteAllBytes(
                $script:FakeProfilePath,
                [System.Text.Encoding]::UTF8.GetBytes($pre))
            $preBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)

            Add-To-Profile 6>$null
            Remove-From-Profile 6>$null

            $postBytes = [System.IO.File]::ReadAllBytes($script:FakeProfilePath)
            Assert-BytesEqual $preBytes $postBytes
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
            Assert-BytesEqual $before $after
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
            Assert-BytesEqual $before $after
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

    Context 'Invoke-SaveAction (hardlink)' {
        It 'creates a slot AND re-links .credentials.json as hardlink' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            Set-Content -LiteralPath $credFile -Value 'SAL' -NoNewline

            Invoke-SaveAction -Name 'work' 6>$null

            $slot  = Join-Path $credDir '.credentials.work.json'
            Test-Path $slot | Should -BeTrue
            (Get-Item -LiteralPath $credFile).LinkType | Should -Be 'HardLink'
            (Get-Item -LiteralPath $slot).LinkType       | Should -Be 'HardLink'
            Get-Content -LiteralPath $credFile -Raw | Should -Be 'SAL'
            Get-Content -LiteralPath $slot     -Raw | Should -Be 'SAL'
        }

        It 'overwrites an existing slot AND re-links .credentials.json' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            $slot     = Join-Path $credDir '.credentials.work.json'
            Set-Content -LiteralPath $credFile -Value 'NEW' -NoNewline
            Set-Content -LiteralPath $slot     -Value 'OLD' -NoNewline

            Invoke-SaveAction -Name 'work' 6>$null

            Get-Content -LiteralPath $credFile -Raw | Should -Be 'NEW'
            Get-Content -LiteralPath $slot     -Raw | Should -Be 'NEW'
            (Get-Item -LiteralPath $credFile).LinkType | Should -Be 'HardLink'
        }

        It 'migration: save when .credentials.json is a regular file produces hardlink' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            [System.IO.File]::WriteAllBytes($credFile, [byte[]](0x41,0x42))

            { Get-Item -LiteralPath $credFile }.LinkType | Should -Not -Be 'HardLink'

            Invoke-SaveAction -Name 'work' 6>$null

            (Get-Item -LiteralPath $credFile).LinkType | Should -Be 'HardLink'
        }
    }

    Context 'Invoke-SwitchAction (hardlink)' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
        }

        It 'creates hardlink on both endpoints' {
            $slot = Join-Path $script:CredDirPath '.credentials.work.json'
            [System.IO.File]::WriteAllBytes($slot, [byte[]](0xDE,0xAD,0xBE,0xEF))

            Invoke-SwitchAction -Name 'work' 6>$null

            (Get-Item -LiteralPath $script:CredFilePath).LinkType | Should -Be 'HardLink'
            (Get-Item -LiteralPath $slot).LinkType                | Should -Be 'HardLink'
            [System.IO.File]::ReadAllBytes($script:CredFilePath)  | Should -Be ([byte[]](0xDE,0xAD,0xBE,0xEF))
        }

        It 'migration: switch when .credentials.json is a regular file produces hardlink' {
            $slot = Join-Path $script:CredDirPath '.credentials.work.json'
            [System.IO.File]::WriteAllBytes($slot, [byte[]](0x41))

            { Get-Item -LiteralPath $script:CredFilePath }.LinkType | Should -Not -Be 'HardLink'

            Invoke-SwitchAction -Name 'work' 6>$null

            (Get-Item -LiteralPath $script:CredFilePath).LinkType | Should -Be 'HardLink'
        }

        It 'rotation creates hardlinks on both endpoints' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.a.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.b.json') -Value 'B' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                  -Value 'A' -NoNewline

            Invoke-SwitchAction -Name '' 6>$null

            Get-Content -LiteralPath $script:CredFilePath -Raw | Should -Be 'B'
            (Get-Item -LiteralPath $script:CredFilePath).LinkType | Should -Be 'HardLink'
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

    Context 'Invoke-UsageAction' {
        # Pester 5 only makes functions defined in BeforeAll visible to
        # every It in the Context; function definitions inside BeforeEach
        # live only for that one BeforeEach invocation. New-Slot is a
        # fixture builder the tests share, so it lives in BeforeAll. The
        # time-dependent $script:FutureMs / $script:PastMs cannot live
        # in BeforeAll because they would capture once and drift as the
        # suite runs; they are re-computed in BeforeEach instead.
        BeforeAll {
            function New-Slot {
                Param (
                    [string] $Name,
                    [string] $AccessToken = 'sk-ant-oat-fresh',
                    [string] $RefreshToken = 'sk-ant-ort-fresh',
                    $ExpiresAt  # defaults to $script:FutureMs
                )
                if ($null -eq $ExpiresAt) { $ExpiresAt = $script:FutureMs }
                $payload = @{
                    claudeAiOauth = @{
                        accessToken      = $AccessToken
                        refreshToken     = $RefreshToken
                        expiresAt        = $ExpiresAt
                        scopes           = @('user:inference','user:profile')
                        subscriptionType = 'team'
                        rateLimitTier    = 'default_claude_max_5x'
                    }
                } | ConvertTo-Json -Depth 10 -Compress
                $path = Join-Path $script:CredDirPath ".credentials.$Name.json"
                Set-Content -LiteralPath $path -Value $payload -NoNewline -Encoding utf8NoBOM
                return $path
            }

            # Build an ISO-8601 string N time-units from now, matching the
            # shape the live /api/oauth/usage emits. In BeforeAll (not
            # BeforeEach) so every It in this Context sees the function.
            function Format-IsoReset {
                Param ([TimeSpan] $Offset)
                return [DateTimeOffset]::UtcNow.Add($Offset).ToString(
                    'o', [Globalization.CultureInfo]::InvariantCulture)
            }
        }

        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'

            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()
            $script:PastMs   = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
        }

        It 'prints no-slots message when no slots exist' {
            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'No slots saved'
        }

        It 'happy path: real /api/oauth/usage shape (buckets at root, utilization, ISO resets_at) renders table' {
            $slotPath = New-Slot -Name 'work'
            # Establish the hardlink the way Invoke-SaveAction would. Without
            # this, .credentials.json would be missing and the synth <active>
            # row would not fire — fine — but explicitly linking here
            # documents the "happy path" configuration.
            Remove-Item -LiteralPath $script:CredFilePath -Force -ErrorAction SilentlyContinue
            New-Item -ItemType HardLink -Path $script:CredFilePath -Target $slotPath | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{
                        utilization = 31.0
                        resets_at   = (Format-IsoReset ([TimeSpan]::FromMinutes(134)))  # ~2h 14m
                    }
                    seven_day = [pscustomobject]@{
                        utilization = 17.0
                        resets_at   = (Format-IsoReset ([TimeSpan]::FromHours(42)))     # ~1d 18h -> "in 42h"
                    }
                    seven_day_sonnet = [pscustomobject]@{
                        utilization = 0.0
                        resets_at   = $null
                    }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match 'work'
            # Integer percent, right-justified into 4-char cell.
            $out | Should -Match '\b31%'
            $out | Should -Match '\b17%'
            # Variant C: hours+minutes under 24h; elapsed test time may shave
            # a minute off, so accept 13-14m.
            $out | Should -Match 'in 2h 1[34]m'
            # Variant C: integer total hours at/above 24h; elapsed test time
            # may drop 42h to 41h.
            $out | Should -Match 'in 4[12]h(?!\d)'
            # 'ok' status (buckets were present, so not "no plan data").
            $out | Should -Match '(?m)\s+ok\s*$'
            # Unofficial-endpoint footer must not leak into output.
            $out | Should -Not -Match 'unofficial endpoint'
            # Hardlinked active credentials: no synth row, no warning.
            $out | Should -Not -Match '<active>'
            $out | Should -Not -Match 'not hardlinked'
            # And no row other than 'work' (one saved slot → exactly one data row).
            ($out -split "`n" | Where-Object { $_ -match '(?:^|\s)(work|<active>)\b' }).Count | Should -Be 1
        }

        It 'true empty response ({}) renders "ok (no plan data)"' {
            New-Slot -Name 'free' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{}
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'free'
            $out | Should -Match 'ok \(no plan data\)'
        }

        It 'null resets_at paired with 0% renders the em-dash in the reset column' {
            New-Slot -Name 'cold' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 0.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 9.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(103))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # 0% five_hour with null reset: percentage renders as ' 0%',
            # reset cell as '—' (em-dash). Column alignment is preserved.
            $out | Should -Match '\b0%'
            # The 5h reset cell is em-dash. It sits right after the 0% cell
            # within the row, so we assert on that sequence.
            $out | Should -Match '0%\s+—'
        }

        It '401 response: status is unauthorized' {
            New-Slot -Name 'revoked' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 401 }
                $inner = [System.Exception]::new('Unauthorized')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'unauthorized'
        }

        It 'network timeout: status is error; overall call still returns 0-exit' {
            New-Slot -Name 'offline' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Net.WebException]::new('The operation has timed out.')
            }

            { Invoke-UsageAction 6>$null } | Should -Not -Throw
            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'error:'
            $out | Should -Match 'timed out'
        }

        It 'slot with no claudeAiOauth section: status is no-oauth; no HTTP call made' {
            $path = Join-Path $script:CredDirPath '.credentials.apikey.json'
            Set-Content -LiteralPath $path -Value '{"apiKey":"sk-ant-api..."}' -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -MockWith { throw 'should not be called' }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match 'apikey'
            $out | Should -Match 'no-oauth'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'expired token: refresh succeeds, slot file rewritten in place, usage retrieved' {
            $slotPath = New-Slot -Name 'stale' -AccessToken 'sk-ant-oat-OLD' -ExpiresAt $script:PastMs

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                if ($Headers['Authorization'] -ne 'Bearer sk-ant-oat-NEW') {
                    throw "refresh did not propagate to usage call: got '$($Headers['Authorization'])'"
                }
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(3))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $after = Get-Content -LiteralPath $slotPath -Raw | ConvertFrom-Json
            $after.claudeAiOauth.accessToken  | Should -Be 'sk-ant-oat-NEW'
            $after.claudeAiOauth.refreshToken | Should -Be 'sk-ant-ort-NEW'
            [DateTimeOffset]::FromUnixTimeMilliseconds($after.claudeAiOauth.expiresAt).UtcDateTime |
                Should -BeGreaterThan ([DateTime]::UtcNow)
            $out | Should -Match '\b5%'

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'expired token + -NoRefresh: status is expired, no refresh call, slot unchanged' {
            $slotPath = New-Slot -Name 'stale' -AccessToken 'sk-ant-oat-OLD' -ExpiresAt $script:PastMs
            $before   = [System.IO.File]::ReadAllBytes($slotPath)

            Mock Invoke-RestMethod -MockWith { throw 'should not be called' }

            $out = Invoke-UsageAction -NoRefresh 6>&1 | Out-String

            $out | Should -Match 'stale'
            $out | Should -Match 'expired'
            $after = [System.IO.File]::ReadAllBytes($slotPath)
            $after.Length | Should -Be $before.Length
            for ($i = 0; $i -lt $before.Length; $i++) { $after[$i] | Should -Be $before[$i] }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'expired token + refresh fails (400): status is expired; slot unchanged' {
            $slotPath = New-Slot -Name 'stale' -ExpiresAt $script:PastMs
            $before   = [System.IO.File]::ReadAllBytes($slotPath)

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                throw [System.Exception]::new('refresh_token invalid')
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw 'should not be called if refresh failed'
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match 'expired'
            $after = [System.IO.File]::ReadAllBytes($slotPath)
            $after.Length | Should -Be $before.Length
            for ($i = 0; $i -lt $before.Length; $i++) { $after[$i] | Should -Be $before[$i] }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It '-Json emits a per-slot dictionary that round-trips via ConvertFrom-Json' {
            New-Slot -Name 'alpha' | Out-Null
            New-Slot -Name 'bravo' -AccessToken 'sk-ant-oat-bravo' -RefreshToken 'sk-ant-ort-bravo' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*fresh*' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 10.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*bravo*' } -MockWith {
                throw [System.Exception]::new('network down')
            }

            $raw    = Invoke-UsageAction -Json
            $parsed = $raw | ConvertFrom-Json

            ($parsed | Get-Member -MemberType NoteProperty | ForEach-Object Name) | Sort-Object |
                Should -Be @('alpha','bravo')
            $parsed.alpha.status | Should -Be 'ok'
            # Real schema: utilization at data.five_hour (no rate_limits wrapper).
            $parsed.alpha.data.five_hour.utilization | Should -Be 10
            $parsed.bravo.status | Should -Be 'error'
            $parsed.bravo.error  | Should -Match 'network down'
        }

        It 'refresh preserves any hardlink to .credentials.json (active-slot refresh)' {
            $slotPath = New-Slot -Name 'activeStale' -AccessToken 'sk-ant-oat-OLD' -ExpiresAt $script:PastMs

            Remove-Item -LiteralPath $script:CredFilePath -Force -ErrorAction SilentlyContinue
            New-Item -ItemType HardLink -Path $script:CredFilePath -Target $slotPath | Out-Null
            (Get-Item -LiteralPath $script:CredFilePath).LinkType | Should -Be 'HardLink'

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{}
            }

            Invoke-UsageAction 6>$null

            (Get-Item -LiteralPath $script:CredFilePath).LinkType | Should -Be 'HardLink'
            (Get-Item -LiteralPath $slotPath).LinkType            | Should -Be 'HardLink'

            $credJson = Get-Content -LiteralPath $script:CredFilePath -Raw | ConvertFrom-Json
            $credJson.claudeAiOauth.accessToken | Should -Be 'sk-ant-oat-NEW'
        }

        It 'named-slot usage: verbose view shows only Session and Weekly buckets' {
            New-Slot -Name 'alpha' | Out-Null
            New-Slot -Name 'bravo' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    # Buckets we render:
                    five_hour        = [pscustomobject]@{ utilization = 25.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                    seven_day        = [pscustomobject]@{ utilization = 17.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(48))) }
                    # Buckets we MUST NOT render (scope decision: limits only = session + weekly):
                    seven_day_opus   = [pscustomobject]@{ utilization = 8.0;  resets_at = (Format-IsoReset ([TimeSpan]::FromDays(6))) }
                    seven_day_sonnet = [pscustomobject]@{ utilization = 0.0;  resets_at = $null }
                    extra_usage      = [pscustomobject]@{ is_enabled = $false; monthly_limit = $null; used_credits = $null; utilization = $null; currency = $null }
                }
            }

            $out = Invoke-UsageAction -Name 'alpha' 6>&1 | Out-String

            # Targeted slot only.
            $out | Should -Match "Slot 'alpha'"
            $out | Should -Not -Match "Slot 'bravo'"

            # The two rendered buckets.
            $out | Should -Match 'Session \(5h\)'
            $out | Should -Match 'Weekly \(all models\)'
            $out | Should -Match 'Resets '

            # Explicitly absent: labels for buckets we deliberately stopped
            # rendering. Protects against accidental regression if a future
            # refactor reintroduces a generic bucket loop.
            $out | Should -Not -Match 'Weekly \(Opus only\)'
            $out | Should -Not -Match 'Weekly \(Sonnet only\)'
            $out | Should -Not -Match 'Extra usage'
            # Raw API keys also absent (we use labels, not keys).
            $out | Should -Not -Match '(?m)^\s+five_hour\b'
            $out | Should -Not -Match '(?m)^\s+seven_day\b'

            # Unofficial-endpoint footer removed.
            $out | Should -Not -Match 'unofficial endpoint'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'named-slot usage throws on missing slot' {
            New-Slot -Name 'alpha' | Out-Null
            { Invoke-UsageAction -Name 'missing' 6>$null } | Should -Throw -ExpectedMessage "*Slot 'missing' not found*"
        }

        # --- synth <active> row + hardlink warning ---

        # Claude Code replaces .credentials.json via atomic rename during an
        # OAuth refresh; that breaks the hardlink chain the switcher sets up.
        # The `usage` action detects this state and renders a synthetic
        # <active> row for whatever .credentials.json currently points at,
        # so users can see the account Claude Code is actually using even
        # when no saved slot matches it. Paired with a list-style warning.
        It 'synth <active> (unsaved) row appears when .credentials.json matches no saved slot' {
            # Two saved slots with one set of tokens + a completely
            # different .credentials.json with a third token. Content hash
            # of the active file matches neither slot.
            New-Slot -Name 'work' -AccessToken 'sk-ant-oat-work' | Out-Null
            New-Slot -Name 'home' -AccessToken 'sk-ant-oat-home' | Out-Null
            $activePayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-ACTIVE-UNKNOWN'
                    refreshToken     = 'sk-ant-ort-ACTIVE-UNKNOWN'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                    rateLimitTier    = 'default_claude_max_5x'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $activePayload -NoNewline -Encoding utf8NoBOM

            # Return three different responses keyed by the Authorization
            # header so we can detect whether the synth row used the
            # active-file token (it must) rather than a saved slot's token.
            Mock Invoke-RestMethod -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*ACTIVE-UNKNOWN*'
            } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 53.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 19.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(40))) }
                }
            }
            Mock Invoke-RestMethod -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -notlike '*ACTIVE-UNKNOWN*'
            } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(3))) }
                    seven_day = [pscustomobject]@{ utilization = 7.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(120))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Saved slots still render (both rows), without the `*` marker
            # (content hash does not match .credentials.json, so their
            # natural IsActive is already false; nothing suppressed).
            $out | Should -Match '(?m)^\s+work\s'
            $out | Should -Match '(?m)^\s+home\s'

            # Synth row is present, marked active, with the (unsaved) suffix
            # because .credentials.json content doesn't hash-match any slot.
            $out | Should -Match '(?m)^\s+\*\s+<active> \(unsaved\)\s'
            # Its usage numbers come from the active-file token (53/19),
            # not the saved-slot tokens (5/7).
            $out | Should -Match '<active> \(unsaved\).*\b53%'
            $out | Should -Match '<active> \(unsaved\).*\b19%'

            # Hardlink-broken warning on the unsaved path.
            $out | Should -Match 'Warning: .credentials.json is not hardlinked'
            $out | Should -Match "sca save <name>"

            # Three endpoint calls: one per saved slot, one for .credentials.json.
            Should -Invoke Invoke-RestMethod -Times 3 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'synth <active> row (no suffix) appears when .credentials.json is a copy of a saved slot' {
            # Same tokens in the active file as in 'work'; both hash-match
            # but the active file is a regular file, not a hardlink.
            $slotPath = New-Slot -Name 'work' -AccessToken 'sk-ant-oat-WORK-TOKEN'
            $workJson = Get-Content -LiteralPath $slotPath -Raw
            Set-Content -LiteralPath $script:CredFilePath -Value $workJson -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 10.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                    seven_day = [pscustomobject]@{ utilization = 12.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(72))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Synth row uses the no-suffix label because content matches
            # an existing saved slot.
            $out | Should -Match '(?m)^\s+\*\s+<active>\s'
            # The saved-slot row for 'work' is still present but does NOT
            # carry the `*` marker — `*` is on the synth row only.
            $out | Should -Match '(?m)^\s+work\s'
            $out | Should -Not -Match '(?m)^\s+\*\s+work\s'

            # Warning points at the matched slot and suggests sca switch.
            $out | Should -Match "Warning: .credentials.json is not hardlinked to 'work'"
            $out | Should -Match "sca switch work"
        }

        It 'no synth row and no warning when .credentials.json is a hardlink to a saved slot' {
            $slotPath = New-Slot -Name 'work'
            Remove-Item -LiteralPath $script:CredFilePath -Force -ErrorAction SilentlyContinue
            New-Item -ItemType HardLink -Path $script:CredFilePath -Target $slotPath | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 0.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 0.0; resets_at = $null }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Not -Match '<active>'
            $out | Should -Not -Match 'Warning: .credentials.json'
            # Exactly one endpoint call: for the saved slot (the synth-row
            # extra call must NOT happen on the hardlinked path).
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'synth row renders even when there are no saved slots at all' {
            # Fresh install edge case: .credentials.json exists (user ran
            # `claude /login` once) but nothing has been `sca save`'d yet.
            $activePayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-loner'
                    refreshToken     = 'sk-ant-ort-loner'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'pro'
                    rateLimitTier    = $null
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $activePayload -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 2.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(4))) }
                    seven_day = [pscustomobject]@{ utilization = 1.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(150))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Must NOT print the zero-slots early-return message.
            $out | Should -Not -Match 'No slots saved yet'
            # Synth row present with (unsaved) suffix.
            $out | Should -Match '<active> \(unsaved\)'
            $out | Should -Match '\b2%'
            $out | Should -Match 'Warning: .credentials.json is not hardlinked'
        }

        It '`sca usage <active>` drills into the synth row verbose view' {
            # Set up the unsaved-active state.
            $activePayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-ACTIVE'
                    refreshToken     = 'sk-ant-ort-ACTIVE'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                    rateLimitTier    = 'default_claude_max_5x'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $activePayload -NoNewline -Encoding utf8NoBOM
            New-Slot -Name 'other' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*ACTIVE*'
            } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 53.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 19.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(40))) }
                }
            }
            Mock Invoke-RestMethod -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -notlike '*ACTIVE*'
            } -MockWith {
                throw 'saved-slot token should not be queried when drilling into synth row'
            }

            $out = Invoke-UsageAction -Name '<active> (unsaved)' 6>&1 | Out-String

            # Verbose view header carries the synth name.
            $out | Should -Match "Slot '<active> \(unsaved\)'"
            # Two-bucket render only.
            $out | Should -Match 'Session \(5h\)\s+53%\s+Resets '
            $out | Should -Match 'Weekly \(all models\)\s+19%\s+Resets '
            # Drill-down must not emit the warning (only the summary table does).
            $out | Should -Not -Match 'Warning: .credentials.json'

            # Only the active-file token was queried.
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*ACTIVE*'
            }
        }

        It '`sca usage <active>` also accepts the bare <active> alias' {
            $activePayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-ACTIVE2'
                    refreshToken     = 'sk-ant-ort-ACTIVE2'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $activePayload -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 40.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 60.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(72))) }
                }
            }

            $out = Invoke-UsageAction -Name '<active>' 6>&1 | Out-String

            $out | Should -Match "Slot '<active> \(unsaved\)'"
            $out | Should -Match '\b40%'
            $out | Should -Match '\b60%'
        }

        It '`sca usage <active>` throws when there is nothing to synthesize' {
            # No .credentials.json -> nothing to synthesize. Must refuse.
            New-Slot -Name 'alpha' | Out-Null
            { Invoke-UsageAction -Name '<active>' 6>$null } |
                Should -Throw -ExpectedMessage '*No synthetic active slot*'
        }

        It '-Json includes the synth row under its label key' {
            $activePayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-ACTIVE3'
                    refreshToken     = 'sk-ant-ort-ACTIVE3'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $activePayload -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 1.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(3))) }
                    seven_day = [pscustomobject]@{ utilization = 2.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(50))) }
                }
            }

            $raw    = Invoke-UsageAction -Json
            $parsed = $raw | ConvertFrom-Json

            # ConvertFrom-Json exposes ordered-dictionary keys as
            # NoteProperty names on the root object. The synth row's key is
            # the literal label string.
            $parsed.PSObject.Properties.Name | Should -Contain '<active> (unsaved)'
            $active = $parsed.'<active> (unsaved)'
            $active.status                        | Should -Be 'ok'
            $active.is_active                     | Should -Be $true
            $active.data.five_hour.utilization    | Should -Be 1
            $active.data.seven_day.utilization    | Should -Be 2
        }
    }

    Context 'Format-ResetDelta' {
        It 'returns em-dash for null / empty / 0' {
            Format-ResetDelta $null  | Should -Be '—'
            Format-ResetDelta ''     | Should -Be '—'
            # Legacy-API integer 0 should also not explode (PowerShell coerces
            # 0 -eq '' to $true, so the early return fires).
            Format-ResetDelta 0      | Should -Be '—'
        }

        It 'returns em-dash for malformed input rather than throwing' {
            Format-ResetDelta 'not a date at all' | Should -Be '—'
        }

        It 'returns "now" for past ISO timestamps' {
            $past = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $past | Should -Be 'now'
        }

        It 'returns "in <m>m" for sub-hour ISO deltas' {
            $future = [DateTimeOffset]::UtcNow.AddMinutes(30).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $future | Should -Match '^in (29|30)m$'
        }

        It 'returns "in <h>h <m>m" for 1-23 hour ISO deltas (minute precision kept)' {
            $future = [DateTimeOffset]::UtcNow.AddHours(2).AddMinutes(14).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $future | Should -Match '^in 2h 1[34]m$'
        }

        It 'returns "in <h>h" (integer total hours) for >=24h ISO deltas' {
            $future = [DateTimeOffset]::UtcNow.AddHours(42).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $future | Should -Match '^in 4[12]h$'
        }

        It 'returns "in <h>h" for multi-day ISO deltas (no days unit)' {
            $future = [DateTimeOffset]::UtcNow.AddDays(4).AddHours(7).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            # 4d 7h = 103h; test elapsed time may trim a minute so 102 or 103.
            Format-ResetDelta $future | Should -Match '^in 10[23]h$'
            # And definitely not the old "Xd Yh" format.
            Format-ResetDelta $future | Should -Not -Match 'd '
        }

        It 'accepts a pre-parsed DateTimeOffset value too (defensive)' {
            $future = [DateTimeOffset]::UtcNow.AddMinutes(45)
            Format-ResetDelta $future | Should -Match '^in 4[45]m$'
        }
    }

    Context 'Format-ResetAbsolute' {
        # NOTE: Windows local tz names contain spaces (e.g. "W. Europe Standard
        # Time"), so every regex tail allows .+ rather than \S+. Test names
        # also avoid `<`, `>`, and `|` because those characters seem to trip
        # Pester 5's error-report pipeline into treating fragments as commands
        # (observed: "The term 'pm' is not recognized").
        It 'returns em-dash for null / empty / malformed input' {
            Format-ResetAbsolute $null   | Should -Be '—'
            Format-ResetAbsolute ''      | Should -Be '—'
            Format-ResetAbsolute 'nope'  | Should -Be '—'
        }

        It 'same-day ISO renders hour:minute am or pm and the local tz name' {
            # Pick a timestamp 3 hours ahead. Near local midnight this may
            # cross to the next day; the assertions branch on which side we
            # land to keep the test deterministic regardless of wall time.
            $future  = [DateTimeOffset]::Now.AddHours(3)
            $sameDay = $future.LocalDateTime.Date -eq [DateTime]::Now.Date
            $iso     = $future.ToString('o', [Globalization.CultureInfo]::InvariantCulture)

            $out = Format-ResetAbsolute $iso
            if ($sameDay) {
                # Resets 7:50pm W. Europe Standard Time
                $out | Should -Match '^Resets \d{1,2}:\d{2}(am|pm) .+$'
                $out | Should -Not -Match ','
            } else {
                # Different-day form when 3h from now crosses midnight.
                $out | Should -Match '^Resets \w{3} \d{1,2}, '
            }
        }

        It 'multi-day ISO renders Mon d, then time and local tz name' {
            $future = [DateTimeOffset]::Now.AddHours(48)
            $iso    = $future.ToString('o', [Globalization.CultureInfo]::InvariantCulture)

            # Resets Apr 26, 7:05pm W. Europe Standard Time
            Format-ResetAbsolute $iso | Should -Match '^Resets \w{3} \d{1,2}, \d{1,2}(:\d{2})?(am|pm) .+$'
        }

        It 'drops the :00 suffix on on-the-hour different-day times' {
            # 9:00am tomorrow local exercises the minute-zero short form.
            $tomorrow9am = [DateTime]::Today.AddDays(1).AddHours(9)
            $dto  = [DateTimeOffset]$tomorrow9am
            $iso  = $dto.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $out  = Format-ResetAbsolute $iso

            # Resets Apr 25, 9am W. Europe Standard Time
            $out | Should -Match '^Resets \w{3} \d{1,2}, 9am .+$'
        }
    }

    Context 'Get-SlotProfile' {
        # Reuses the New-Slot BeforeAll helper from the Invoke-UsageAction
        # context so slot files have the exact claudeAiOauth shape the
        # helper expects. Profile caching was removed along with the
        # sidecar scheme; Get-SlotProfile is now a pure HTTP helper used
        # by Invoke-SaveAction to embed the email in the slot filename.
        BeforeAll {
            function New-ProfileSlot {
                Param (
                    [string] $Name,
                    [string] $AccessToken = 'sk-ant-oat-profile',
                    $ExpiresAt
                )
                if ($null -eq $ExpiresAt) { $ExpiresAt = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds() }
                $payload = @{
                    claudeAiOauth = @{
                        accessToken      = $AccessToken
                        refreshToken     = 'sk-ant-ort-profile'
                        expiresAt        = $ExpiresAt
                        scopes           = @('user:inference','user:profile')
                        subscriptionType = 'team'
                        rateLimitTier    = 'default_claude_max_5x'
                    }
                } | ConvertTo-Json -Depth 10 -Compress
                $path = Join-Path $script:SandboxHome '.claude' | Join-Path -ChildPath ".credentials.$Name.json"
                $dir  = Split-Path -Parent $path
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Set-Content -LiteralPath $path -Value $payload -NoNewline -Encoding utf8NoBOM
                return $path
            }
        }

        It 'happy path: 200 response returns the email' {
            $slot = New-ProfileSlot -Name 'happy'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'alice@example.com'; uuid = 'acct-uuid' }
                    organization = [pscustomobject]@{ name  = 'example'; organization_type = 'claude_team' }
                }
            }

            $res = Get-SlotProfile -SlotPath $slot
            $res.Status | Should -Be 'ok'
            $res.Email  | Should -Be 'alice@example.com'

            # No caching: a second call fires another HTTP request. This
            # is by design — email is now encoded in the slot filename at
            # save time, so Get-SlotProfile is only called at save time.
            Get-SlotProfile -SlotPath $slot | Out-Null
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' }
        }

        It '401 response returns unauthorized' {
            $slot = New-ProfileSlot -Name 'revoked'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 401 }
                $inner = [System.Exception]::new('Unauthorized')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            (Get-SlotProfile -SlotPath $slot).Status | Should -Be 'unauthorized'
        }

        It 'network timeout returns error' {
            $slot = New-ProfileSlot -Name 'offline'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                throw [System.Net.WebException]::new('The operation has timed out.')
            }

            $res = Get-SlotProfile -SlotPath $slot
            $res.Status | Should -Be 'error'
            $res.Error  | Should -Match 'timed out'
        }

        It 'slot without claudeAiOauth returns no-oauth and makes zero HTTP calls' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            if (-not (Test-Path -LiteralPath $credDir)) { New-Item -ItemType Directory -Path $credDir -Force | Out-Null }
            $slot = Join-Path $credDir '.credentials.apikey.json'
            Set-Content -LiteralPath $slot -Value '{"apiKey":"sk-ant-api..."}' -NoNewline -Encoding utf8NoBOM

            (Get-SlotProfile -SlotPath $slot).Status | Should -Be 'no-oauth'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' }
        }

        It 'expired token: refresh succeeds then profile call uses the new token' {
            $slot = New-ProfileSlot -Name 'stale' `
                                    -AccessToken 'sk-ant-oat-OLD' `
                                    -ExpiresAt   ([DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds())

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                if ($Headers['Authorization'] -ne 'Bearer sk-ant-oat-NEW') {
                    throw "refresh did not propagate to profile call: got '$($Headers['Authorization'])'"
                }
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'bob@example.com'; uuid = 'acct-uuid' }
                    organization = [pscustomobject]@{ name  = 'example'; organization_type = 'claude_team' }
                }
            }

            $res = Get-SlotProfile -SlotPath $slot
            $res.Status | Should -Be 'ok'
            $res.Email  | Should -Be 'bob@example.com'

            $after = Get-Content -LiteralPath $slot -Raw | ConvertFrom-Json
            $after.claudeAiOauth.accessToken | Should -Be 'sk-ant-oat-NEW'
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

    Context 'Invoke-UsageAction email rendering' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 1.0; resets_at = ([DateTimeOffset]::UtcNow.AddHours(2).ToString('o', [Globalization.CultureInfo]::InvariantCulture)) }
                    seven_day = [pscustomobject]@{ utilization = 2.0; resets_at = ([DateTimeOffset]::UtcNow.AddHours(50).ToString('o', [Globalization.CultureInfo]::InvariantCulture)) }
                }
            }
        }

        # Email now lives in the slot filename; Get-Slots parses it via
        # Get-SlotFileInfo and propagates .Email into the row objects.
        # These tests stage the filenames directly rather than running
        # Invoke-SaveAction, so they isolate the display path.
        It 'renders a second-line email when the slot name differs from the labeled email' {
            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-alias'
                    refreshToken     = 'sk-ant-ort-alias'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                    rateLimitTier    = 'default_claude_max_5x'
                }
            } | ConvertTo-Json -Compress
            # Labeled filename directly — no save-time fetch involved.
            $labeled = '.credentials.work(finn.kumkar@stadtwerk.org).json'
            Set-Content -LiteralPath (Join-Path $script:CredDirPath $labeled) -Value $payload -NoNewline -Encoding utf8NoBOM

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+work\s'
            $out | Should -Match '(?m)^\s+└─ finn\.kumkar@stadtwerk\.org\s*$'
            # Zero profile HTTP calls on the display path — email is from
            # the filename, not the endpoint.
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' }
        }

        It 'suppresses the second line when the slot name equals the embedded email' {
            # Slot name equals email -> save would have chosen the
            # unlabeled form. Stage that directly.
            $email = 'alice@example.com'
            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-alice'
                    refreshToken     = 'sk-ant-ort-alice'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath (Join-Path $script:CredDirPath ".credentials.$email.json") -Value $payload -NoNewline -Encoding utf8NoBOM

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match "(?m)^\s+$([regex]::Escape($email))\s"
            $out | Should -Not -Match '└─'
        }

        It 'unlabeled slot (save-time profile fetch failed) renders without second line' {
            # .credentials.pending.json (no parens suffix) -> email unknown.
            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-pending'
                    refreshToken     = 'sk-ant-ort-pending'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.pending.json') -Value $payload -NoNewline -Encoding utf8NoBOM

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+pending\s'
            $out | Should -Not -Match '└─'
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
