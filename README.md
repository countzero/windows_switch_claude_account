# Claude Account Switcher

A zero-dependency PowerShell tool for managing multiple Claude Code accounts on Windows. Save, switch, and watch live plan usage across all your slots — single self-contained `.ps1`, no companion files.

## Features

- **Live plan-usage dashboard** — `sca usage -Watch` polls Anthropic's `/api/oauth/usage` and renders a flicker-free, auto-refreshing view of Session (5h) and Week (7d) limits across every slot
- **Identity-aware slots** — each slot's OAuth email is captured at save time, baked into the filename, and locked in a sidecar; what you see in `list` is guaranteed to be who the tokens actually belong to
- **Auto-reconcile** — silently captures Claude Code's hourly token refreshes into the tracked slot; auto-saves cross-account swaps under a timestamped name so you never lose state
- **Transparent token refresh** — expired access tokens are refreshed before usage queries and mirrored back into the active credentials file
- **Atomic-safe writes** — slot-file updates survive a running Claude Code via `MoveFileEx` with retry; `save` / `switch` still refuse to run while it's open (single source of truth on `~/.claude.json`)
- **Named slots with rotation** — unlimited accounts under any name (Windows-invalid characters auto-sanitized); `sca switch` with no name cycles through them alphabetically
- **Zero dependencies** — pure PowerShell 7.2+, no external packages, no companion assets

## What `sca usage -Watch` looks like

```ansi
[33m[Usage] Plan usage[0m

  Session  [[92m█████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░[0m]  [92m22%[0m

  Week     [[93m██████████████████████████░░░░░░░░░░░░░░░░░[0m]  [93m62%[0m

     Slot         Account                 Session         Week           Status
     -----------  ----------------------  --------------  -------------  -----------
[92m  *  work         —                        18% (2h 11m)    42% (102h)     ok[0m
[37m     personal     —                         3% (4h 02m)     7% (146h)     ok[0m
[37m     dev          —                         9% (3h 41m)    34% (118h)     ok[0m
[93m     client-acme  ada.lovelace@arpa.net    71% (1h 04m)    92% (41h)      near limit[0m
[91m     legacy       team@example.com         12% (3h 18m)   103% now        limited 7d[0m

[90m[Watch] Last poll: 14:32:07  |  next in 47s[0m
```

> Bar color: green &lt;50%, yellow ≥50%, red ≥90%. Row color tracks slot status: green for the active+`ok` slot (including the `*` marker), gray for healthy inactive slots, yellow for `near limit` (≥90%), red for `limited 5h` / `limited 7d` (≥100%).

## Installation

> **Requires PowerShell 7.2+.** Stock Windows ships PowerShell 5.1, which is not supported. Install PS 7 via `winget install Microsoft.PowerShell`, then run from `pwsh`.

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

For a tagged release, replace `main` with the tag (e.g. `v1.1.0`); see the
[releases page](https://github.com/countzero/windows_switch_claude_account/releases)
for the version list and changelog.

### Manual (run once)

```powershell
.\switch_claude_account.ps1 install
```

This adds `sca` (short) and `switch-claude-account` (long) aliases to your PowerShell profile. Close and reopen your terminal to activate them.

### Without alias

```powershell
.\switch_claude_account.ps1 <action> [name]
```

## Usage

### Save an account

Log into an account in Claude Code, **close Claude Code**, then save:

```powershell
sca save work
sca save personal
sca save test-project
```

`save` refuses to run while Claude Code is open and refuses to save a slot whose identity it cannot resolve from `~/.claude.json` (primary) or `/api/oauth/profile` (fallback). There are no unlabeled-no-identity slots. To rename a slot: `sca switch old-name; sca save new-name; sca remove old-name`.

### List saved slots

```powershell
sca list
```

The active slot is marked with `*` (sourced from `~/.claude/.sca-state.json`). Slots whose identity sidecar is missing or invalid are hidden from the list, from rotation, and from `switch`; re-running `sca save <name>` while that slot is active recaptures the sidecar.

### Switch to a slot

```powershell
sca switch work
```

`switch` refuses to run while Claude Code is open. It atomically writes the slot's bytes into `.credentials.json` AND restores the slot's captured `oauthAccount` block into `~/.claude.json` so Claude Code's `/status` shows the matching email.

### Rotate to the next slot

```powershell
sca switch
```

Without a name, `switch` activates the next slot in alphabetical order and wraps from the last back to the first. The current position comes from `state.active_slot`.

### Remove a slot

```powershell
sca remove test-project
```

`remove` refuses to delete the slot tracked as currently active.

### Identity capture: who is each slot actually logged in as?

Slot names are user-assigned labels; nothing stops you from naming a slot `work` and later overwriting it with credentials for a completely different account. At `sca save` time the tool pulls the OAuth email from `~/.claude.json`'s `oauthAccount` block (Claude Code's own cache) and embeds it in the slot filename:

```
%USERPROFILE%\.claude\.credentials.work(ada.lovelace@arpa.net).json
```

A paired sidecar `.credentials.work(ada.lovelace@arpa.net).account.json` holds the full whitelisted identity (`accountUuid`, `emailAddress`, `organizationUuid`, `displayName`, `organizationName`) so `sca switch` can restore the matching `oauthAccount` block to `~/.claude.json`. Because the email is captured at save time and carried in both the filename and sidecar, it cannot drift from the OAuth tokens — the only way to update a slot's email label is to re-run `sca save`.

When the slot name already equals the OAuth email, the filename is deduplicated to `.credentials.alice@example.com.json` and the `Account` column shows `—`.

### Check plan usage

```powershell
sca usage                         # one-shot table for every slot
sca usage work                    # verbose single-slot block (opus / sonnet / overage)
sca usage -Watch                  # live, self-refreshing view; Ctrl-C to quit
sca usage -Watch -Interval 300    # slower poll cadence (60s floor)
sca usage -Json                   # machine-readable per-slot output
sca usage -NoColor                # strip ANSI color (also: $env:NO_COLOR='1')
```

`-NoColor` works under `-Watch` too — body color is stripped while the alt-buffer / synchronized-output rendering remains flicker-free. The output shows the 5-hour session limit (`Session` column, "Current session" in Claude Code's `/usage`) and the 7-day weekly all-models limit (`Week` column, "Current week (all models)") as percentages of each account's Claude.ai subscription:

```
[Usage] Plan usage

  Session [████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  10%

  Week    [██████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  24%

     Slot      Account  Session         Week           Status
     --------  -------  --------------  -------------  ------
  *  work      —         18% (2h 11m)    42% (102h)    ok
     personal  —          3% (4h 02m)     7% (146h)    ok
     api-key   —          —               —            no-oauth (api key or non-claude.ai slot)
```

Decoding the output:

- **Pool-aggregate bars** — sum utilization across HTTP-ok slots over `N × 100%`. Bar color: green &lt;50%, yellow ≥50%, red ≥90%.
- **Active marker (`*`)** — sourced from `~/.claude/.sca-state.json`; appears at the start of the row and inherits the row's color.
- **`Account` column** — the OAuth email captured at save time. Shows `—` when the email equals the slot name (deduped filename), the actual email otherwise.
- **`Session` / `Week` cells** — `<pct>% <delta>`. The delta is `(2h 11m)` under 24h with minute precision, `(102h)` at 24h+ with integer hours, `now` if the reset is past, or `—` when no data is available.
- **`Status` column** — one of `ok`, `near limit` (≥90%), `limited 5h` / `limited 7d` (≥100%), `error`, `expired`, `unauthorized`, `rate-limited`, or `no-oauth`. Status drives the entire row's color.

Drill into a single slot for absolute reset times in your local timezone:

```powershell
sca usage work
```

```
[Usage] Slot 'work' (active)
  Session     18%  Resets 7:50pm Europe/Berlin
  Week        42%  Resets Apr 28, 9am Europe/Berlin
```

`list`, `switch`, and `usage` run a quiet **reconcile** pass before doing their work: if `.credentials.json` has changed since the last sync (Claude Code refreshed a token, or you logged into a different account inside Claude Code), the new bytes are captured into the tracked slot — or auto-saved under `auto-<UTC-timestamp>(<email>).json` if the email differs.

> **Unofficial API.** `sca usage` calls `api.anthropic.com/api/oauth/usage`, the same endpoint Claude Code's `/usage` uses internally. Undocumented by Anthropic and may break on Claude Code upgrades; when that happens, see the extraction recipe at the top of `switch_claude_account.ps1` to re-pin the constants.

> **Token refresh.** If a slot's access token has expired (default TTL ~1h), `sca usage` transparently refreshes it against `platform.claude.com/v1/oauth/token` and mirrors the new tokens back into both the slot file and `.credentials.json` via atomic rename so the active session keeps working.

### Install / uninstall alias

```powershell
sca install      # Add aliases to your PowerShell profile
sca uninstall    # Remove aliases from your PowerShell profile
sca help         # Show usage info
```

## Workflow

### Saving accounts

1. Open Claude Code and log in with your first account
2. **Close Claude Code**
3. Run `sca save work`
4. Open Claude Code, log out, log in with a different account
5. **Close Claude Code**
6. Run `sca save personal`

If Claude Code is running when you invoke `save` or `switch`, the action exits immediately with a clear message — no partial writes occur.

### Switching between accounts

1. **Close Claude Code**
2. Run `sca switch work`
3. Open Claude Code — it now uses the `work` credentials and `/status` shows the matching email

### Why close Claude Code first?

`sca save` and `sca switch` read and write `~/.claude.json`'s `oauthAccount` block. Claude Code keeps that block in an in-memory cache that may flush back and clobber the update. Closing the app eliminates the race. (Slot-file updates done by `sca usage`'s token refresh use `MoveFileEx` with retry, so they survive an open Claude Code on `.credentials.json` itself — but the `~/.claude.json` cache race means you still need to close it for the two write actions.)

## Windows Notes

### Name sanitization
Spaces, Windows-invalid filename characters (`\ / : * ? " < > |` and control chars), and PowerShell wildcard brackets (`[` `]`) are automatically replaced with `_`. Trailing dots are stripped. Reserved Windows device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, `LPT1`-`LPT9`) are rejected.

- `my personal` → `my_personal`
- `foo/bar` → `foo_bar`
- `foo[bar]` → `foo_bar_`
- `foo.` → `foo`
- `CON` → error (reserved device name)

### Profile encoding
`sca install` and `sca uninstall` preserve your PowerShell profile's existing encoding (UTF-8 with or without BOM, UTF-16 LE/BE). ANSI-encoded profiles are treated as UTF-8 no-BOM (indistinguishable without a BOM).

### State file
The active-slot tracker lives at `%USERPROFILE%\.claude\.sca-state.json` — plain JSON, safe to inspect. Schema: `{ schema, active_slot, last_sync_hash }`.

### Execution policy
If you get a security warning on first run, press `Y` or run once as:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Testing

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1
```

Pester 5 is auto-installed to `CurrentUser` scope on first use. PSScriptAnalyzer runs in advisory mode if installed. Each test sandboxes `$env:USERPROFILE` and `$PROFILE.CurrentUserAllHosts` to Pester's `$TestDrive` so your real `.claude\` directory and PowerShell profile are never touched. Exit code follows Pester: `0` on pass, non-zero on any failure.

---

For the architecture (state file, sidecar invariants, `~/.claude.json` ownership, unofficial API constants), see [`CLAUDE.md`](./CLAUDE.md).
