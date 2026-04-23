# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Common Changelog](https://common-changelog.org),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
