# Claude Account Switcher

A zero-dependency PowerShell script for switching between multiple Claude Code accounts on Windows. Save, switch, and manage named credential slots — all from the command line.

## Features

- **Named slots** — Save unlimited accounts with custom names
- **Name sanitization** — Automatically handles special characters for Windows
- **Persistent aliases** — `sca` (short) and `switch-claude-account` (long) installed into your PowerShell profile
- **No dependencies** — Pure PowerShell, no external packages needed

## Installation

> **Requires PowerShell 7.0+.** Stock Windows ships PowerShell 5.1, which is not supported. Install PS 7 via `winget install Microsoft.PowerShell`, then run from `pwsh`.

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

### Saving accounts

1. Open Claude Code and log in with your first account
2. **Close Claude Code** (Windows locks the credentials file while it runs)
3. Run `sca save work`
4. Open Claude Code, log out, log in with a different account
5. **Close Claude Code**
6. Run `sca save personal`

### Switching between accounts

1. **Close Claude Code**
2. Run `sca switch work`
3. Open Claude Code — it now uses the `work` credentials

### Refreshing a stale slot

OAuth tokens expire after ~1 hour of inactivity. If a saved slot stops working:

1. Log into that account in Claude Code
2. **Close Claude Code**
3. Run `sca save work` again — this overwrites the old token with fresh credentials

> `sca save <name>` silently overwrites any existing slot with the same name.

### Renaming a slot

1. `sca switch old-name`
2. `sca save new-name`
3. `sca remove old-name`

## Windows Notes

### File locks
Close Claude Code / VS Code before running `sca save` or `sca switch` (see Workflow). PowerShell will show a clear error if you try to overwrite a locked file.

### Name sanitization
Spaces and Windows-invalid filename characters (`\ / : * ? " < > |` and control chars) are automatically replaced with `_`. Trailing dots are stripped. Reserved Windows device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`) are rejected with an error.

- `my personal` → `my_personal`
- `foo/bar` → `foo_bar`
- `foo.` → `foo`
- `CON` → error (reserved device name)

### Profile encoding
`sca install` and `sca uninstall` preserve your PowerShell profile's existing encoding (UTF-8 with or without BOM, UTF-16 LE/BE). ANSI-encoded profiles are treated as UTF-8 no-BOM, which is indistinguishable without a BOM.

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

## Testing

The test suite uses [Pester 5](https://pester.dev) and lives in `tests/`.

### Run all tests

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1
```

The runner will:
1. **Auto-install Pester 5** to the CurrentUser scope on first use (no admin rights needed).
2. Run **PSScriptAnalyzer** in advisory mode if it is installed — findings are printed but never fail the run. If not installed, the runner prints a one-line skip notice and proceeds.
3. Invoke Pester against `tests/switch_claude_account.Tests.ps1` with `-Output Detailed`.

Exit code follows Pester: `0` on pass, non-zero on any failure.

### Optional: enable the lint pass

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

### Run Pester directly (skip the runner)

If Pester 5 is already installed:

```powershell
Invoke-Pester -Path tests -Output Detailed
```

### Sandboxing

Each test runs with `$env:USERPROFILE` pointed at Pester's `$TestDrive` and `$PROFILE.CurrentUserAllHosts` stubbed to a file inside `$TestDrive`. Your real `%USERPROFILE%\.claude\` directory and your real PowerShell profile are never touched.

