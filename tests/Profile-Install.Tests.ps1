#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Add-To-Profile / Remove-From-Profile in
# switch_claude_account.ps1. Per-test sandbox setup lives in tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE

    # Local helper for install/uninstall round-trip tests. Throws with a
    # precise offset on first mismatch so Pester shows exactly where the
    # byte sequences diverge instead of a generic "not equal" failure.
    # Used only by this file, so kept local rather than in Common.ps1.
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
        . (Join-Path $PSScriptRoot 'Common.ps1')
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

    AfterAll {
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
