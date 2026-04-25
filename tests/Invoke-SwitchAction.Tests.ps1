#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-SwitchAction in switch_claude_account.ps1,
# including its hardlink behavior. Per-test sandbox setup lives in
# tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')
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

        # The new switch output renders the filename-encoded email
        # alongside the slot name so the user sees which account they
        # just activated. The format is `'<slot>' (<email>)` for labeled
        # slots, plain `'<slot>'` for unlabeled / dedup slots.
        It "renders email in success message when target slot is labeled" {
            $labeled = Join-Path $script:CredDirPath '.credentials.work(alice@example.com).json'
            Set-Content -LiteralPath $labeled -Value 'X' -NoNewline

            $out = Invoke-SwitchAction -Name 'work' 6>&1 | Out-String

            $out | Should -Match "Switched to 'work' \(alice@example\.com\)"
        }

        It "omits email parens when target slot is unlabeled" {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.work.json') -Value 'X' -NoNewline

            $out = Invoke-SwitchAction -Name 'work' 6>&1 | Out-String

            # `(?m)...$` anchors the slot identity to end-of-line so an
            # accidental `(email)` suffix or a stale trailing period would
            # both fail this assertion. The success line is now a yellow
            # header without a trailing dot.
            $out | Should -Match "(?m)Switched to 'work'\s*$"
            $out | Should -Not -Match '\([^)]*@[^)]*\)'
        }

        It "omits email parens when slot name equals the embedded email (dedup form)" {
            $email = 'alice@example.com'
            Set-Content -LiteralPath (Join-Path $script:CredDirPath ".credentials.$email.json") -Value 'X' -NoNewline

            $out = Invoke-SwitchAction -Name $email 6>&1 | Out-String

            $out | Should -Match "(?m)Switched to '$([regex]::Escape($email))'\s*$"
            # No `(alice@example.com)` suffix duplicating the slot name.
            $out | Should -Not -Match "'$([regex]::Escape($email))' \($([regex]::Escape($email))\)"
        }

        # Rotation prints only the success line (for the destination)
        # plus the saved-slot table beneath. The previous two-line
        # `[Switch] Rotating from ... to ...` banner is gone — the table
        # beneath conveys the new active slot via its `*` marker.
        It 'rotation prints success line for destination + table beneath' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.slot-1(alice@example.com).json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.slot-2(bob@example.com).json')   -Value 'B' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                                          -Value 'B' -NoNewline

            $out = Invoke-SwitchAction -Name '' 6>&1 | Out-String

            $out | Should -Match "Switched to 'slot-1' \(alice@example\.com\)"
            # Table beneath: column headers and both rows present.
            $out | Should -Match '(?m)^\s+Slot\s+Account\s*$'
            $out | Should -Match '(?m)^\s+\*\s+slot-1\s+alice@example\.com\b'
            $out | Should -Match '(?m)^\s+slot-2\s+bob@example\.com\b'
            # No trace of the retired rotation banner.
            $out | Should -Not -Match 'Rotating from'
        }

        It 'rotation does not print the rotation banner' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.bravo.json') -Value 'B' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                      -Value 'A' -NoNewline

            $out = Invoke-SwitchAction -Name '' 6>&1 | Out-String

            $out | Should -Not -Match 'Rotating'
            $out | Should -Match "Switched to 'bravo'"
        }

        It 'named switch prints the saved-slot table beneath the success line' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.bravo.json') -Value 'B' -NoNewline

            $out = Invoke-SwitchAction -Name 'alpha' 6>&1 | Out-String

            $out | Should -Match "Switched to 'alpha'"
            # Column header row present.
            $out | Should -Match '(?m)^\s+Slot\s+Account\s*$'
            # No `[List] Saved slots` header — Format-ListTable was called
            # with -SuppressHeader so the table sits cleanly under the
            # `[Switch]` line.
            $out | Should -Not -Match '\[List\] Saved slots'
        }

        It 'switch table marks the just-activated slot with *' {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.bravo.json') -Value 'B' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                      -Value 'B' -NoNewline

            $out = Invoke-SwitchAction -Name 'alpha' 6>&1 | Out-String

            # alpha is now active (just hardlinked), bravo is not.
            $out | Should -Match '(?m)^\s+\*\s+alpha\s'
            $out | Should -Match '(?m)^\s+bravo\s'
            # Defensive: bravo must NOT carry a `*` after the switch.
            $out | Should -Not -Match '(?m)^\s+\*\s+bravo\s'
        }

        # The success line is a yellow header, not a sentence — the
        # apply hint moved to a separate `[Info]` line beneath the table.
        # Verify (a) no "Close and restart" text on the success line,
        # (b) no trailing period after the slot identity.
        It 'success line drops the "Close and restart" wording and the trailing period' {
            $labeled = Join-Path $script:CredDirPath '.credentials.work(alice@example.com).json'
            Set-Content -LiteralPath $labeled -Value 'X' -NoNewline

            $out = Invoke-SwitchAction -Name 'work' 6>&1 | Out-String

            # The "Close and restart" string MUST NOT appear on the same
            # line as "Switched to ...". Negated CR/LF char class anchors
            # the assertion to a single line.
            $out | Should -Not -Match "Switched to[^`r`n]*Close and restart"
            # Negative lookahead: the closing paren of the email must
            # NOT be followed by a literal `.` on the success line.
            $out | Should -Match "Switched to 'work' \(alice@example\.com\)(?!\.)"
        }

        It "[Info] hint appears beneath the table" {
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.alpha.json') -Value 'A' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.bravo.json') -Value 'B' -NoNewline

            $out = Invoke-SwitchAction -Name 'alpha' 6>&1 | Out-String

            $out | Should -Match '\[Info\] Close and restart Claude Code to apply\.'

            # Ordering check: [Switch] header < table row < [Info] hint.
            $switchIdx = $out.IndexOf('[Switch] Switched')
            $rowIdx    = ($out | Select-String -Pattern '(?m)^\s+\*\s+alpha\s').Matches[0].Index
            $infoIdx   = $out.IndexOf('[Info] Close')
            $switchIdx | Should -BeLessThan $rowIdx
            $rowIdx    | Should -BeLessThan $infoIdx
        }

        It "single-slot no-op suppresses the [Info] hint" {
            # Exactly one slot, and it's already active -> Get-NextSlotName
            # prints its yellow advisory and returns $null; the caller
            # exits BEFORE the table render and the [Info] line.
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.only.json') -Value 'X' -NoNewline
            Set-Content -LiteralPath $script:CredFilePath                                     -Value 'X' -NoNewline

            $out = Invoke-SwitchAction -Name '' 6>&1 | Out-String

            $out | Should -Match 'Only one slot'
            $out | Should -Match 'already active'
            # No apply hint: nothing changed, nothing to apply.
            $out | Should -Not -Match '\[Info\] Close and restart'
            # No success line either.
            $out | Should -Not -Match 'Switched to'
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

    AfterAll {
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
