#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for the state-file primitives in switch_claude_account.ps1:
# Set-CredentialFileAtomic, Read-ScaState, Write-ScaState, Update-ScaState.
#
# These four functions are the foundation the rest of the redesign sits on
# (atomic writes that survive an open Claude Code; state-file tracking that
# replaces the hardlink-based active-slot identification). They are tested
# in isolation here so a regression in the foundation surfaces with a small,
# targeted failure rather than indirectly via Invoke-* action tests.
#
# Per-test sandbox setup lives in tests/Common.ps1; see that file for the
# scoping rationale.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')

        # Every test in this file works inside the sandboxed .claude
        # directory, so create it once per test rather than repeating the
        # Join-Path / New-Item dance in every It block.
        $script:SandboxCredDir = Join-Path $script:SandboxHome '.claude'
        New-Item -ItemType Directory -Path $script:SandboxCredDir -Force | Out-Null
    }

    Context 'Set-CredentialFileAtomic' {
        It 'writes bytes to a non-existent destination' {
            $dest = Join-Path $script:SandboxCredDir 'new.txt'
            Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](65,66,67))

            Test-Path -LiteralPath $dest | Should -BeTrue
            [System.IO.File]::ReadAllBytes($dest) | Should -Be ([byte[]](65,66,67))
        }

        It 'replaces an existing destination atomically' {
            $dest = Join-Path $script:SandboxCredDir 'existing.txt'
            Set-Content -LiteralPath $dest -Value 'OLD' -NoNewline

            Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](78,69,87))

            Get-Content -LiteralPath $dest -Raw | Should -Be 'NEW'
        }

        It 'cleans up the temp file after a successful write' {
            $dest = Join-Path $script:SandboxCredDir 'cleaned.txt'
            Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](1,2,3))

            $leftovers = Get-ChildItem -LiteralPath $script:SandboxCredDir -Filter 'cleaned.txt.sca-tmp.*'
            $leftovers.Count | Should -Be 0
        }

        # The whole reason the script switched to atomic-rename writes:
        # Claude Code keeps .credentials.json open with FILE_SHARE_DELETE
        # while running, and only [System.IO.File]::Replace / ::Move
        # succeed against an open-but-share-delete handle. A regression
        # here would silently re-introduce the "close Claude Code first"
        # constraint we promised to remove.
        It 'succeeds while destination is open with FileShare::ReadWrite|Delete' {
            $dest = Join-Path $script:SandboxCredDir 'open.txt'
            Set-Content -LiteralPath $dest -Value 'OLD' -NoNewline

            $stream = [System.IO.File]::Open($dest, 'Open', 'Read', 'ReadWrite, Delete')
            try {
                { Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](78,69,87)) } |
                    Should -Not -Throw
            }
            finally {
                $stream.Dispose()
            }

            Get-Content -LiteralPath $dest -Raw | Should -Be 'NEW'
        }

        # Regression guard for the inverse: if a reader holds the file
        # without granting FileShare::Delete, the atomic write must fail
        # cleanly rather than silently corrupting state. This shouldn't
        # happen in practice (Claude Code grants share-delete) but it
        # documents the contract we depend on.
        It 'fails when destination is open without FileShare::Delete' {
            $dest = Join-Path $script:SandboxCredDir 'locked.txt'
            Set-Content -LiteralPath $dest -Value 'OLD' -NoNewline

            $stream = [System.IO.File]::Open($dest, 'Open', 'Read', 'Read')
            try {
                { Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]](78,69,87)) } |
                    Should -Throw
            }
            finally {
                $stream.Dispose()
            }

            # Original content is preserved; no partial write reached disk.
            Get-Content -LiteralPath $dest -Raw | Should -Be 'OLD'
        }

        It 'writes empty bytes' {
            $dest = Join-Path $script:SandboxCredDir 'empty.txt'
            Set-CredentialFileAtomic -Path $dest -Bytes ([byte[]]@())

            Test-Path -LiteralPath $dest | Should -BeTrue
            (Get-Item -LiteralPath $dest).Length | Should -Be 0
        }
    }

    Context 'Write-ScaState' {
        It 'writes a schema-1 JSON file at $StateFile' {
            $state = [pscustomobject]@{
                schema         = 1
                active_slot    = 'work'
                last_sync_hash = 'abc123'
            }
            Write-ScaState -State $state

            Test-Path -LiteralPath $StateFile | Should -BeTrue
            $obj = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            $obj.schema         | Should -Be 1
            $obj.active_slot    | Should -Be 'work'
            $obj.last_sync_hash | Should -Be 'abc123'
        }

        It 'enforces schema=1 even when caller passes a different value' {
            $state = [pscustomobject]@{
                schema         = 99
                active_slot    = 'work'
                last_sync_hash = 'abc123'
            }
            Write-ScaState -State $state

            $obj = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            $obj.schema | Should -Be 1
        }

        It 'overwrites an existing state file atomically' {
            Write-ScaState -State ([pscustomobject]@{ schema=1; active_slot='one'; last_sync_hash='h1' })
            Write-ScaState -State ([pscustomobject]@{ schema=1; active_slot='two'; last_sync_hash='h2' })

            $obj = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            $obj.active_slot    | Should -Be 'two'
            $obj.last_sync_hash | Should -Be 'h2'
        }

        It 'persists null active_slot / last_sync_hash' {
            $state = [pscustomobject]@{ schema=1; active_slot=$null; last_sync_hash=$null }
            Write-ScaState -State $state

            $obj = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
            $obj.active_slot    | Should -BeNullOrEmpty
            $obj.last_sync_hash | Should -BeNullOrEmpty
        }
    }

    Context 'Read-ScaState' {
        It 'returns null when no state file and no .credentials.json' {
            Read-ScaState | Should -BeNullOrEmpty
        }

        It 'returns a parsed state object when the file is schema 1' {
            $state = [pscustomobject]@{ schema=1; active_slot='work'; last_sync_hash='deadbeef' }
            Write-ScaState -State $state

            $r = Read-ScaState
            $r.schema         | Should -Be 1
            $r.active_slot    | Should -Be 'work'
            $r.last_sync_hash | Should -Be 'deadbeef'
        }

        It 'returns null on schema mismatch' {
            $bad = '{"schema":2,"active_slot":"work","last_sync_hash":"abc"}'
            Set-Content -LiteralPath $StateFile -Value $bad -NoNewline -Encoding utf8NoBOM

            Read-ScaState | Should -BeNullOrEmpty
        }

        It 'returns null on corrupt JSON' {
            Set-Content -LiteralPath $StateFile -Value 'not-json{' -NoNewline -Encoding utf8NoBOM

            Read-ScaState | Should -BeNullOrEmpty
        }

        # Auto-migration: this is what makes the redesign upgrade-safe for
        # users coming from the hardlink-based version. With no state file
        # but a .credentials.json that hashes to a known slot, we should
        # bootstrap the state on first read and persist it so subsequent
        # reads are O(1).
        It 'auto-migrates when state file missing and .credentials.json hash matches a slot' {
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.json')      -Value 'PAYLOAD' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.work.json') -Value 'PAYLOAD' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.other.json') -Value 'OTHER'   -NoNewline

            $r = Read-ScaState
            $r.active_slot | Should -Be 'work'

            # Persisted: state file exists after the migration call.
            Test-Path -LiteralPath $StateFile | Should -BeTrue
        }

        It 'parses labeled slot filenames during auto-migration' {
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.json')                              -Value 'PAYLOAD' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.work(alice@example.com).json')      -Value 'PAYLOAD' -NoNewline

            (Read-ScaState).active_slot | Should -Be 'work'
        }

        It 'returns null when state file missing and no slot hash matches' {
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.json')      -Value 'NOMATCH' -NoNewline
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.work.json') -Value 'OTHER'   -NoNewline

            Read-ScaState | Should -BeNullOrEmpty
            # Crucially: the migration must NOT write a state file when there
            # is no match (otherwise we'd persist an active_slot=$null state
            # and lose the chance for a later auto-save to do the right
            # thing on first sca usage / sca switch invocation).
            Test-Path -LiteralPath $StateFile | Should -BeFalse
        }

        It 'returns null when state file missing and no slot files exist' {
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.json') -Value 'PAYLOAD' -NoNewline

            Read-ScaState | Should -BeNullOrEmpty
            Test-Path -LiteralPath $StateFile | Should -BeFalse
        }
    }

    Context 'Update-ScaState' {
        It 'creates a fresh state file when none exists' {
            $r = Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1'

            $r.active_slot    | Should -Be 'work'
            $r.last_sync_hash | Should -Be 'h1'
            Test-Path -LiteralPath $StateFile | Should -BeTrue
        }

        It 'preserves unchanged fields' {
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1' | Out-Null

            $r = Update-ScaState -LastSyncHash 'h2'
            $r.active_slot    | Should -Be 'work'
            $r.last_sync_hash | Should -Be 'h2'
        }

        It 'updates active_slot only' {
            Update-ScaState -ActiveSlot 'one' -LastSyncHash 'h1' | Out-Null

            $r = Update-ScaState -ActiveSlot 'two'
            $r.active_slot    | Should -Be 'two'
            $r.last_sync_hash | Should -Be 'h1'
        }

        It 'clears active_slot via -ClearActiveSlot' {
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1' | Out-Null

            $r = Update-ScaState -ClearActiveSlot
            $r.active_slot    | Should -BeNullOrEmpty
            $r.last_sync_hash | Should -Be 'h1'
        }

        # Defensive contract: -ClearActiveSlot wins over -ActiveSlot when
        # both are bound. Callers expressing "forget the active slot"
        # should not have it accidentally re-set by a stale -ActiveSlot
        # default in the same invocation.
        It '-ClearActiveSlot wins over -ActiveSlot when both are bound' {
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1' | Out-Null

            $r = Update-ScaState -ActiveSlot 'other' -ClearActiveSlot
            $r.active_slot | Should -BeNullOrEmpty
        }

        It 'persists writes (round-trips through Read-ScaState)' {
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1' | Out-Null

            $r = Read-ScaState
            $r.active_slot    | Should -Be 'work'
            $r.last_sync_hash | Should -Be 'h1'
        }
    }

    AfterAll {
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
