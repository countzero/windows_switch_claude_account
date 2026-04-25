# Claude Account Switcher

A zero-dependency PowerShell script for switching between multiple Claude Code accounts on Windows. Save, switch, and manage named credential slots — all from the command line.

## Features

- **Named slots** — Save unlimited accounts with custom names
- **Name sanitization** — Automatically handles special characters for Windows
- **Persistent aliases** — `sca` (short) and `switch-claude-account` (long) installed into your PowerShell profile
- **No dependencies** — Pure PowerShell, no external packages needed

## Installation

> **Requires PowerShell 7.0+.** Stock Windows ships PowerShell 5.1, which is not supported. Install PS 7 via `winget install Microsoft.PowerShell`, then run from `pwsh`.

### Download

Grab `switch_claude_account.ps1` from the
[repository on GitHub](https://github.com/countzero/windows_switch_claude_account)
and place it anywhere on disk — it is a single self-contained file with no
companion assets. From PowerShell:

```powershell
Invoke-WebRequest `
    https://raw.githubusercontent.com/countzero/windows_switch_claude_account/main/switch_claude_account.ps1 `
    -OutFile switch_claude_account.ps1
```

This pulls the latest version from the `main` branch. For a specific tagged
release, replace `main` with the tag (e.g. `v1.1.0`) and see the
[releases page](https://github.com/countzero/windows_switch_claude_account/releases)
for the version list and changelog.

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

### Rotate to the next slot

```powershell
sca switch
```

Without a name, `switch` activates the next slot in alphabetical order and wraps from the last slot back to the first. Useful for cycling through accounts without typing names. If the active credentials file is locked or does not match any saved slot, rotation falls back to the first slot and tells you so.

### Remove a slot

```powershell
sca remove test-project
```

### Check plan usage

```powershell
sca usage
```

Shows the 5-hour session limit ("Current session" in Claude Code's `/usage`, rendered as the `Session` column) and the 7-day weekly all-models limit ("Current week (all models)", rendered as the `Week` column) for every saved slot, as live percentages against each account's Claude.ai subscription. Two pool-wide progress bars above the table show how much aggregate headroom remains across all slots:

```
[Usage] Plan usage per slot

  Session [██████████████████████████████████████░░░░]  90%

  Week    [████████████████████████████████░░░░░░░░░░]  76%

     Slot      Account  Session         Week          Status
     --------  -------  --------------  ------------  ------
     work      —         18% in 2h 11m   42% in 103h  ok
  *  personal  —          3% in 4h 02m    7% in 146h  ok
     api-key   —          —               —           no-oauth (api key or non-claude.ai slot)
```

Each `Session` / `Week` cell merges utilization and reset delta into one string. Deltas under 24h keep minute precision (`in 2h 11m`); at 24h and above the column switches to an integer total-hours view (`in 103h`) to stay narrow. The aggregate bars sum the AVAILABLE headroom (100 − util) across HTTP-ok slots over `N × 100%`; `90%` above means roughly 10% of the pooled session budget has been used. Bar color is green when ≥50% headroom, yellow when ≥10%, red below.

Drill into a single slot for absolute reset times in your local timezone:

```
sca usage work
```

```
[Usage] Slot 'work' (active)
  Session     18%  Resets 7:50pm Europe/Berlin
  Week        42%  Resets Apr 28, 9am Europe/Berlin
```

### Who is each slot actually logged in as?

Slot names are user-assigned labels; nothing stops you from naming a slot `work` and then later overwriting it with credentials for a completely different account. At `sca save` time the tool fetches the OAuth account email and embeds it in the slot filename itself, using the RFC 5322 parenthesized-comment form:

```
%USERPROFILE%\.claude\.credentials.work(ada.lovelace@arpa.net).json
```

`sca usage` and `sca list` then surface the email inline in an `Account` column whenever it adds information:

```
[Usage] Plan usage per slot

  Session [█████████████████████████████████████████████████████░░░░░░░░░░░░]  82%

  Week    [██████████████████████████████████████████████████████████░░░░░░░]  90%

     Slot               Account                Session         Week          Status
     -----------------  ---------------------  --------------  ------------  ------
     ada@arpa.net       ada.lovelace@arpa.net   31% in 2h 14m   17% in 42h   ok
     alice@example.com  —                        5% in 3h 00m    2% in 120h  ok
```

Reading it:
- `ada@arpa.net` is the slot name you picked, but the tokens inside actually belong to `ada.lovelace@arpa.net`. The `Account` column surfaces the mismatch so you can repair it (`sca save ada.lovelace@arpa.net` then `sca remove ada@arpa.net`).
- `alice@example.com` shows `—` in the `Account` column because the slot name already equals the email — no new information to display. The filename is also deduplicated: `.credentials.alice@example.com.json` rather than `.credentials.alice@example.com(alice@example.com).json`.

Because the email lives in the filename, it cannot drift from the OAuth tokens stored in the same file. The only way to update a slot's email label is to re-run `sca save`, which re-fetches the profile and renames the file. Subsequent `sca usage` / `sca list` calls are zero-network for labels — the email is parsed straight out of the filename.

If `sca save` cannot reach the profile endpoint (offline, 401, timeout), the slot is saved with the old unlabeled name `.credentials.<slot>.json`. It still works; `sca usage` just omits the second line until you re-save while online.

`sca switch <name>` and `sca remove <name>` continue to take just the slot name — the tool finds the matching file regardless of whether it carries the `(email)` suffix.

### Hardlink-broken state (synthetic `<active>` row)

When Claude Code rewrites `.credentials.json` via atomic rename during a token refresh, the hardlink that `sca save` / `sca switch` sets up is broken. `sca usage` detects this and adds a synthetic row so you still see the usage Claude Code is actually reporting:

```
[Usage] Plan usage per slot

  Session [█████████████████████████████████████░░░░░░░░░░░░░░░]  71%

  Week    [█████████████████████████████████████████████░░░░░░░]  87%

     Slot                Account  Session         Week          Status
     ------------------  -------  --------------  ------------  ------
     work                —          5% in 3h 00m    7% in 120h  ok
  *  <active> (unsaved)  —         53% in 2h 00m   19% in 40h   ok
[Usage] Warning: .credentials.json is not hardlinked to any saved slot. Run 'sca save <name>' to capture the active session, or 'sca switch <name>' to overwrite it with a saved slot.
```

Label conventions:
- `<active>` — the active-file content matches a saved slot (tokens are equivalent, only the hardlink was lost); the warning points at `sca switch <matched-slot>` to repair auto-sync.
- `<active> (unsaved)` — content matches no saved slot; `sca save <name>` to capture it or `sca switch <name>` to discard.

You can drill into the synthetic row directly (quote the name so the shell does not interpret `<` / `>` as redirection):

```powershell
sca usage '<active>'              # either label works
sca usage '<active> (unsaved)'    # exact label also accepted
```

Other forms:

```powershell
sca usage work          # verbose single-slot report (shows opus / sonnet / overage buckets)
sca usage -NoRefresh    # do not auto-refresh expired OAuth tokens
sca usage -Json         # emit per-slot JSON for scripting
```

> **Unofficial API.** The `usage` action calls `api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` command uses internally. The endpoint is undocumented by Anthropic and the action may break on Claude Code upgrades; when that happens, see the extraction recipe at the top of `switch_claude_account.ps1` to re-pin the constants.

If a slot's access token has expired (default TTL ~1h), `sca usage` transparently refreshes it against `platform.claude.com/v1/oauth/token` using the slot's refresh token, rewriting the slot file in place so any hardlink to `.credentials.json` survives. Pass `-NoRefresh` to disable this and only report stale slots.

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
Spaces, Windows-invalid filename characters (`\ / : * ? " < > |` and control chars), and PowerShell wildcard brackets (`[` `]`) are automatically replaced with `_`. Trailing dots are stripped. Reserved Windows device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`) are rejected with an error.

- `my personal` → `my_personal`
- `foo/bar` → `foo_bar`
- `foo[bar]` → `foo_bar_`
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

