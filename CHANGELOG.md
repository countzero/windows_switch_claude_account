# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Common Changelog](https://common-changelog.org),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `usage` action reports live 5-hour session and 7-day weekly plan-usage percentages per slot by calling Anthropic's undocumented `GET /api/oauth/usage` (the same endpoint Claude Code's own `/usage` slash command uses). Auto-refreshes expired OAuth tokens against `platform.claude.com/v1/oauth/token` in-place so the hardlink to `.credentials.json` survives. `-Json` emits the raw per-slot response; `-NoRefresh` disables the auto-refresh.
- `sca usage <name>` shows a verbose single-slot view with friendly labels (`Session (5h)`, `Weekly (all models)`) and absolute local-timezone reset timestamps in the style Claude Code uses (`Resets 7:50pm Europe/Berlin`, `Resets Apr 26, 9am Europe/Berlin`).
- Synthetic `<active>` row rendered when `.credentials.json` is not hardlinked to any saved slot (e.g. after Claude Code atomically replaced it during a token refresh), so users still see the usage Claude Code is actually reporting. Label is `<active>` when the active-file content matches a saved slot, `<active> (unsaved)` otherwise. Addressable via `sca usage '<active>'` or `sca usage '<active> (unsaved)'` for the verbose drill-down. The summary table also emits a `sca list`-style warning pointing at `sca switch <matched>` or `sca save <name>` as the repair step.
- Each slot's OAuth account email is embedded in the slot filename at `sca save` time using the RFC 5322 parenthesized-comment form (`.credentials.<slot>(<email>).json`). `sca usage` and `sca list` surface the email on an indented second line (`  └─ <email>`) when it differs from the slot name; zero profile HTTP calls on the display path. Save-time resolution hits Anthropic's undocumented `GET /api/oauth/profile` with Claude Code's exact `Ql()` header shape (`Authorization` + `Content-Type` only). Offline / failed saves fall back to the unlabeled filename (`.credentials.<slot>.json`); any subsequent `sca save` upgrades to the labeled form. Because the filename is the single source of truth, the email cannot drift from the OAuth tokens stored in the same file — fixing the cache-staleness class of bug the previous sidecar-based implementation was vulnerable to. `-Json` output gains an `account.email` field per entry when the labeled filename carries an email.
- `Get-SafeName` now sanitizes `(` and `)` in user-provided slot names (to `_`), matching the treatment `[` / `]` already receive — both pairs could otherwise inject ambiguity into the parenthesized-email filename grammar. Existing slots with `(` or `)` in their names would be re-sanitized on the next `sca save`.
- `Get-Slots` performs a silent one-time sweep to delete any leftover `.credentials.*.profile.json` and `.credentials.profile.json` files from the earlier (pre-release) sidecar-based profile cache. No user action required.
- Pester coverage: 22 `Invoke-UsageAction` cases (happy path, empty `{}`, null `resets_at`, no-OAuth slot, 401, timeout, expired+refresh, expired+-NoRefresh, expired+refresh-fail, -Json round-trip, hardlink preservation across refresh, synth row with/without saved-slot content match, no synth + no warning on hardlinked active file, synth row on fresh-install (no saved slots), verbose drill-down on synth row, bare `<active>` alias acceptance, no-synth-state throw, -Json includes synth entry, labeled filename produces second line, dedup suppresses second line, unlabeled slot renders single line), 5 `Get-SlotProfile` cases (happy/401/timeout/no-oauth/expired+refresh), 8 `Get-SlotFileInfo` parser cases + a null-returning default, 4 `Invoke-SaveAction` filename-encoding cases (labeled on success, unlabeled on failure, dedup on name==email, rename on account change), a `Get-Slots` sidecar-cleanup + labeled-parse case, an `Invoke-SwitchAction` labeled-lookup case, an `Invoke-RemoveAction` labeled-lookup case, and 3 `Get-SafeName` paren-sanitization cases. Plus the existing `Format-ResetDelta` and `Format-ResetAbsolute` formatter suites.
- `CLAUDE.md` documents the pinned `/api/oauth/usage` + `/api/oauth/profile` constants, the re-extraction grep recipe against `claude.exe`, the verified live response schemas, the two-bucket rendering scope, the synth-row behavior, the filename-encoding grammar and parse rule, the save-time failure modes, and why the binary's hook-input schema should not be used to parse the raw endpoint.

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
