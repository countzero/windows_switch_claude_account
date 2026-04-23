# Project: Claude Account Switcher

## Purpose
A PowerShell script for switching between multiple Claude Code accounts on Windows. Zero dependencies, named-slot management, built-in alias installer.

## Key Files
- `switch_claude_account.ps1` — Main script (save/switch/list/remove/install/uninstall/help)
- `README.md` — Full usage guide

## How to Run
```powershell
.\switch_claude_account.ps1 <action> [name]
```

Actions: `save`, `switch`, `list`, `remove`, `install`, `uninstall`, `help`

## Architecture
- Credentials stored at `%USERPROFILE%\.claude\.credentials.json`
- Backups stored at `%USERPROFILE%\.claude-swap-backup\`
- Alias installed in `$PROFILE` with `install` action
- Name sanitization replaces special chars with `_` for Windows safety