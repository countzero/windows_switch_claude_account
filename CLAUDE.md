# CLAUDE.md

## Repo structure

Single-file PowerShell tool — everything lives in `switch_claude_account.ps1`. No build, test, lint, or dependency system.

## Key facts

- **Credential directory**: `%USERPROFILE%\.claude\`
- **Active credentials**: `.credentials.json`
- **Named slots**: `.credentials.<name>.json`
- **PS version**: Requires PowerShell 5.0+ (`#Requires -Version 5.0`)
- **Alias installer**: `sca` and `switch-claude-account` added to PowerShell profile via marker-delimited block

## Windows-specific gotchas

- **File locks**: `Copy-Item -Force` fails if Claude Code or VS Code has `.credentials.json` open. Always close the app before `save` or `switch`.
- **Execution policy**: May need `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` on first run.
- **Token expiry**: OAuth tokens refresh/expire after ~1 hour of inactivity. Stale slots need re-saving.
- **Name sanitization**: Invalid Windows filename characters (including `\ / : * ? " < > |` and control chars) are replaced with `_`.

## Script actions

| Action     | Requires name | What it does |
|------------|---------------|--------------|
| `save`     | Yes           | Copies `.credentials.json` → `.credentials.<name>.json` |
| `switch`   | Yes           | Copies `.credentials.<name>.json` → `.credentials.json` |
| `list`     | No            | Lists saved slot names |
| `remove`   | Yes           | Deletes a named slot |
| `install`  | No            | Adds wrapper function + aliases to PowerShell profile |
| `uninstall`| No            | Removes wrapper function + aliases from profile |
| `help`     | No            | Shows detailed help |

## Editing the script

The profile install/uninstall uses marker comments (`# === Claude Account Switcher ===`) to isolate its block. When modifying `Add-To-Profile` or `Remove-From-Profile`, keep these markers intact.
