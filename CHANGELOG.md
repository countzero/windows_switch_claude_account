# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Common Changelog](https://common-changelog.org),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-04-25

### Added
- `usage` action reports live 5-hour Session and 7-day Week plan-usage percentages per slot by calling Anthropic's undocumented `GET /api/oauth/usage` (the same endpoint Claude Code's own `/usage` slash command uses). Auto-refreshes expired OAuth tokens against `platform.claude.com/v1/oauth/token` in place so the hardlink to `.credentials.json` survives. `-json` emits the raw per-slot response (plus a `plan_status` field matching the Status column verbatim) for scripting.
- `sca usage -watch` renders a live, self-refreshing view of the usage table (or single-slot verbose view when combined with a slot name). Redraws once per second so reset deltas (`in 2h 37m`) tick visibly; re-polls the endpoint every `-interval` seconds (default **60 s**, floor **60 s** — values below get clamped up with a yellow advisory). Ctrl-C exits via the runtime's default handler; no other key bindings. Interactive-only: throws when combined with `-json` and refuses when `[Console]::IsOutputRedirected` is true. On mid-loop HTTP failure the previous snapshot stays visible with an advisory appended to the footer; the hardlink-broken warning is suppressed on redraws between polls.
- `sca usage <name>` verbose single-slot view: 4-line block with `Account:`, a `Status:` line carrying the plan-usability verdict (`limited 5h`, `near limit`, `ok`, …) and a short rationale tail, and `Session` / `Week` rows showing utilization plus absolute local-timezone reset stamps in the style Claude Code uses (`Resets 7:50pm Europe/Berlin`, `Resets Apr 26, 9am Europe/Berlin`).
- Pool-wide aggregate `Session` / `Week` progress bars rendered above the `sca usage` summary table (no slot-name argument), fitted to the table's width. Bars show usage (filled = used, empty = headroom) aggregated as `Σ min(util, 100) / (N * 100)` across HTTP-ok rows. Synth `<active>` matched is excluded to avoid double-counting; `<active> (unsaved)` is included. Color thresholds: Green below 50%, Yellow at 50%, Red at 90% (anchored to `UtilWarnPct` so "red" carries the same near-cap meaning at per-slot and pool scale).
- Plan-usability **Status** column on the `sca usage` summary table, replacing the older HTTP-only health column. Labels — `ok`, `ok (no plan data)`, `near limit`, `limited 5h`, `limited 7d`, `limited`, `expired`, `unauthorized`, `error: …`, `no-oauth (api key or non-claude.ai slot)` — are derived from `UtilWarnPct = 90` / `UtilLimitPct = 100` thresholds via `Get-PlanStatus`, with colors mapped through `Get-StatusColor` so the table and verbose view stay in lockstep. The `Session` and `Week` columns now carry merged bucket cells (`100% in 2h 37m`); column widths auto-fit per render.
- Synthetic `<active>` row rendered when `.credentials.json` is not hardlinked to any saved slot (e.g. after Claude Code atomically replaced the file during a token refresh). Label is `<active>` when the active file's content hashes to a saved slot, `<active> (unsaved)` otherwise. Addressable via `sca usage '<active>'` (or `sca usage '<active> (unsaved)'`) for the verbose drill-down — Powershell users must quote the argument so `<` / `>` are not parsed as redirection. The summary view emits a `sca list`-style advisory pointing at `sca switch <matched>` or `sca save <name>` as the repair step.
- Each slot's OAuth account email is embedded in the slot filename at `sca save` time using the RFC 5322 parenthesized-comment form (`.credentials.<slot>(<email>).json`). The email is rendered inline in a new `Account` column on both `sca list` and `sca usage` (middle-truncated at 32 chars; `—` for unlabeled slots and for the dedup form where slot name equals the email). Zero profile HTTP calls on the display path — the filename is the single source of truth, so the email cannot drift from the OAuth tokens stored in the same file. Save-time resolution hits Anthropic's undocumented `GET /api/oauth/profile` with Claude Code's exact `Ql()` header shape (`Authorization` + `Content-Type` only). Offline / failed saves fall back to the unlabeled filename; any subsequent `sca save` upgrades to the labeled form. `-json` carries the full untruncated email under `account.email`.
- `sca list` rebuilt as a 2-data-column table (`Slot | Account`) with a leading active-marker column, sharing layout / dedup / truncation with `Format-UsageTable` so the two views look like siblings.
- `sca switch` output rebuilt: a DarkYellow header line (`[Switch] Switched to '<slot>' (<email>)`), the saved-slot table beneath (re-enumerated post-switch so the `*` marker reflects the just-completed hardlink swap), and a cyan `[Info] Close and restart Claude Code to apply.` hint as the last line. Yellow advisory branches (locked active credentials file, no active match) print above the success line; the single-slot-already-active no-op skips the success line, table, and `[Info]` hint.
- 429 rate-limit resilience in `Get-SlotUsage`: each successful `/api/oauth/usage` response is cached per slot in-memory; on rate-limit the cached body is reused with a yellow `displaying cached data` advisory, so the watch loop and back-to-back invocations degrade gracefully under throttling.
- `Get-SafeName` now sanitizes `(` and `)` in user-provided slot names (to `_`), matching the treatment `[` / `]` already receive — both pairs could otherwise inject ambiguity into the parenthesized-email filename grammar. Existing slots with `(` or `)` are re-sanitized on the next `sca save`.
- `Get-Slots` performs a silent one-time sweep to delete any leftover `.credentials.*.profile.json` and `.credentials.profile.json` files from the earlier (pre-release) sidecar-based profile cache. No user action required.
- `Get-UsageSnapshot` / `Format-UsageFrame` / `Invoke-UsageWatch` split the usage action into a pure data-gathering layer, a pure rendering layer, and a thin timing loop, so the one-shot path and the `-watch` loop render identical frames from identical snapshots — and the rendering contract is asserted by frame-level Pester cases.
- `CLAUDE.md` documents the pinned `/api/oauth/usage` + `/api/oauth/profile` constants, the re-extraction grep recipe against `claude.exe`, the verified live response schemas, the two-bucket rendering scope, the aggregate-bar formula and slot-inclusion rule, the synth-row behavior, the filename-encoding grammar and parse rule, the save-time failure modes, the `-watch` loop design, the color-convention split (DarkYellow / Yellow / Green / Red / Cyan / DarkGray), and why the binary's hook-input schema should not be used to parse the raw endpoint.
- Pester suite split into per-action files (`tests/Invoke-<Action>Action.Tests.ps1`, `Helpers.Tests.ps1`, `Profile-Install.Tests.ps1`) with shared sandbox setup in `tests/Common.ps1`. Each file's outer `Describe` is `'switch_claude_account'` so the existing `-FullNameFilter` recipe keeps working unchanged. Total: 152 in-process tests covering the new usage/email/watch/aggregate-bar/Status/synth-row/filename-encoding paths.

### Changed
- Section-title headers (`[Usage] Plan usage`, `[List] Saved slots`, `[Switch] Switched to …`, `[Usage] Slot '<name>'`) recolored from Yellow to **DarkYellow**. Yellow is now reserved for advisories / warnings, restoring a visual distinction between header and warning that both used to share. Green / Red / Cyan / DarkGray roles also codified (success / destructive / info / dimmed metadata).
- Help screen `FILES` section emits literal `%USERPROFILE%` placeholders instead of interpolating them, so `sca help` no longer leaks the running user's Windows username.
- README expanded with `usage` / `usage -watch` / aggregate-bar / Status-column / Account-column / synth-row sections and corresponding example output.
- `.claude/worktrees/` added to `.gitignore`.

### Fixed
- `save` no longer aborts with a traceback when the `/api/oauth/profile` response returns an email containing NTFS-invalid characters (`<`, `>`, `|`, `:`, `*`, `?`, `"`, `\`, `/`) or when a pre-existing labeled slot file is locked by another process. The slot persists unlabeled, the hardlink from `.credentials.json` stays intact, and a yellow advisory describes the fallback. The `[Save] Saved as '<name>'` success line no longer claims an email label that did not actually land on disk — the email suffix is gated on a value set only when the rename to the labeled form (or the dedup no-rename path) actually succeeded.

## [1.1.0] - 2026-04-24

### Changed
- `save` and `switch` now replace `.credentials.json` with a hardlink to the named slot file instead of copying bytes. OAuth token refreshes written by Claude Code flow into the saved slot through the shared inode, so slots no longer go stale after an hour of inactivity.
- Slot names containing `[` or `]` are now sanitized to `_`. PowerShell's `-Path` parameter treats brackets as character-class wildcards, so `sca remove foo[bar]` previously deleted unrelated slots that happened to match the pattern (e.g. `fooa` and `foob`). All credential-file operations additionally switched to `-LiteralPath` as defense-in-depth.
- README now documents `sca switch` (no name) auto-rotation in its own subsection; previously only mentioned in `-h` output and the v1.0.0 changelog.

### Added
- `list` warns when `.credentials.json` is no longer hardlinked to any saved slot (e.g. Claude Code replaced it via atomic rename during a token refresh) and suggests `sca switch <name>` to repair auto-sync.
- `Test-HardlinkSupport` pre-flight check runs before every `save` / `switch` and fails early with a clear error on filesystems that cannot create hardlinks (FAT32, most network shares, non-NTFS volumes).

### Fixed
- `uninstall` preserves profile line endings byte-for-byte. The previous implementation read the profile with `Get-Content` (which strips line terminators) and rewrote with `-join "`r`n"`, silently converting LF or mixed-ending profiles to CRLF. `Remove-From-Profile` now splices the marker block out of the raw file content via regex replace.
- Test suite restores `$env:USERPROFILE` and `$global:PROFILE` in `AfterAll`. Running `Invoke-Pester -Path tests` interactively previously left the caller's session with `USERPROFILE` pointing at a deleted `$TestDrive` path and `PROFILE` as a stub `PSCustomObject`.

## [1.0.0] - 2026-04-23

### Added
- Single-file PowerShell switcher with `save`, `switch`, `list`, `remove`, `install`, `uninstall`, and `help` actions
- Named credential slots stored as `.credentials.<name>.json` under `%USERPROFILE%\.claude\`
- Auto-rotation: `sca switch` without a name rotates to the next saved slot alphabetically (wraps)
- Help screen as default action plus `-h` / `--help` switch
- `sca` (short) and `switch-claude-account` (long) aliases installed into the PowerShell profile via marker-delimited block
- Windows filename sanitization with reserved device name rejection (`CON`, `PRN`, `AUX`, `NUL`, `COM1-9`, `LPT1-9`)
- Profile install/uninstall that preserves existing encoding (UTF-8 with/without BOM, UTF-16 LE/BE) and refuses to mutate on orphan markers
- Pester 5 test suite (65 in-process tests) with auto-install and sandboxed `$env:USERPROFILE` / `$PROFILE.CurrentUserAllHosts` per test
- Optional PSScriptAnalyzer advisory pass in the test runner
- README with installation, usage, workflow, Windows notes, and testing sections
- `CLAUDE.md` with agent guidance for repo structure, gotchas, and script shape conventions
