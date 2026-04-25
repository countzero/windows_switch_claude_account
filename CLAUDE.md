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
| `switch`   | Optional      | Replaces `.credentials.json` with a hardlink to `.credentials.<name>.json`. If `<name>` is omitted, rotates to the next saved slot in alphabetical order (wraps around). Output is a yellow header line `[Switch] Switched to '<slot>' (<email>)` (no trailing period — matches the `[List]` / `[Usage]` header style), followed by the saved-slot table (same shape as `sca list`, header suppressed), and a cyan `[Info] Close and restart Claude Code to apply.` hint as the last line. Yellow advisories appear above the success line for the locked-active and no-active-detected edge cases; the single-slot-already-active no-op prints its yellow advisory and skips the success line, the table, and the `[Info]` hint. |
| `list`     | No            | Renders saved slots as a 2-data-column table (`Slot \| Account`) with a leading active-marker column. Mirrors `Format-UsageTable`'s shape and reuses `Format-AccountCell`, so account dedup and middle-truncation are identical across the two views. Pure offline render — no network IO. |
| `remove`   | Yes           | Deletes a named slot |
| `usage`    | Optional      | Calls Claude Code's **undocumented** `GET /api/oauth/usage` per slot to report 5h / 7d plan-usage percentages. Auto-refreshes expired OAuth tokens in place (hardlink-preserving). Accepts `-json` for scripted output, or `-watch` (optional `-interval <seconds>`, floor 60) for a self-refreshing live view. With `<name>`, renders a verbose single-slot block including opus / sonnet / overage buckets. |
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

All branches are optional; free-tier / API-key accounts receive `{}`. The `-json` switch emits the raw response under `data` per slot so scripts can pull any field the script itself does not format.

By design the script only **renders** two buckets in both the summary table and the verbose view: `five_hour` (labelled *Session*) and `seven_day` (labelled *Week*) — matching Claude Code's own `/usage` screen's first two bars. Every other bucket the endpoint returns (`seven_day_opus`, `seven_day_sonnet`, `extra_usage`, and internal codenames) still round-trips through `-json`; it just does not have a human-readable row in the normal view. The labels were originally `Session (5h)` / `Weekly (all models)`; they were shortened to match the table column headers and the aggregate-bar labels (single visual cadence across all three surfaces).

Claude Code separately re-shapes this body into `{ rate_limits: { five_hour: { used_percentage, resets_at } } }` before handing it to its status-line hook — that is the schema you will find by grepping `used_percentage` in `claude.exe`. **Do not** trust the hook-input schema for parsing the raw endpoint response; use the shape above.

`Format-ResetDelta` renders the ISO string as a relative delta in the summary table (variant C: hours+minutes under 24h, integer total hours at/above 24h — e.g. `in 2h 14m`, `in 103h`). `Format-ResetAbsolute` renders it as local-tz wall-clock in the `sca usage <name>` verbose view (`Resets 7:50pm Europe/Berlin`, `Resets Apr 26, 9am Europe/Berlin`), matching Claude Code's own `/usage` display.

### Summary-table layout + Status column semantics

`Format-UsageTable` renders 5 data columns (plus the leading `*` active marker): `Slot | Account | Session | Week | Status`.

- **Merged bucket cells**. `Session` and `Week` each combine utilization and reset delta in a single cell: `100% in 2h 37m`. A cold bucket (`utilization = 0`, `resets_at = null`) renders as just ` 0%` — the em-dash reset sentinel is only emitted when the bucket itself has no data at all. Column widths auto-fit to the widest cell in the batch. Headers were renamed from `5h` / `7d` to match the aggregate-bar labels above the table; status text such as `limited 5h` keeps the time-window shorthand because that string is also a `-json plan_status` contract value.
- **Account column**. Pulls the email parsed from the slot filename by `Get-SlotFileInfo`. Renders `—` for unlabeled slots and for slots whose name equals the labeled email (dedup form). Long emails are middle-truncated with `…` at `$Script:AccountColumnMaxWidth = 32` characters; the full string is always retained in `sca usage <name>` verbose view and in `-json`. Replaces the previous `└─ email` continuation line — rows are now single-line.
- **Status column** mixes HTTP health with plan usability. When the `/api/oauth/usage` call succeeded, `Get-PlanStatus` derives the label from the utilization values:

  | State                                       | Label               | Color |
  |---------------------------------------------|---------------------|-------|
  | Both buckets below `$Script:UtilWarnPct`    | `ok`                | Green if active, Gray otherwise |
  | HTTP ok but response carried no buckets     | `ok (no plan data)` | same as `ok` |
  | Any bucket ≥ `UtilWarnPct` and all < `UtilLimitPct` | `near limit` | Yellow |
  | 5h bucket ≥ `UtilLimitPct`                  | `limited 5h`        | Red |
  | 7d bucket ≥ `UtilLimitPct`                  | `limited 7d`        | Red |
  | Both buckets ≥ `UtilLimitPct`               | `limited`           | Red |
  | HTTP failure states                         | `expired` / `unauthorized` / `error: …` / `no-oauth (api key or non-claude.ai slot)` | Yellow / Red / Red / DarkGray |

  The thresholds are script-scope constants (`$Script:UtilWarnPct = 90`, `$Script:UtilLimitPct = 100`) next to the usage endpoint constants. `100%` is the hard cap Anthropic enforces; `90%` is the heads-up tier. `Get-StatusColor` is the single source of truth for the color mapping so the summary table and verbose view stay in lockstep.

A row flagged `limited 5h` / `limited 7d` / `limited` cannot serve new prompts until the named window resets. This was previously rendered as `ok` in the old HTTP-only Status column, which was misleading — the rewrite is the reason this section exists.

### Aggregate progress bars

Above the summary table, `sca usage` (no slot name) renders two pool-wide AVAILABLE-headroom progress bars — one for `Session` (5h), one for `Week` (7d) — emitted by `Format-AggregateBars` from inside `Format-UsageTable` when the `-IncludeAggregateBars` switch is set. The switch is set by `Format-UsageFrame` for the table view; it is intentionally NOT set by `Format-UsageVerbose`'s non-ok fallback (single-slot drill-down is off-topic for a pool summary).

Layout: a blank line, the Session bar, a blank line, the Week bar, a blank line — then the existing column header. Visual:

```
[Usage] Plan usage per slot

  Session [█████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  48%

  Week    [█████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  64%

     Slot    Account              Session         Week          Status
     ...
```

**Aggregation formula**. For each bucket: `usedTotal = Σ min(util, 100)` over eligible rows (clamped to handle stray >100 utilization values from the API); `cap = N * 100`; `availPct = round((cap - usedTotal) / cap * 100)`. Buckets with `null` / missing utilization contribute `0` used (full headroom).

**Slot-inclusion rule**:
- Status `'ok'` only — HTTP-failure rows have no usable data.
- Synth `<active>` matched (Name equals `$Script:ActiveSlotNameMatched`) is EXCLUDED to avoid double-counting against its hash-paired saved slot.
- Synth `<active> (unsaved)` is INCLUDED — it represents a separate quota pool not yet captured by `sca save`.

**Width**: bar fits to table edge. `barWidth = TotalLineWidth − 17`, floored at 8. The 17 is the per-line fixed overhead: 2 (indent) + 8 (label pad) + `[`+`]` + space + `"NNN%"` (4). `Format-UsageTable` computes `TotalLineWidth` after its column-width loop and passes it to `Format-AggregateBars`. The 8-char floor keeps narrow 1-slot tables visually meaningful — the bar line will be wider than `TotalLineWidth` in that degenerate case but never collapses to `[]`.

**Color** via `Get-AggregateBarColor`:
- `availPct ≥ $Script:AggregateGreenPct` (50) → Green
- `availPct ≥ $Script:AggregateYellowPct` (10) → Yellow
- otherwise → Red

`Get-AggregateBarColor` is a pure helper extracted specifically so the threshold logic is unit-testable without mocking `Write-Host` (Pester's parameter-capture across mock scope boundaries was unreliable in practice).

**Why `Write-Host`, not `Write-Progress`**: (1) `Write-Progress` lives on stream 4, which the suite's `6>&1 | Out-String` capture pattern would miss; (2) it is host-managed and transient — it would not sit inline above the table; (3) it does not compose with the `Clear-Host`-based watch redraw inside `Invoke-UsageWatch`. The bars use the same `Write-Host -ForegroundColor` machinery as every other rendering helper in the file.

When no eligible rows exist (zero saved slots HTTP-ok), `Format-AggregateBars` emits nothing — the post-`[Usage]`-header blank line still separates the header from the column header so the table doesn't stick to the title.

### List table layout (`sca list`)

`Format-ListTable` renders 2 data columns (plus the leading `*` active marker): `Slot | Account`. Mirrors `Format-UsageTable`'s shape so the two views look like siblings — same header style (`[List] Saved slots` in yellow), same active-marker conventions (`*` only, no trailing `(active)` text; the row is colored Green when active), same `Format-AccountCell` truncation (`—` for unlabeled / dedup-form slots, middle-truncated email otherwise).

Pure offline render — no network calls. `Invoke-ListAction` only produces a network call indirectly if the user later re-runs `sca usage`. The hardlink-broken / `ActiveLocked` advisories are printed below the table (matching `Format-UsageFrame`'s ordering: data first, advisories below).

The two table renderers (`Format-UsageTable` and `Format-ListTable`) are kept as siblings rather than factored into a generic helper. With only two callers and different per-cell rules (Status / merged-bucket cells live only on the usage table, the list table has neither), an abstraction would cost more than it saves.

### Switch action output

`Invoke-SwitchAction` emits a yellow header line, the saved-slot table beneath, and a cyan `[Info]` apply hint as the last line, so the user reads "what just happened" at a glance and immediately sees the new active slot in context (via the `*` marker on the just-activated row). The retired rotation banner is gone — the table beneath conveys the transition implicitly.

```
[Switch] Switched to 'slot-1' (ada.lovelace@arpa.net)

    Slot    Account
    ------  ---------------------
  * slot-1  ada.lovelace@arpa.net
    slot-2  ada@arpa.net

[Info] Close and restart Claude Code to apply.
```

- **Success line**: yellow header, matches the `[List] Saved slots` / `[Usage] Plan usage per slot` convention so all three actions present a consistent table-header look. Intentionally emitted with no trailing period — it is a header, not a sentence (same style as `[List] Saved slots`).
- **Table beneath**: rendered via `Format-ListTable -Slots <fresh-slots> -SuppressHeader`. The slot list is re-enumerated post-switch (one extra `Get-Slots` call) so the `*` marker reflects the just-completed hardlink swap. `-SuppressHeader` skips the `[List] Saved slots` yellow header so the table sits cleanly under the `[Switch]` line. The hardlink-broken / `ActiveLocked` advisories that `Invoke-ListAction` emits cannot fire here (the hardlink was just established by `New-Item -ItemType HardLink`).
- **`[Info]` apply hint**: cyan, last line beneath the table. Carries the "Close and restart Claude Code to apply." reminder split out of the success line so the success line stays scannable as a header. Suppressed for the single-slot no-op (nothing changed, nothing to apply).
- **Yellow advisory branches** (printed above the success line):
  - **Locked active credentials file** (rotation only): `[Switch] Active credentials file is locked; cannot identify current slot. Rotating to <ident>.` Rotation still proceeds; the success line, table, and `[Info]` hint follow as usual.
  - **No active match** (rotation only, hash of `.credentials.json` matches no saved slot): `[Switch] No currently active slot detected. Rotating to <ident>.` Rotation still proceeds; the success line, table, and `[Info]` hint follow as usual.
  - **Single-slot-already-active no-op** (rotation only): `[Switch] Only one slot (<ident>) and it is already active. Nothing to do.` Skips the success line, the table, AND the `[Info]` hint — nothing changed, no point re-rendering the unchanged state and no apply needed. Emitted by `Get-NextSlotName` itself, which then returns `$null` so the caller exits early.

Slot identities are rendered via `Format-SlotIdentity`, the single source of truth for the dedup logic: returns `'<slot>' (<email>)` for labeled slots whose email differs from the slot name, and `'<slot>'` (no parens) for unlabeled or dedup-form slots. Same dedup rules as `Format-AccountCell` so the inline prose form and the table cell form stay consistent.

`Get-NextSlotName`'s return shape: `{ To = { Name; Email }; HasActiveMatch = <bool>; Locked = <bool> }` (or `$null` for the single-slot no-op). `HasActiveMatch` differentiates the happy path (no advisory) from the no-active-match advisory branch; `Locked` is true only when the active credentials file existed but could not be hashed. The previous `From` field was dropped when the rotation banner was retired — no caller renders it any more.

### Verbose view (`sca usage <slot>`)

`Format-UsageVerbose` renders a single slot as a 4-line block:

```
[Usage] Slot 'slot-1'
  Account: ada@arpa.net
  Status:  limited 5h - no prompts until 5h window resets
  Session    100%  Resets 7:50pm Europe/Berlin
  Week        28%  Resets Apr 26, 9am Europe/Berlin
```

The `Status:` line sits between `Account:` and the bucket rows so the usability verdict is the first thing read. `Get-StatusRationale` supplies a short English tail for the non-obvious labels (`limited 5h`, `limited 7d`, `limited`, `near limit`, `ok (no plan data)`); plain `ok` renders without a tail.

### `-json` output

Each per-slot entry carries the same fields as before plus a `plan_status` string when the HTTP call succeeded:

```jsonc
{
  "slot-1": {
    "status":      "ok",
    "is_active":   false,
    "plan_status": "limited 5h",          // absent for HTTP-failure rows
    "account":     { "email": "ada@arpa.net" },
    "data":        { /* raw /api/oauth/usage body */ }
  }
}
```

`plan_status` values match the Status column labels verbatim so scripts can branch on usability without re-deriving the thresholds. The full untruncated email always lives in `account.email`, regardless of the summary table's truncation width.

### Watch mode (`sca usage -watch`)

`Invoke-UsageWatch` provides a self-refreshing live view of the usage table or verbose view. It re-polls the endpoint every `-interval` seconds (default **60 s**, floor **60 s**) and redraws the frame once per second so reset deltas (`in 2h 37m`) and the countdown footer tick visibly between polls.

Design split driven by the watch loop:

- **`Get-UsageSnapshot`** is the pure data-gathering function: enumerates slots, calls `Get-SlotUsage` (and `Get-SlotProfile` for the synth row), and returns `{ Results, HardlinkBroken, MatchedSlotName, NoSlots, HasSynthRow }`. Never renders. The one-shot path and the watch loop both call it.
- **`Format-UsageFrame`** is the pure renderer: takes a snapshot plus an optional footer string and prints table-or-verbose + optional hardlink advisory + footer. Used identically from both entry points, so the frame shape is asserted by the suite and the watch loop automatically inherits every rendering guarantee.
- **`Invoke-UsageWatch`** is the loop itself. Untested — its behavior is `Clear-Host` + `Format-UsageFrame` on a 1-second `Start-Sleep` tick. No keyboard input handling: Ctrl-C terminates via the runtime's default handler, and the `finally` block restores `[Console]::CursorVisible`.

Runtime guards (both throw, neither runs the loop):

- `-watch -json` — mutually exclusive; `-watch` is interactive, `-json` is for scripting.
- `[Console]::IsOutputRedirected` — `sca usage -watch > file.txt` is refused rather than silently filling the file with `Clear-Host`-shredded frames; the error message points at `-json`.

Interval clamping: values below `$Script:UsageWatchMinInterval = 60` get clamped up to 60 with a one-line yellow advisory. The floor matches the default so `-interval` can only *slow* the poll — this is deliberate, the unofficial endpoint has no published rate limit and we prefer conservative cadence.

Exit: Ctrl-C only. The loop installs no key listeners (no `[Console]::KeyAvailable` / `ReadKey`); the runtime's default Ctrl-C handler terminates the pipeline and PowerShell runs the `finally` block, which restores `[Console]::CursorVisible` to its pre-loop value. There is no interactive force-refresh — to bypass the poll interval, quit and re-run.

Error handling: if an HTTP call fails mid-loop, the previous snapshot stays on screen and a second line appears under the footer reading `[Watch] Last poll failed: <msg> (keeping previous data; will retry on next tick)`. The hardlink-broken advisory is suppressed on redraws between polls (only shown on freshly-polled frames) so the warning does not flash every second.

### Profile endpoint + filename-encoded email

`Invoke-SaveAction` resolves the OAuth account email at save time via `GET https://api.anthropic.com/api/oauth/profile` (Claude Code's `Ql()` function, same auth token as the usage endpoint). Claude Code's exact header shape is used: `Authorization: Bearer <token>` + `Content-Type: application/json`, 10 s timeout, **no** `anthropic-beta` or `User-Agent`. Matches Ql() verbatim so a future Anthropic header-validation change breaks us no sooner than it breaks Claude Code itself.

Response consumption is minimal — only `account.email` is rendered. The full response carries `account.uuid`, `account.display_name`, `organization.name`, `organization.organization_type`, `organization.rate_limit_tier`, `organization.has_extra_usage_enabled`, `organization.billing_type`, `organization.subscription_created_at`, `organization.cc_onboarding_flags`, `organization.claude_code_trial_ends_at`, and `organization.claude_code_trial_duration_days`; all still round-trip through `sca usage -json` under the per-slot `.data` key if callers need them.

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

Display contract: both `sca list` and `sca usage` render emails inline in the `Account` column on the same row as the slot name — there is no longer a `└─ <email>` continuation line anywhere. `Format-AccountCell` is the single source of truth for the dedup logic: it returns `—` when the slot is unlabeled (offline save) or when the slot name (case-insensitive) equals its embedded email, and the middle-truncated email otherwise. The full untruncated email always lives in `sca usage <name>` verbose output and in `sca usage -json`.

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

Run a single test or context by name (`-FullNameFilter` is a wildcard/regex against the full `Describe > Context > It` path):

```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ -FullNameFilter '*Get-SafeName*' -Output Detailed"
```

The runner auto-installs Pester 5 (CurrentUser scope) on first use. PSScriptAnalyzer, if installed, runs in advisory mode — findings are printed but never fail the run.

Tests sandbox `$env:USERPROFILE` and `$PROFILE.CurrentUserAllHosts` per test via `$TestDrive`, so the real profile and real `.claude` directory are never touched.

Tests are split per action under `tests/Invoke-<Action>Action.Tests.ps1` (plus `Helpers.Tests.ps1` and `Profile-Install.Tests.ps1`), with shared per-test sandbox setup in `tests/Common.ps1` (dot-sourced from each file's `BeforeEach`). Each file's outer `Describe` is named `'switch_claude_account'` so the `-FullNameFilter` recipe above keeps working unchanged across files.
