# CLAUDE.md

## Repo structure

Single-file PowerShell tool — core logic lives in `switch_claude_account.ps1`. Tests live in `tests/` and use Pester 5.

## Key facts

- **Credential directory**: `%USERPROFILE%\.claude\`
- **Active credentials**: `.credentials.json` — written by Claude Code via atomic rename on every OAuth refresh. `sca` writes it via the same atomic-rename primitive (`Set-CredentialFileAtomic`) so the file is byte-equal to the tracked slot file after every `sca save` / `sca switch` / reconcile pass. **No hardlinks are involved** (the previous design's hardlink approach was structurally broken by Claude Code's atomic-rename refreshes; replaced in v2.0.0 with state-file tracking).
- **State file**: `%USERPROFILE%\.claude\.sca-state.json` — schema v1: `{ schema, active_slot, last_sync_hash }`. Single source of truth for "which slot is active." Read with `Read-ScaState` (auto-migrates from a 1.x install on first read by hashing `.credentials.json` against existing slot files); written via `Update-ScaState`.
- **Named slots**: `.credentials.<name>(<email>).json` (labeled) or `.credentials.<name>.json` (unlabeled).
- **PS version**: Requires PowerShell 7.0+ (`#Requires -Version 7.0`). Uses `$PROFILE.CurrentUserAllHosts` for the install target.
- **Alias installer**: `sca` and `switch-claude-account` added to PowerShell profile via marker-delimited block

## Windows-specific gotchas

- **Atomic-rename writes survive an open Claude Code**. `Set-CredentialFileAtomic` calls `[System.IO.File]::Replace` / `::Move`, both of which invoke `MoveFileEx` and succeed against the FILE_SHARE_DELETE handle Claude Code keeps on `.credentials.json` while running. So `sca save` / `sca switch` no longer require closing Claude Code first. The retry policy is 3 attempts with 50 ms backoff to absorb transient sharing violations from antivirus / indexer scanners. Note: a running Claude Code session may keep using its in-memory tokens until restarted — the file swap is instant, but the process state isn't. The `[Info]` line on `switch` says so.
- **Execution policy**: May need `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` on first run.
- **Token expiry**: OAuth tokens refresh / expire after ~1 hour of inactivity. Without daemon the slot file is at most one Claude-Code-refresh behind the active file at any moment; the next `sca usage` or `sca switch` invocation captures the refresh into the slot via `Invoke-Reconcile`. "One refresh behind" is harmless in OAuth terms — the slot's previous refresh_token is still valid until rotated again, which Claude Code will do on its next API call. `Update-SlotTokens` (called by `sca usage` when the active slot's access token is expired) explicitly propagates the new tokens to BOTH the slot file AND `.credentials.json` so Claude Code's next call sees the latest refresh_token.
- **Reconcile fires on usage and switch only** — not on `list` (kept as a pure offline render) or `remove`. The auto-migration path inside `Read-ScaState` handles upgrades from 1.x silently; users who have not yet reconciled see a stale `last_sync_hash` until their first `sca usage`.
- **Cross-account swap detection**: when reconcile sees `.credentials.json` bytes differ from `state.last_sync_hash`, it makes one HTTP call to `/api/oauth/profile` to identify the new email. If the email matches the tracked slot's filename email, mirror through; if it differs, refuse to overwrite and auto-save under `auto-<UTC-timestamp>(<new-email>)` instead. Profile-fetch failure (offline / 401 / no-oauth) tolerantly falls into the mirror branch — preserving continuity over paranoia.
- **Name sanitization**: Invalid Windows filename characters (`\ / : * ? " < > |` and control chars), PowerShell wildcard brackets (`[` `]`), and spaces are replaced with `_`. Brackets are sanitized because PowerShell's `-Path` parameter treats them as character-class wildcards; without sanitization, `sca remove foo[bar]` would silently wildcard-match unrelated slot files. Paired with `-LiteralPath` on every credential-file op as defense-in-depth.

## Script actions

| Action     | Requires name | What it does |
|------------|---------------|--------------|
| `save`     | Yes           | Atomic-writes `.credentials.json` bytes into `.credentials.<name>(<email>).json` (email resolved via `/api/oauth/profile`; falls back to unlabeled if offline). Updates `state.active_slot` and `state.last_sync_hash`. No reconcile prelude — explicit save IS the capture. |
| `switch`   | Optional      | Reconciles first (so a pending Claude Code refresh on the outgoing slot is captured), then atomic-writes the target slot's bytes into `.credentials.json` and updates state. If `<name>` is omitted, rotates to the next saved slot in alphabetical order (wraps around). Output is a DarkYellow header line `[Switch] Switched to '<slot>' (<email>)`, the saved-slot table beneath, and a cyan `[Info] Restart Claude Code to fully apply the swap (running sessions may continue using the previous credentials until restarted).` Yellow advisory above the success line for the no-active-slot rotation edge case; single-slot-already-active no-op prints its advisory and skips the success line, table, and `[Info]` hint. |
| `list`     | No            | Renders saved slots as a 2-data-column table (`Slot \| Account`) with a leading active-marker column. Mirrors `Format-UsageTable`'s shape. Pure offline render — no network IO, no reconcile, no hashing. `*` marker comes from `state.active_slot`. |
| `remove`   | Yes           | Deletes a named slot. Refuses to remove the slot tracked as active in state — user must `sca switch <other>` first. |
| `usage`    | Optional      | Reconciles first, then calls Claude Code's **undocumented** `GET /api/oauth/usage` per slot to report 5h / 7d plan-usage percentages. Auto-refreshes expired OAuth tokens via `Update-SlotTokens`, which propagates the new tokens to `.credentials.json` when the slot is the tracked active. Accepts `-json` for scripted output, or `-watch` (optional `-interval <seconds>`, floor 60) for a self-refreshing live view. With `<name>`, renders a verbose single-slot block. |
| `install`  | No            | Adds wrapper function + aliases to PowerShell profile |
| `uninstall`| No            | Removes wrapper function + aliases from profile |
| `help`     | No            | Shows detailed help |

## Editing the script

The profile install/uninstall uses marker comments (`# === Claude Account Switcher ===`) to isolate its block. When modifying `Add-To-Profile` or `Remove-From-Profile`, keep these markers intact.

The top-level dispatcher is wrapped in `Invoke-Main` and guarded by `if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }` so tests can dot-source the script without triggering a live run. Each action body (`save`, `switch`, `list`, `remove`, `usage`) is extracted into an `Invoke-*Action` function so tests can call it directly. Keep this shape when adding new actions — put the body in `Invoke-<Action>Action` and add a one-line dispatch to `Invoke-Main`.

The two credentials-touching actions that need a fresh slot file (`switch`, `usage`) call `Invoke-Reconcile` first; `save` skips reconcile (the explicit save IS the capture); `list` and `remove` skip reconcile too (`list` is a pure offline render; `remove` doesn't read slot bytes). New actions should follow the same rule: reconcile only when the slot file's bytes feed downstream logic.

### Color conventions

- **DarkYellow** is reserved for **section-title headers**: `[Usage] Plan usage`, `[Usage] Slot '<name>'`, `[List] Saved slots`, and `[Switch] Switched to <ident>`. These are the four lines that introduce a block of data (a table or a verbose detail view).
- **Yellow** is reserved for **advisories / warnings**: rate-limit notices, reconcile auto-save / identity-change advisories, no-active-slot rotation branch, save-time profile-fetch failures, `-interval` clamping, etc. Anything yellow means "attention required", never "this is a header".
- **Green** marks success on actions that just produced a useful side effect (`[Save] Saved …`, `[Install] Installed!`).
- **Red** marks completion of destructive actions (`[Remove] Removed …`, `[Uninstall] Uninstalled.`).
- **Cyan** marks information hints, currently just the `[Info] Restart Claude Code …` line under the `switch` action's table.
- **DarkGray** is for dimmed metadata (account row in the verbose view, "no plan-usage data" fallback, watch-mode footer).

The DarkYellow choice tracks the warm amber `#ffcb6b` used for `warning` / `info` in OpenCode's material theme. PowerShell's `Write-Host -ForegroundColor` is restricted to the 16-value `ConsoleColor` enum and cannot hit truecolor; `DarkYellow` renders as warm amber/mustard in modern terminals (Windows Terminal Campbell ≈`#C19C00`, VS Code, Alacritty) and is the closest hue match within the palette. The split also restores a visual distinction between header and warning, which both used to be plain `Yellow`.

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

`Format-ResetDelta` renders the ISO string as a relative delta in the summary table (variant C: hours+minutes under 24h, integer total hours at/above 24h — e.g. `(2h 14m)`, `(103h)`). `Format-ResetAbsolute` renders it as local-tz wall-clock in the `sca usage <name>` verbose view (`Resets 7:50pm Europe/Berlin`, `Resets Apr 26, 9am Europe/Berlin`), matching Claude Code's own `/usage` display.

### Summary-table layout + Status column semantics

`Format-UsageTable` renders 5 data columns (plus the leading `*` active marker): `Slot | Account | Session | Week | Status`.

- **Merged bucket cells**. `Session` and `Week` each combine utilization and reset delta in a single cell: `100% (2h 37m)`. A cold bucket (`utilization = 0`, `resets_at = null`) renders as just ` 0%` — the em-dash reset sentinel is only emitted when the bucket itself has no data at all. Column widths auto-fit to the widest cell in the batch. Headers were renamed from `5h` / `7d` to match the aggregate-bar labels above the table; status text such as `limited 5h` keeps the time-window shorthand because that string is also a `-json plan_status` contract value.
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
  | HTTP 429 (token refresh OR usage endpoint), no fresh cache | `rate-limited` | Yellow |
  | HTTP failure states                         | `expired` / `unauthorized` / `error: …` / `no-oauth (api key or non-claude.ai slot)` | Yellow / Red / Red / DarkGray |

  The thresholds are script-scope constants (`$Script:UtilWarnPct = 90`, `$Script:UtilLimitPct = 100`) next to the usage endpoint constants. `100%` is the hard cap Anthropic enforces; `90%` is the heads-up tier. `Get-StatusColor` is the single source of truth for the color mapping so the summary table and verbose view stay in lockstep.

A row flagged `limited 5h` / `limited 7d` / `limited` cannot serve new prompts until the named window resets. This was previously rendered as `ok` in the old HTTP-only Status column, which was misleading — the rewrite is the reason this section exists.

**429 / `rate-limited` handling**: a 429 from either `/api/oauth/usage` or `/v1/oauth/token` (the latter triggered by `Get-SlotUsage`'s pre-call refresh of an expired token) is detected by the `Test-Is429` helper and routed through the same fallback policy: serve fresh cached usage data when `$Script:SlotUsageCache` has a `<UsageCacheTTL = 10`-minute entry for the slot, otherwise return `Status='rate-limited'`. The advisory text under the table reads `Anthropic API rate limited — displaying cached data.` — endpoint-agnostic, since either call may have triggered it. Long error messages on the `'expired'` and `'error'` arms are normalized through `Format-StatusErrorTail` (whitespace collapse + 60-char cap) so a verbose underlying exception cannot wrap the row. Without this normalization, a 429 from the token endpoint used to render as a multi-line `expired: Response status code does not indicate success: 429 (Too Many Requests).` and break the table layout.

### Aggregate progress bars

Above the summary table, `sca usage` (no slot name) renders two pool-wide USAGE progress bars — one for `Session` (5h), one for `Week` (7d) — emitted by `Format-AggregateBars` from inside `Format-UsageTable` when the `-IncludeAggregateBars` switch is set. The switch is set by `Format-UsageFrame` for the table view; it is intentionally NOT set by `Format-UsageVerbose`'s non-ok fallback (single-slot drill-down is off-topic for a pool summary).

Layout: a blank line, the Session bar, a blank line, the Week bar, a blank line — then the existing column header. Filled portion = used; empty portion = remaining headroom. Standard progress-bar convention, matching the per-slot `Session` / `Week` table cells beneath which already display utilization. Visual:

```
[Usage] Plan usage

  Session [█████████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░]  52%

  Week    [████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  36%

     Slot    Account              Session         Week          Status
     ...
```

**Aggregation formula**. For each bucket: `usedTotal = Σ min(util, 100)` over eligible rows (per-row clamp to handle stray >100 utilization values from the API); `cap = N * 100`; `usedPct = round(usedTotal / cap * 100)` (equivalently the mean utilization across eligible rows). Buckets with `null` / missing utilization contribute `0` used. `usedTotal` is in `[0, cap]` by construction, so no outer clamp is needed before the rounding step.

**Slot-inclusion rule**:
- Status `'ok'` only — HTTP-failure rows have no usable data.
- Buckets with `null` / missing utilization counted as 0% used.

After the v2.0.0 redesign there are no synth rows in the data model, so no slot-name special cases are needed.

**Width**: bar fits to table edge. `barWidth = TotalLineWidth − 17`, floored at 8. The 17 is the per-line fixed overhead: 2 (indent) + 8 (label pad) + `[`+`]` + space + `"NNN%"` (4). `Format-UsageTable` computes `TotalLineWidth` after its column-width loop and passes it to `Format-AggregateBars`. The 8-char floor keeps narrow 1-slot tables visually meaningful — the bar line will be wider than `TotalLineWidth` in that degenerate case but never collapses to `[]`.

**Color** via `Get-AggregateBarColor`:
- `usedPct ≥ $Script:AggregateRedPct` (90) → Red
- `usedPct ≥ $Script:AggregateYellowPct` (50) → Yellow
- otherwise → Green

`AggregateRedPct` is anchored to `UtilWarnPct` (90) so "red" carries the same near-cap meaning at per-slot and pool scale; pure `100` would be a knife-edge transition that fires only after the pool is already exhausted. `AggregateYellowPct = 50` is the half-burned mark. There is no `AggregateGreenPct` — the "else" branch is Green by definition; three constants for two thresholds would be one too many.

`Get-AggregateBarColor` is a pure helper extracted specifically so the threshold logic is unit-testable without mocking `Write-Host` (Pester's parameter-capture across mock scope boundaries was unreliable in practice).

**Why `Write-Host`, not `Write-Progress`**: (1) `Write-Progress` lives on stream 4, which the suite's `6>&1 | Out-String` capture pattern would miss; (2) it is host-managed and transient — it would not sit inline above the table; (3) it does not compose with the synchronized-output watch redraw inside `Invoke-UsageWatch` (the loop wraps each frame in DEC mode 2026 + `ESC[2J` so every `Write-Host` line lands inside one atomic frame; `Write-Progress` writes outside that envelope and would tear). The bars use the same `Write-Host -ForegroundColor` machinery as every other rendering helper in the file.

When no eligible rows exist (zero saved slots HTTP-ok), `Format-AggregateBars` emits nothing — the post-`[Usage]`-header blank line still separates the header from the column header so the table doesn't stick to the title.

### List table layout (`sca list`)

`Format-ListTable` renders 2 data columns (plus the leading `*` active marker): `Slot | Account`. Mirrors `Format-UsageTable`'s shape so the two views look like siblings — same header style (`[List] Saved slots` in DarkYellow), same active-marker conventions (`*` only, no trailing `(active)` text; the row is colored Green when active), same `Format-AccountCell` truncation (`—` for unlabeled / dedup-form slots, middle-truncated email otherwise).

Pure offline render — no network calls, no reconcile, no hashing. `Invoke-ListAction` reads `state.active_slot` (via `Get-Slots` -> `Read-ScaState`) for the `*` marker and renders. The hardlink-broken / `ActiveLocked` advisories were deleted with the rest of the hardlink mechanism in v2.0.0; pending-state cases the old advisories warned about are now handled silently by reconcile next time the user runs `sca usage` or `sca switch`.

The two table renderers (`Format-UsageTable` and `Format-ListTable`) are kept as siblings rather than factored into a generic helper. With only two callers and different per-cell rules (Status / merged-bucket cells live only on the usage table, the list table has neither), an abstraction would cost more than it saves.

### Switch action output

`Invoke-SwitchAction` runs `Invoke-Reconcile` first (so a pending Claude Code refresh on the outgoing active slot is captured into its slot file before we overwrite `.credentials.json`), then atomic-writes the destination slot's bytes to `.credentials.json`, then prints a DarkYellow header line, the saved-slot table beneath, and a cyan `[Info]` apply hint as the last line.

```
[Switch] Switched to 'slot-1' (ada.lovelace@arpa.net)

    Slot    Account
    ------  ---------------------
  * slot-1  ada.lovelace@arpa.net
    slot-2  ada@arpa.net

[Info] Restart Claude Code to fully apply the swap (running sessions may continue using the previous credentials until restarted).
```

- **Success line**: DarkYellow header, matches the `[List] Saved slots` / `[Usage] Plan usage` convention so all three actions present a consistent table-header look. Intentionally emitted with no trailing period — it is a header, not a sentence.
- **Table beneath**: rendered via `Format-ListTable -Slots <fresh-slots> -SuppressHeader`. The slot list is re-enumerated post-switch (one extra `Get-Slots` call) so the `*` marker reflects the just-updated `state.active_slot`. `-SuppressHeader` skips the `[List] Saved slots` DarkYellow header so the table sits cleanly under the `[Switch]` line.
- **`[Info]` apply hint**: cyan, last line beneath the table. Wording softened from the previous "Close and restart Claude Code to apply." to reflect that atomic-rename writes work even while Claude Code is open — the file is swapped now, but a running Claude Code session keeps using its in-memory tokens until restarted. Suppressed for the single-slot no-op (nothing changed, nothing to apply).
- **Yellow advisory branches** (printed above the success line):
  - **Reconcile advisories** (auto-save or identity-change): emitted by `Invoke-Reconcile` itself before the switch's own output. The user sees the unusual state explained before the success line.
  - **No active slot detected** (rotation only): `[Switch] No currently active slot detected. Rotating to <ident>.` Fires when `state.active_slot` is null or points at a missing slot file. Rotation still proceeds; the success line, table, and `[Info]` hint follow as usual.
  - **Single-slot-already-active no-op** (rotation only): `[Switch] Only one slot (<ident>) and it is already active. Nothing to do.` Skips the success line, the table, AND the `[Info]` hint — nothing changed, no point re-rendering the unchanged state and no apply needed. Emitted by `Get-NextSlotName` itself, which then returns `$null` so the caller exits early.

Slot identities are rendered via `Format-SlotIdentity`, the single source of truth for the dedup logic: returns `'<slot>' (<email>)` for labeled slots whose email differs from the slot name, and `'<slot>'` (no parens) for unlabeled or dedup-form slots. Same dedup rules as `Format-AccountCell` so the inline prose form and the table cell form stay consistent.

`Get-NextSlotName`'s return shape: `{ To = { Name; Email }; HasActiveSlot = <bool> }` (or `$null` for the single-slot no-op). `HasActiveSlot` differentiates the happy path (no advisory) from the no-active-slot advisory branch. The `Locked` field was deleted with the rest of the hardlink mechanism — `Get-Slots` no longer hashes the active file, so there's no lock to detect.

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
    "status":             "ok",
    "is_active":          false,
    "plan_status":        "limited 5h",   // absent for HTTP-failure rows
    "is_cached_fallback": true,           // present (and true) only when the row was served from $Script:SlotUsageCache after a 429; absent otherwise
    "account":            { "email": "ada@arpa.net" },
    "data":               { /* raw /api/oauth/usage body */ }
  }
}
```

`plan_status` values match the Status column labels verbatim so scripts can branch on usability without re-deriving the thresholds. The full untruncated email always lives in `account.email`, regardless of the summary table's truncation width. `is_cached_fallback` is the JSON-side signal of the same condition the `Anthropic API rate limited — displaying cached data.` advisory surfaces in the human view; absence means the data was fetched live for this run.

### Watch mode (`sca usage -watch`)

`Invoke-UsageWatch` provides a self-refreshing live view of the usage table or verbose view. It re-polls the endpoint every `-interval` seconds (default **60 s**, floor **60 s**) and redraws the frame once per second so reset deltas (`(2h 37m)`) and the countdown footer tick visibly between polls.

**Flicker-free rendering.** The loop enters the alternate screen buffer (`ESC[?1049h`) and hides the cursor (`ESC[?25l`) on entry; the `finally` block restores both on Ctrl-C. Each frame is wrapped in DEC mode 2026 (synchronized output: `ESC[?2026h` … `ESC[?2026l`) with `ESC[2J` + cursor-home (`ESC[H`) at the start, then the existing `Format-UsageFrame` renderer is called unchanged. Inside the sync envelope the terminal buffers the clear-and-redraw and presents one atomic frame, so the user never sees the intermediate "blank screen" frame that the prior `Clear-Host` produced. Terminals that support DEC 2026 (Windows Terminal ≥ v1.13, VS Code, iTerm2 ≥ 3.4.13, kitty, alacritty, WezTerm, foot, gnome-terminal/vte, mintty, modern ConHost) render flicker-free; older terminals silently ignore the unknown DEC private mode and exhibit the previous `Clear-Host`-style flicker (no regression). Renderer functions (`Format-UsageFrame`, `Format-UsageTable`, `Format-AggregateBars`, `Format-UsageVerbose`, `Format-UsageFooter`) are untouched — only `Invoke-UsageWatch` emits the wrapper sequences, so the one-shot `sca usage` / `sca list` / `sca switch` paths are unaffected.

Design split driven by the watch loop:

- **`Get-UsageSnapshot`** is the pure data-gathering function: enumerates slots, calls `Get-SlotUsage` per slot, and returns `{ Results, NoSlots, HasCacheFallback }`. Never renders. The one-shot path and the watch loop both call it. Reconcile runs once per poll boundary (in `Invoke-UsageAction` for the one-shot path, inside the watch loop's `$dueForPoll` branch) so by the time `Get-UsageSnapshot` reads slot files they are byte-equal to whatever Claude Code last wrote into `.credentials.json`.
- **`Format-UsageFrame`** is the pure renderer: takes a snapshot plus an optional footer string and prints table-or-verbose + optional cache-fallback advisory + footer. Used identically from both entry points, so the frame shape is asserted by the suite and the watch loop automatically inherits every rendering guarantee.
- **`Invoke-UsageWatch`** is the loop itself. Untested — its behavior is the alt-buffer + sync-mode wrapper described above around a `Format-UsageFrame` call on a 1-second `Start-Sleep` tick. No keyboard input handling: Ctrl-C terminates via the runtime's default handler, and the `finally` block emits `ESC[?25h` + `ESC[?1049l` (show cursor + leave alt buffer) and restores `[Console]::CursorVisible` to its pre-loop value.

Runtime guards (both throw, neither runs the loop):

- `-watch -json` — mutually exclusive; `-watch` is interactive, `-json` is for scripting.
- `[Console]::IsOutputRedirected` — `sca usage -watch > file.txt` is refused rather than silently filling the file with alt-buffer / cursor-control / sync-mode escape sequences; the error message points at `-json`.

Interval clamping: values below `$Script:UsageWatchMinInterval = 60` get clamped up to 60 with a one-line yellow advisory. The floor matches the default so `-interval` can only *slow* the poll — this is deliberate, the unofficial endpoint has no published rate limit and we prefer conservative cadence.

Exit: Ctrl-C only. The loop installs no key listeners (no `[Console]::KeyAvailable` / `ReadKey`); the runtime's default Ctrl-C handler terminates the pipeline and PowerShell runs the `finally` block, which leaves the alternate screen buffer (so the user's pre-watch terminal scrollback is restored, mirroring `top` / `htop` / `vim`) and restores cursor visibility. There is no interactive force-refresh — to bypass the poll interval, quit and re-run.

Error handling: if an HTTP call fails mid-loop, the previous snapshot stays on screen and a second line appears under the footer reading `[Watch] Last poll failed: <msg> (keeping previous data; will retry on next tick)`.

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

Reconcile's identity safeguard makes one extra `Get-SlotProfile` call per `sca usage` / `sca switch` invocation when `.credentials.json` bytes differ from `state.last_sync_hash`. The call is the only profile-endpoint hit on the display path; it returns the email of the freshly-written tokens so reconcile can compare against the tracked slot's filename email and either mirror through (same identity) or auto-save (cross-account swap). Profile-fetch failure (offline / 401 / no-oauth) is tolerated — it falls into the same-identity mirror branch, preferring continuity over paranoia.

On-disk migration from the previous cache-based implementation: `Get-Slots` silently removes any leftover `.credentials.*.profile.json` sidecars and the `.credentials.profile.json` file on each enumeration (the cleanup is cheap and idempotent once complete).

Display contract: both `sca list` and `sca usage` render emails inline in the `Account` column on the same row as the slot name — there is no longer a `└─ <email>` continuation line anywhere. `Format-AccountCell` is the single source of truth for the dedup logic: it returns `—` when the slot is unlabeled (offline save) or when the slot name (case-insensitive) equals its embedded email, and the middle-truncated email otherwise. The full untruncated email always lives in `sca usage <name>` verbose output and in `sca usage -json`.

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
