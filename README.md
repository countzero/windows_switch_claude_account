# Claude Account Switcher

A zero-dependency PowerShell script for switching between multiple Claude Code accounts on Windows. Save, switch, and manage named credential slots — all from the command line.

## Features

- **Named slots** — Save unlimited accounts with custom names
- **Name sanitization** — Automatically handles special characters for Windows
- **Built-in alias installer** — One command to set up `sca` (short) and `switch-claude-account` (long)
- **No dependencies** — Pure PowerShell, no external packages needed
- **Profile management** — `install`/`uninstall` for persistent alias

## Installation

### Manual (run once)

```powershell
.\switch_claude_account.ps1 install
```

This adds `sca` (short) and `switch-claude-account` (long) aliases to your PowerShell profile. Close and reopen your terminal to activate them.

### Without alias

Run the script directly:

```powershell
.\switch_claude_account.ps1 <action> [name]
```

## Usage

### Save an account

Log into an account in Claude Code, then save it:

```powershell
sca save work
sca save personal
sca save test-project
```

### List saved slots

```powershell
sca list
```

### Switch to a slot

```powershell
sca switch work
```

### Remove a slot

```powershell
sca remove test-project
```

### Install / uninstall alias

```powershell
sca install      # Add aliases to your PowerShell profile
sca uninstall    # Remove aliases from your PowerShell profile
sca help         # Show usage info
```

## Workflow

1. Open Claude Code and log in with your first account
2. Run `sca save work`
3. Log out, log in with a different account
4. Run `sca save personal`
5. Switch back anytime with `sca switch work`

## Windows Notes

### File locks
Close Claude Code / VS Code before running `sca switch` or `sca save`. Windows locks the credentials file while the app is running. PowerShell will show a clear error if you try to overwrite a locked file.

### Token expiry
OAuth tokens refresh/expire after ~1 hour of inactivity. If a saved slot stops working, log back into that account in Claude Code and run `sca save <name>` again. The script safely overwrites the old token.

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
- **Slot files**: `%USERPROFILE%\.claude\.credentials.<name>.json`

Each `save` copies the credentials file to `.credentials.<name>.json` in the same directory. Each `switch` copies the named slot back to `.credentials.json`.

