# CLAUDE.md

## Repo structure

Single-file PowerShell tool — core logic lives in `switch_claude_account.ps1`. Tests live in `tests/` and use Pester 5.

## Key facts

- **Credential directory**: `%USERPROFILE%\.claude\`
- **Active credentials**: `.credentials.json` — after the first `switch` or `save`, this is a hardlink to the active slot file. OAuth token refreshes in both paths simultaneously.
- **Named slots**: `.credentials.<name>.json`
- **PS version**: Requires PowerShell 7.0+ (`#Requires -Version 7.0`). Uses `$PROFILE.CurrentUserAllHosts` for the install target.
- **Alias installer**: `sca` and `switch-claude-account` added to PowerShell profile via marker-delimited block

## Windows-specific gotchas

- **File locks**: `Remove-Item` / `New-Item -HardLink` fail if Claude Code or VS Code has `.credentials.json` open. Always close the app before `save` or `switch`. `usage` tolerates a running Claude Code for the read path, but if it has to refresh an expired token the in-place `Set-Content` write may fail under lock; rerun after Claude Code exits.
- **Execution policy**: May need `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` on first run.
- **Token expiry**: OAuth tokens refresh/expire after ~1 hour of inactivity. Hardlinked slots auto-sync, so stale slots are self-healing — Claude Code will refresh on the next call.
- **Hardlink detection**: `list` warns if `.credentials.json` is no longer hardlinked (likely from a Claude Code write that broke the link). Run `sca switch <name>` to repair.
- **Name sanitization**: Invalid Windows filename characters (`\ / : * ? " < > |` and control chars), PowerShell wildcard brackets (`[` `]`), and spaces are replaced with `_`. Brackets are sanitized because PowerShell's `-Path` parameter treats them as character-class wildcards; without sanitization, `sca remove foo[bar]` would silently wildcard-match unrelated slot files. Paired with `-LiteralPath` on every credential-file op as defense-in-depth.

## Script actions

| Action     | Requires name | What it does |
|------------|---------------|--------------|
| `save`     | Yes           | Copies `.credentials.json` → `.credentials.<name>.json`, then re-links `.credentials.json` as a hardlink to the new slot. Subsequent token refreshes flow into the saved slot. |
| `switch`   | Optional      | Replaces `.credentials.json` with a hardlink to `.credentials.<name>.json`. If `<name>` is omitted, rotates to the next saved slot in alphabetical order (wraps around). |
| `list`     | No            | Lists saved slot names |
| `remove`   | Yes           | Deletes a named slot |
| `usage`    | Optional      | Calls Claude Code's **undocumented** `GET /api/oauth/usage` per slot to report 5h / 7d plan-usage percentages. Auto-refreshes expired OAuth tokens in place (hardlink-preserving). Accepts `-Json` and `-NoRefresh` switches. With `<name>`, renders a verbose single-slot block including opus / sonnet / overage buckets. |
| `install`  | No            | Adds wrapper function + aliases to PowerShell profile |
| `uninstall`| No            | Removes wrapper function + aliases from profile |
| `help`     | No            | Shows detailed help |

## Editing the script

The profile install/uninstall uses marker comments (`# === Claude Account Switcher ===`) to isolate its block. When modifying `Add-To-Profile` or `Remove-From-Profile`, keep these markers intact.

The top-level dispatcher is wrapped in `Invoke-Main` and guarded by `if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }` so tests can dot-source the script without triggering a live run. Each action body (`save`, `switch`, `list`, `remove`, `usage`) is extracted into an `Invoke-*Action` function so tests can call it directly. Keep this shape when adding new actions — put the body in `Invoke-<Action>Action` and add a one-line dispatch to `Invoke-Main`.

## Unofficial endpoints (`usage` action)

The `usage` action depends on four pinned constants extracted from `claude.exe` 2.1.119 (a Bun-compiled binary). They live at the top of `switch_claude_account.ps1` under the `# --- Unofficial /api/oauth/usage constants ---` comment:

- `$Script:UsageEndpoint`  — `https://api.anthropic.com/api/oauth/usage`
- `$Script:TokenEndpoint`  — `https://platform.claude.com/v1/oauth/token`
- `$Script:OAuthClientId`  — `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (Claude.ai subscription flow; the other client id in the binary is for the Console API-key flow and does not accept our refresh tokens)
- `$Script:AnthropicBeta`  — `oauth-2025-04-20`
- `$Script:UsageUserAgent` — `claude-code/2.1.119`

These are **undocumented and unsupported by Anthropic** — accepted tradeoff in exchange for live server-authoritative usage data. When the call starts returning 4xx after a Claude Code upgrade, re-extract from `$(Get-Command claude).Source` using the grep recipe in the script header comment, bump the constants, and re-run `tests/Invoke-Tests.ps1`. The tests mock `Invoke-RestMethod` by `$Uri` so they verify the action's *shape contract* and will not catch the constants drifting out of date — only a live call can.

Response schema (verified against a live Team-plan call on 2026-04-24):

```jsonc
// GET /api/oauth/usage → body
{
  "five_hour":            { "utilization": 0..100, "resets_at": "<ISO-8601>"|null },
  "seven_day":            { "utilization": 0..100, "resets_at": "<ISO-8601>"|null },
  "seven_day_opus":       null | { "utilization": ..., "resets_at": ... },
  "seven_day_sonnet":     null | { "utilization": ..., "resets_at": ... },
  "extra_usage": {
    "is_enabled":    <bool>,
    "monthly_limit": <number|null>,
    "used_credits":  <number|null>,
    "utilization":   <number|null>,
    "currency":      <string|null>
  }
  // Plus internal/unreleased buckets that the endpoint exposes but that
  // are null for external subscriptions: seven_day_oauth_apps,
  // seven_day_cowork, seven_day_omelette, iguana_necktie,
  // omelette_promotional. Format-UsageVerbose iterates $Data.PSObject.Properties
  // so any future non-null bucket surfaces with a '? <key>' prefix without
  // code changes.
}
```

All branches are optional; free-tier / API-key accounts receive `{}`. The `-Json` switch emits the raw response under `data` per slot so scripts can pull any field the script itself does not format.

By design the script only **renders** two buckets in both the summary table and the verbose view: `five_hour` (labelled *Session (5h)*) and `seven_day` (labelled *Weekly (all models)*) — matching Claude Code's own `/usage` screen's first two bars. Every other bucket the endpoint returns (`seven_day_opus`, `seven_day_sonnet`, `extra_usage`, and internal codenames) still round-trips through `-Json`; it just does not have a human-readable row in the normal view.

Claude Code separately re-shapes this body into `{ rate_limits: { five_hour: { used_percentage, resets_at } } }` before handing it to its status-line hook — that is the schema you will find by grepping `used_percentage` in `claude.exe`. **Do not** trust the hook-input schema for parsing the raw endpoint response; use the shape above.

`Format-ResetDelta` renders the ISO string as a relative delta in the summary table (variant C: hours+minutes under 24h, integer total hours at/above 24h — e.g. `in 2h 14m`, `in 103h`). `Format-ResetAbsolute` renders it as local-tz wall-clock in the `sca usage <name>` verbose view (`Resets 7:50pm Europe/Berlin`, `Resets Apr 26, 9am Europe/Berlin`), matching Claude Code's own `/usage` display.

### Profile endpoint + filename-encoded email

`Invoke-SaveAction` resolves the OAuth account email at save time via `GET https://api.anthropic.com/api/oauth/profile` (Claude Code's `Ql()` function, same auth token as the usage endpoint). Claude Code's exact header shape is used: `Authorization: Bearer <token>` + `Content-Type: application/json`, 10 s timeout, **no** `anthropic-beta` or `User-Agent`. Matches Ql() verbatim so a future Anthropic header-validation change breaks us no sooner than it breaks Claude Code itself.

Response consumption is minimal — only `account.email` is rendered. The full response carries `account.uuid`, `account.display_name`, `organization.name`, `organization.organization_type`, `organization.rate_limit_tier`, `organization.has_extra_usage_enabled`, `organization.billing_type`, `organization.subscription_created_at`, `organization.cc_onboarding_flags`, `organization.claude_code_trial_ends_at`, and `organization.claude_code_trial_duration_days`; all still round-trip through `sca usage -Json` under the per-slot `.data` key if callers need them.

The resolved email is embedded directly in the slot filename using the RFC 5322 parenthesized-comment form:

- Labeled:       `.credentials.<slot>(<email>).json`
- Unlabeled:     `.credentials.<slot>.json`  (profile fetch failed, or save ran offline)
- Deduplicated:  when `<slot>` (case-insensitive) equals `<email>`, the tool keeps the unlabeled form to avoid visually redundant filenames like `.credentials.alice@example.com(alice@example.com).json`.

The filename is the single source of truth. Because it is written by `sca save` from a fresh profile fetch against the tokens that were *just* stored, the email cannot drift from the tokens — any change to the account requires re-running `sca save`, which re-fetches the profile and renames the file. `sca usage` / `sca list` parse the email straight out of the filename (`Get-SlotFileInfo`) and make zero profile HTTP calls on the display path.

Parse rule (regex, in `Get-SlotFileInfo`):
```
^\.credentials\.(.+?)(?:\(([^()]*@[^()]*)\))?\.json$
    group 1 = slot name (lazy)
    group 2 = email       (optional; only captured when the parens contain '@')
```
The `@`-in-parens requirement keeps a slot named e.g. `work(v2)` parsing as *slot = `work(v2)`, email = none* rather than mis-splitting at the parens. `Get-SafeName` sanitizes `(` and `)` in user-provided slot names to `_`, so user input cannot inject parens into the filename and fool the parser.

Save-time failure modes (all non-fatal; save still produces a usable slot):
- Offline / timeout → unlabeled form; yellow advisory printed.
- 401 / token revoked → unlabeled; advisory printed.
- Response missing `account.email` → unlabeled; advisory printed.
- Any subsequent `sca save <name>` upgrades the file to the labeled form once the profile fetch succeeds.

Synth `<active>` row: `.credentials.json` has no filename-encoded email, so when the hardlink is broken and the synth row is rendered, `Invoke-UsageAction` still makes one live profile call against the active file's token to show which account Claude Code is using. The only display-path HTTP profile call; fires only when a synth row appears.

On-disk migration from the previous cache-based implementation: `Get-Slots` silently removes any leftover `.credentials.*.profile.json` sidecars and the `.credentials.profile.json` file on each enumeration (the cleanup is cheap and idempotent once complete).

Display contract: the `  └─ <email>` second line under a slot row in `sca list` / `sca usage` only appears when the slot's labeled email (case-insensitive) differs from the slot name. Slots saved with the deduplicated form, and unlabeled slots (offline save), render as a single line.

### Synthetic `<active>` row + hardlink warning

When `.credentials.json` exists but is not a hardlink to any saved slot (the state after Claude Code atomically replaces the file during an OAuth refresh), `Invoke-UsageAction`:

1. Queries the active file directly as an extra virtual slot.
2. Labels the resulting row `<active>` if the content hashes to a saved slot (same tokens, broken hardlink) or `<active> (unsaved)` if it matches nothing saved (fresh login).
3. Suppresses the `*` marker on any content-hash-matched saved slot so the marker appears exactly once on the synth row.
4. After the table, emits the same hardlink-broken advisory `Invoke-ListAction` produces, pointing at `sca switch <matched-slot>` (match case) or `sca save <name>` / `sca switch <name>` (unsaved case).

The two synth labels (`<active>` and `<active> (unsaved)`) live in `$Script:ActiveSlotNameMatched` / `$Script:ActiveSlotNameUnsaved` and are the single source of truth. `sca usage <name>` accepts either the full label or the bare string `<active>` as an alias; users need to quote the argument in PowerShell so `<` / `>` are not parsed as redirection operators.

## Testing

Run the suite:

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1
```

The runner auto-installs Pester 5 (CurrentUser scope) on first use. PSScriptAnalyzer, if installed, runs in advisory mode — findings are printed but never fail the run.

Tests sandbox `$env:USERPROFILE` and `$PROFILE.CurrentUserAllHosts` per test via `$TestDrive`, so the real profile and real `.claude` directory are never touched.
