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

        # Read-ScaState's ternaries coerce empty / missing JSON values to
        # $null so callers never have to disambiguate '' vs $null when
        # checking active_slot / last_sync_hash. Write-ScaState happens
        # to write null literals, but a manually edited or partially
        # written state file can carry empty strings; pin the contract.
        It 'coerces empty active_slot / last_sync_hash to $null' {
            $raw = '{"schema":1,"active_slot":"","last_sync_hash":""}'
            Set-Content -LiteralPath $StateFile -Value $raw -NoNewline -Encoding utf8NoBOM

            $r = Read-ScaState
            $r.schema         | Should -Be 1
            $r.active_slot    | Should -BeNullOrEmpty
            $r.last_sync_hash | Should -BeNullOrEmpty
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

        # Regression guard for the auto-migration's Get-SHA256Hex failure
        # tolerance branch: when the credentials file cannot be hashed
        # (e.g. read fails), Read-ScaState must surface $null without
        # throwing rather than crashing the caller.
        It 'returns null when .credentials.json cannot be hashed (Get-SHA256Hex throws)' {
            Set-Content -LiteralPath (Join-Path $script:SandboxCredDir '.credentials.json') -Value 'PAYLOAD' -NoNewline
            Mock Get-SHA256Hex -MockWith { throw [System.IO.IOException]::new('locked') }

            Read-ScaState | Should -BeNullOrEmpty
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

        # Defense-in-depth: Update-ScaState must not clobber the
        # last_warmup_at map when a caller mutates active_slot /
        # last_sync_hash. The two cooldown helpers and the swap
        # primitive both write the state file; a regression here
        # would silently empty the cooldown map on every swap.
        It 'preserves last_warmup_at across an active_slot / last_sync_hash update' {
            Set-SlotWarmupTimestamp -Name 'slot-1'
            Update-ScaState -ActiveSlot 'slot-2' -LastSyncHash 'h-new' | Out-Null

            $r = Read-ScaState
            $r.active_slot                   | Should -Be 'slot-2'
            $r.last_sync_hash                | Should -Be 'h-new'
            $r.last_warmup_at['slot-1']      | Should -BeGreaterThan 0
        }

        # Update-ScaState's no-current-state branch (line 'creates a
        # fresh state file when none exists' above) must seed the new
        # last_warmup_at field with @{} so a later Set-SlotWarmupTimestamp
        # has somewhere to write. Without this seed the next Read /
        # Write cycle would silently drop a Set-SlotWarmupTimestamp
        # call made between two Update-ScaState calls.
        It 'seeds last_warmup_at = @{} when no state file exists' {
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1' | Out-Null

            $r = Read-ScaState
            $null -eq $r.last_warmup_at | Should -BeFalse
            $r.last_warmup_at -is [hashtable] | Should -BeTrue
            $r.last_warmup_at.Count | Should -Be 0
        }
    }

    Context 'Get-/Set-SlotWarmupTimestamp' {
        # The cooldown helpers behind Invoke-WarmAllSlotsBySwitch.
        # Set-SlotWarmupTimestamp must round-trip through the state file
        # and Get-SlotWarmupTimestamp must return $null when no record
        # exists. The Set helper intentionally writes "now" rather than
        # accepting a timestamp parameter; backdating the cooldown clock
        # would defeat the per-slot rate-limit's whole point.

        It 'Get returns $null when no state file exists' {
            Get-SlotWarmupTimestamp -Name 'slot-1' | Should -BeNullOrEmpty
        }

        It 'Get returns $null when state file exists but slot has no entry' {
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h1' | Out-Null
            Get-SlotWarmupTimestamp -Name 'slot-X' | Should -BeNullOrEmpty
        }

        It 'Set then Get round-trips a millisecond timestamp via the state file' {
            $before = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Set-SlotWarmupTimestamp -Name 'slot-1'
            $after = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

            $stamp = Get-SlotWarmupTimestamp -Name 'slot-1'
            $stamp | Should -BeGreaterOrEqual $before
            $stamp | Should -BeLessOrEqual $after
        }

        It 'Set on multiple slots persists independent timestamps' {
            Set-SlotWarmupTimestamp -Name 'slot-1'
            Start-Sleep -Milliseconds 5
            Set-SlotWarmupTimestamp -Name 'slot-2'

            $s1 = Get-SlotWarmupTimestamp -Name 'slot-1'
            $s2 = Get-SlotWarmupTimestamp -Name 'slot-2'
            $s1 | Should -BeLessThan $s2
        }

        It 'Set updates an existing slot timestamp (cooldown clock restart)' {
            Set-SlotWarmupTimestamp -Name 'slot-1'
            $first = Get-SlotWarmupTimestamp -Name 'slot-1'
            Start-Sleep -Milliseconds 20
            Set-SlotWarmupTimestamp -Name 'slot-1'
            $second = Get-SlotWarmupTimestamp -Name 'slot-1'

            $second | Should -BeGreaterThan $first
        }

        # Coexistence contract: Set-SlotWarmupTimestamp must not disturb
        # active_slot / last_sync_hash. A regression here would mean
        # every warmup attempt corrupts the user's tracked active slot.
        It 'Set preserves active_slot and last_sync_hash' {
            Update-ScaState -ActiveSlot 'work' -LastSyncHash 'h-orig' | Out-Null
            Set-SlotWarmupTimestamp -Name 'slot-1'

            $r = Read-ScaState
            $r.active_slot    | Should -Be 'work'
            $r.last_sync_hash | Should -Be 'h-orig'
        }

        # Read-ScaState must normalize last_warmup_at to a hashtable even
        # when the state file was written by an older sca version (no
        # such field on disk). Without the @{} default, Get-SlotWarmup-
        # Timestamp would throw NullReferenceException on legacy state.
        It 'Read normalizes a legacy state file (no last_warmup_at field) to an empty map' {
            $legacyJson = '{"schema":1,"active_slot":"work","last_sync_hash":"h-legacy"}'
            Set-Content -LiteralPath $StateFile -Value $legacyJson -NoNewline -Encoding utf8NoBOM

            $r = Read-ScaState
            $r.active_slot     | Should -Be 'work'
            $null -eq $r.last_warmup_at | Should -BeFalse
            $r.last_warmup_at -is [hashtable] | Should -BeTrue
            $r.last_warmup_at.Count | Should -Be 0

            # And Set on the legacy state lifts it to the new shape.
            Set-SlotWarmupTimestamp -Name 'slot-1'
            (Read-ScaState).last_warmup_at['slot-1'] | Should -BeGreaterThan 0
        }
    }

    AfterAll {
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
