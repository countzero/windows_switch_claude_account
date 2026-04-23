# Claude Account Switcher

A zero-dependency PowerShell script for switching between multiple Claude Code accounts on Windows. Save, switch, and manage named credential slots — all from the command line.

## Features

- **Named slots** — Save unlimited accounts with custom names
- **Name sanitization** — Automatically handles special characters for Windows
- **Built-in alias installer** — One command to set up `cs` shortcut
- **No dependencies** — Pure PowerShell, no external packages needed
- **Profile management** — `install`/`uninstall` for persistent alias

## Installation

### Manual (run once)

```powershell
.\switch_claude_account.ps1 install
```

This adds a `cs` alias to your PowerShell profile. Close and reopen your terminal to activate it.

### Without alias

Run the script directly:

```powershell
.\switch_claude_account.ps1 <action> [name]
```

## Usage

### Save an account

Log into an account in Claude Code, then save it:

```powershell
cs save work
cs save personal
cs save test-project
```

### List saved slots

```powershell
cs list
```

### Switch to a slot

```powershell
cs switch work
```

### Remove a slot

```powershell
cs remove test-project
```

### Install / uninstall alias

```powershell
cs install      # Add cs alias to your PowerShell profile
cs uninstall    # Remove cs alias from your PowerShell profile
cs help         # Show usage info
```

## Workflow

1. Open Claude Code and log in with your first account
2. Run `cs save work`
3. Log out, log in with a different account
4. Run `cs save personal`
5. Switch back anytime with `cs switch work`

## Windows Notes

### File locks
Close Claude Code / VS Code before running `cs switch` or `cs save`. Windows locks the credentials file while the app is running. PowerShell will show a clear error if you try to overwrite a locked file.

### Token expiry
OAuth tokens refresh/expire after ~1 hour of inactivity. If a saved slot stops working, log back into that account in Claude Code and run `cs save <name>` again. The script safely overwrites the old token.

### Name sanitization
Spaces and special characters are automatically replaced with `_`:
- `my-work-account` → `my_work_account`
- `my personal` → `my_personal`

### Execution policy
If you get a security warning on first run, press `Y` or run once as:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## How it works

The script manages credentials stored at:
- **Credentials file**: `%USERPROFILE%\.claude\.credentials.json`
- **Backup directory**: `%USERPROFILE%\.claude-swap-backup\`

Each `save` copies the credentials file to a named JSON file in the backup directory. Each `switch` copies the named file back to the credentials location.

## Alias details

The `cs` alias is installed in your PowerShell profile (`$PROFILE`). It wraps the script with two parameters: action and optional name. The alias definition looks like:

```powershell
function claude-acct { param([string]$a, [string]$n) & 'C:\path\to\switch_claude_account.ps1' $a $n }
Set-Alias -Name cs -Value claude-acct -Option AllScope
```

The alias is marked with `# === Claude Account Switcher ===` markers so it can be cleanly removed with `uninstall`.