# CLAUDE.md

## Repo structure

Single-file PowerShell tool — core logic lives in `switch_claude_account.ps1`. Tests live in `tests/` and use Pester 5.

## Key facts

- **Credential directory**: `%USERPROFILE%\.claude\`
- **Active credentials**: `.credentials.json`
- **Named slots**: `.credentials.<name>.json`
- **PS version**: Requires PowerShell 7.0+ (`#Requires -Version 7.0`). Uses `$PROFILE.CurrentUserAllHosts` for the install target.
- **Alias installer**: `sca` and `switch-claude-account` added to PowerShell profile via marker-delimited block

## Windows-specific gotchas

- **File locks**: `Copy-Item -Force` fails if Claude Code or VS Code has `.credentials.json` open. Always close the app before `save` or `switch`.
- **Execution policy**: May need `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` on first run.
- **Token expiry**: OAuth tokens refresh/expire after ~1 hour of inactivity. Stale slots need re-saving.
- **Name sanitization**: Invalid Windows filename characters (`\ / : * ? " < > |` and control chars), PowerShell wildcard brackets (`[` `]`), and spaces are replaced with `_`. Brackets are sanitized because PowerShell's `-Path` parameter treats them as character-class wildcards; without sanitization, `sca remove foo[bar]` would silently wildcard-match unrelated slot files. Paired with `-LiteralPath` on every credential-file op as defense-in-depth.

## Script actions

| Action     | Requires name | What it does |
|------------|---------------|--------------|
| `save`     | Yes           | Copies `.credentials.json` → `.credentials.<name>.json` |
| `switch`   | Optional      | Copies `.credentials.<name>.json` → `.credentials.json`. If `<name>` is omitted, rotates to the next saved slot in alphabetical order (wraps around). |
| `list`     | No            | Lists saved slot names |
| `remove`   | Yes           | Deletes a named slot |
| `install`  | No            | Adds wrapper function + aliases to PowerShell profile |
| `uninstall`| No            | Removes wrapper function + aliases from profile |
| `help`     | No            | Shows detailed help |

## Editing the script

The profile install/uninstall uses marker comments (`# === Claude Account Switcher ===`) to isolate its block. When modifying `Add-To-Profile` or `Remove-From-Profile`, keep these markers intact.

The top-level dispatcher is wrapped in `Invoke-Main` and guarded by `if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }` so tests can dot-source the script without triggering a live run. Each action body (`save`, `switch`, `list`, `remove`) is extracted into an `Invoke-*Action` function so tests can call it directly. Keep this shape when adding new actions — put the body in `Invoke-<Action>Action` and add a one-line dispatch to `Invoke-Main`.

## Testing

Run the suite:

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1
```

The runner auto-installs Pester 5 (CurrentUser scope) on first use. PSScriptAnalyzer, if installed, runs in advisory mode — findings are printed but never fail the run.

Tests sandbox `$env:USERPROFILE` and `$PROFILE.CurrentUserAllHosts` per test via `$TestDrive`, so the real profile and real `.claude` directory are never touched.
