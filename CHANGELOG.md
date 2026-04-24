# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Common Changelog](https://common-changelog.org),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
