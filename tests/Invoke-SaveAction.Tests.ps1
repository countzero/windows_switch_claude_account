#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for Invoke-SaveAction in switch_claude_account.ps1, including
# its hardlink behavior. Per-test sandbox setup lives in tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')
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

        # Fail-open regression: email returned by the profile endpoint may
        # contain an NTFS-invalid char (< > | : * ? " \ /). Before the
        # try/catch, Rename-Item threw and the user saw a bare traceback;
        # now the slot persists unlabeled and a yellow advisory explains
        # the fallback. The same code path also covers a locked
        # pre-existing labeled target, which is harder to simulate directly.
        It 'falls back to unlabeled filename and emits advisory when rename to labeled form fails' {
            $credDir  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $credDir -Force | Out-Null
            $credFile = Join-Path $credDir '.credentials.json'
            Set-Content -LiteralPath $credFile -Value '{"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"sk-ant-ort-x","expiresAt":9999999999999}}' -NoNewline

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'foo<bar@example.com' }  # '<' is invalid on NTFS
                    organization = [pscustomobject]@{ name  = 'example'; organization_type = 'claude_team' }
                }
            }

            # Capture info-stream output for advisory assertions. If
            # Invoke-SaveAction throws (the pre-fix regression), Pester
            # surfaces the actual exception and fails the test — which is
            # a stronger signal than a generic "did not throw" assertion
            # would give, and avoids the Pester scriptblock-scoping
            # gotcha where `{ $out = ... } | Should -Not -Throw` does
            # not propagate `$out` to the outer It scope.
            $out = Invoke-SaveAction -Name 'work' 6>&1 | Out-String

            # Unlabeled slot persisted; no labeled file on disk.
            Test-Path -LiteralPath (Join-Path $credDir '.credentials.work.json') | Should -BeTrue
            @(Get-ChildItem -LiteralPath $credDir -Filter '.credentials.work(*).json').Count | Should -Be 0

            # Hardlink from .credentials.json survives the failed rename (core invariant).
            (Get-Item -LiteralPath $credFile).LinkType | Should -Be 'HardLink'

            # Advisory printed; success message does NOT claim the email label.
            $out | Should -Match 'Could not rename slot to labeled form'
            $out | Should -Match "Saved as 'work'"
            $out | Should -Not -Match 'foo<bar@example\.com'
            # Key assertion: proves $labelApplied gated $displayEmail so the
            # success line reflects on-disk reality.
            $out | Should -Not -Match "Saved as 'work' \("
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

    AfterAll {
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
