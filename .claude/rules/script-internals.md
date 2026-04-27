---
paths:
  - "switch_claude_account.ps1"
---

# Script internals

Deep-dive details for `switch_claude_account.ps1`. Loads only when editing the script.

## Color rendering

Two cooperating pieces — both required for `-NoColor` / `$env:NO_COLOR` to actually strip color, AND for watch-mode color to render at all:

1. **`Write-Color` helper** (defined just above `Get-SafeName`). Single chokepoint for every colored call site in the script — no remaining `Write-Host -ForegroundColor` in production paths. Wraps the message string with inline ANSI SGR codes from `$PSStyle.Foreground.*` plus `$PSStyle.Reset`, then calls `Write-Host`.
2. **`$PSStyle.OutputRendering = 'PlainText'` toggle in `Invoke-Main`**, gated by precedence below, wrapped in `try/finally` to restore on exit. With SGR inline in the byte stream, PowerShell's `GetOutputString(value, supportsVT)` strips the codes when `OutputRendering = 'PlainText'`.

**Why the helper, not `-ForegroundColor`**: on Windows, `Write-Host -ForegroundColor` calls Win32 `SetConsoleTextAttribute` — an out-of-band kernel RPC into conhost, invisible to `$PSStyle.OutputRendering`. SGR-in-byte-stream solves both no-color stripping AND watch-mode B&W (the latter because conhost's per-cell attribute state doesn't align with the buffered byte stream inside the DEC 2026 sync envelope; SGR bytes flow through `Console.Out.Write` and sit inside the envelope correctly).

**Color name translation**: PS legacy `ConsoleColor` and PS7's `$PSStyle.Foreground` use opposite conventions (legacy `Dark*` = ANSI 30-37; legacy un-prefixed = ANSI bright 90-97). Our `DarkYellow` headers map to `$PSStyle.Foreground.Yellow`; `Yellow` advisories map to `$PSStyle.Foreground.BrightYellow`.

**No-color precedence** (most → least specific): `-NoColor` switch → `$env:NO_COLOR` non-empty → colored (default). Structural text, `*` active marker, table layout, header underlines, bar glyphs (`█`/`▓`) preserved unchanged in no-color mode — only SGR codes are skipped. `FORCE_COLOR` intentionally unsupported (`Write-Host` writes to stream 6, not stdout, so piping doesn't capture color anyway).

The `try/finally` scope is per-`Invoke-Main`, NOT global. Tests dot-source the script and call `Invoke-*Action` directly, bypassing `Invoke-Main`; `tests/Common.ps1` sets `$PSStyle.OutputRendering = 'PlainText'` once per `BeforeEach`.

## Color palette

- **DarkYellow** — section-title headers (`[Usage] Plan usage`, `[Usage] Slot '<name>'`, `[List] Saved slots`, `[Switch] Switched to <ident>`).
- **Yellow** — advisories / warnings (rate-limit, reconcile auto-save, no-active-slot rotation, profile-fetch failure, `-Interval` clamping). "Attention required", never a header.
- **Green** — success on side-effect actions (`[Save] Saved …`, `[Install] Installed!`).
- **Red** — destructive completion (`[Remove] Removed …`, `[Uninstall] Uninstalled.`).
- **Cyan** — info hints (`[Info] Start Claude Code …` under `switch`).
- **DarkGray** — dimmed metadata (verbose-view account row, "no plan-usage data" fallback, watch footer).

## Summary table (`Format-UsageTable`)

5 data columns + leading `*` active marker: `Slot | Account | Session | Week | Status`.

- **Merged bucket cells**. `Session` and `Week` combine utilization + reset delta in one cell: `100% (2h 37m)`. Cold bucket (`util=0`, `resets_at=null`) renders as ` 0%` only — em-dash sentinel only when bucket has no data at all. Auto-fit column widths.
- **Account column**. Pulls email from `Get-SlotFileInfo`. `—` for unlabeled / dedup-form. Middle-truncated with `…` at `$Script:AccountColumnMaxWidth = 32`. Full email retained in verbose view and `-Json`.
- **Status column** (mixes HTTP health + plan usability via `Get-PlanStatus`):

  | State | Label | Color |
  |---|---|---|
  | Both buckets < `$Script:UtilWarnPct` | `ok` | Green if active, Gray otherwise |
  | HTTP ok but no buckets | `ok (no plan data)` | same as `ok` |
  | Any bucket ≥ `UtilWarnPct`, all < `UtilLimitPct` | `near limit` | Yellow |
  | 5h bucket ≥ `UtilLimitPct` | `limited 5h` | Red |
  | 7d bucket ≥ `UtilLimitPct` | `limited 7d` | Red |
  | Both buckets ≥ `UtilLimitPct` | `limited` | Red |
  | HTTP 429, no fresh cache | `rate-limited` | Yellow |
  | HTTP failure | `expired` / `unauthorized` / `error: …` / `no-oauth (api key or non-claude.ai slot)` | Yellow / Red / Red / DarkGray |

  Thresholds: `$Script:UtilWarnPct = 90`, `$Script:UtilLimitPct = 100`. `Get-StatusColor` is the single source of truth so summary table and verbose view stay in lockstep.

**429 / `rate-limited` handling**: a 429 from `/api/oauth/usage` OR `/v1/oauth/token` (the latter from `Get-SlotUsage`'s pre-call refresh) is detected by `Test-Is429` and routed through the same fallback: serve fresh cached data when `$Script:SlotUsageCache` has a `<UsageCacheTTL = 10`-minute entry, else `Status='rate-limited'`. Advisory: `Anthropic API rate limited — displaying cached data.` Long error messages on `'expired'` / `'error'` arms are normalized through `Format-StatusErrorTail` (whitespace collapse + 60-char cap) so verbose exceptions can't wrap the row.

## Aggregate progress bars

Above the summary table, two pool-wide USAGE bars (one per bucket) emitted by `Format-AggregateBars` from inside `Format-UsageTable` when `-IncludeAggregateBars` is set. Set by `Format-UsageFrame` for the table view; intentionally NOT set by `Format-UsageVerbose`'s non-ok fallback.

```
[Usage] Plan usage

  Session [█████████████████████████████▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓]  52%

  Week    [████████████████████▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓]  36%

     Slot    Account              Session         Week          Status
```

**Formula**: `usedTotal = Σ min(util, 100)` over eligible rows (per-row clamp); `cap = N * 100`; `usedPct = round(usedTotal / cap * 100)`. Null/missing utilization counts as 0.

**Slot-inclusion**: Status `'ok'` only.

**Width**: `barWidth = TotalLineWidth − 17` (overhead: 2 indent + 8 label pad + brackets + space + `NNN%`), floored at 8. `Format-UsageTable` passes `TotalLineWidth` after its column-width loop.

**Color** via `Get-AggregateBarColor` (pure helper, extracted for unit-testing without mocking `Write-Host`):
- `usedPct ≥ $Script:AggregateRedPct (90)` → Red
- `usedPct ≥ $Script:AggregateYellowPct (50)` → Yellow
- else → Green

**Why `Write-Host`, not `Write-Progress`**: stream 4 is missed by the suite's `6>&1 | Out-String` capture; `Write-Progress` is host-managed transient (wouldn't sit inline above the table); doesn't compose with `Invoke-UsageWatch`'s DEC 2026 sync envelope.

When no eligible rows exist, `Format-AggregateBars` emits nothing.

**README screenshot divergence**: the README's screenshot code blocks
intentionally use ASCII space (U+0020) for empty cells instead of `▓`.
GitHub's CSS font fallback renders `▓` at a slightly different
effective width than `█` for some viewers, breaking visual alignment
inside markdown code blocks. ASCII space is guaranteed cell-uniform and
sidesteps the fallback issue. The live script keeps `█`/`▓`
because real terminal monospace fonts (Consolas, SF Mono, Cascadia Code)
render both Block Element glyphs at identical widths. Do not "re-sync"
the README to `▓` — the divergence is deliberate.

## List table (`Format-ListTable`)

2 data columns + leading `*` marker: `Slot | Account`. Mirrors `Format-UsageTable`'s shape (same active-marker conventions, same `Format-AccountCell` truncation). Pure offline render.

`Format-UsageTable` and `Format-ListTable` are kept as siblings rather than factored — different per-cell rules, two callers, abstraction would cost more than it saves.

## Switch action output

Header line + table + cyan `[Info]` hint:

```
[Switch] Switched to 'slot-1' (ada.lovelace@arpa.net)

    Slot    Account
    ------  ---------------------
  * slot-1  ada.lovelace@arpa.net
    slot-2  ada@arpa.net

[Info] Start Claude Code to apply the new identity (Email + tokens are both swapped).
```

- **Success line**: DarkYellow header, no trailing period (it's a header, not a sentence).
- **Table**: `Format-ListTable -Slots <fresh-slots> -SuppressHeader`. Slot list re-enumerated post-switch so `*` reflects the just-updated `state.active_slot`.
- **`[Info]` hint**: cyan, last line. Reflects post-v2.1.0 design — switch updates BOTH `.credentials.json` (tokens) AND `~/.claude.json`'s `oauthAccount` (email shown by `/status`). Suppressed for single-slot no-op.
- **`~/.claude.json` write failure**: yellow advisory `[Switch] Tokens swapped to '<name>' but ~/.claude.json oauthAccount update failed: <reason>` followed by `Claude Code's /status email may not reflect the new slot until you fix and re-run.`
- **Yellow advisory branches** above the success line:
  - **Reconcile advisories** (auto-save / identity-change) — emitted by `Invoke-Reconcile` itself.
  - **No active slot detected** (rotation only): `[Switch] No currently active slot detected. Rotating to <ident>.` Rotation still proceeds.
  - **Single-slot-already-active no-op** (rotation only): `[Switch] Only one slot (<ident>) and it is already active. Nothing to do.` Skips success line, table, hint. Emitted by `Get-NextSlotName` itself; returns `$null` so caller exits early.

`Format-SlotIdentity` is the single source of truth for dedup logic: `'<slot>' (<email>)` for labeled slots whose email differs from the slot name, `'<slot>'` (no parens) for unlabeled or dedup-form slots. Same rules as `Format-AccountCell`.

`Get-NextSlotName` return shape: `{ To = { Name; Email }; HasActiveSlot = <bool> }` or `$null` for the single-slot no-op.

## Verbose view (`Format-UsageVerbose`)

```
[Usage] Slot 'slot-1'
  Account: ada@arpa.net
  Status:  limited 5h - no prompts until 5h window resets
  Session    100%  Resets 7:50pm Europe/Berlin
  Week        28%  Resets Apr 26, 9am Europe/Berlin
```

`Status:` line sits between `Account:` and bucket rows so the usability verdict is read first. `Get-StatusRationale` supplies short English tails for non-obvious labels; plain `ok` renders without a tail.

## `/api/oauth/usage` response schema

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
  // Plus internal/unreleased buckets (null for external subs):
  // seven_day_oauth_apps, seven_day_cowork, seven_day_omelette,
  // iguana_necktie, omelette_promotional. Format-UsageVerbose iterates
  // $Data.PSObject.Properties so any future non-null bucket surfaces
  // with a '? <key>' prefix without code changes.
}
```

Verified against a live Team-plan call on 2026-04-24. All branches optional; free-tier / API-key accounts receive `{}`. The `-Json` switch emits the raw response under `data` per slot.

By design only `five_hour` (*Session*) and `seven_day` (*Week*) are rendered in summary/verbose views — matching Claude Code's own `/usage` first two bars. Other buckets round-trip via `-Json`.

Claude Code internally re-shapes this into `{ rate_limits: { five_hour: { used_percentage, resets_at } } }` for its status-line hook. **Do not** trust the hook-input schema for parsing the raw endpoint response.

`Format-ResetDelta` renders the ISO string as relative delta in the table (`(2h 14m)`, `(103h)`). `Format-ResetAbsolute` renders local-tz wall-clock in `sca usage <name>` verbose view (`Resets 7:50pm Europe/Berlin`, `Resets Apr 26, 9am Europe/Berlin`).

## `-Json` output

```jsonc
{
  "slot-1": {
    "status":             "ok",
    "is_active":          false,
    "plan_status":        "limited 5h",   // absent for HTTP-failure rows
    "is_cached_fallback": true,           // present (and true) only when row served from $Script:SlotUsageCache after a 429
    "account":            { "email": "ada@arpa.net" },
    "data":               { /* raw /api/oauth/usage body */ }
  }
}
```

`plan_status` matches Status column labels verbatim so scripts can branch without re-deriving thresholds. Full untruncated email always in `account.email`. `is_cached_fallback` is the JSON signal of the rate-limited cached-fallback condition.

## Watch mode (`Invoke-UsageWatch`)

Self-refreshing live view. Re-polls every `-Interval` seconds (default + floor **60 s**), redraws every 1 s so the frame self-heals on terminal resize within ~1 s instead of waiting up to `-Interval` seconds.

**Flicker-free rendering**:
- Enter alt buffer (`ESC[?1049h`) + hide cursor (`ESC[?25l`) on entry; `finally` block restores on Ctrl-C.
- Each frame wrapped in DEC mode 2026 (synchronized output: `ESC[?2026h` … `ESC[?2026l`) with `ESC[2J` + cursor-home (`ESC[H`).
- Terminals that support DEC 2026 (Windows Terminal ≥ 1.13, VS Code, iTerm2 ≥ 3.4.13, kitty, alacritty, WezTerm, foot, gnome-terminal/vte, mintty, modern ConHost) render flicker-free; older terminals ignore the unknown DEC private mode (no regression).
- VT control sequences emitted via `Write-VTSequence` (which calls `[Console]::Out.Write` + `Flush`) so they bypass the `Write-Host` -> `StringDecorated.AnsiRegex` filter that `OutputRendering = 'PlainText'` (set by `-NoColor` / `NO_COLOR`) applies. The filter strips DEC private modes (`ESC[?...h/l`) including the DEC 2026 envelope and the `ESC[?1049h` alt-buffer toggle, which would re-introduce the pre-`36e5e27` flicker. Verified against PowerShell `StringDecorated.cs`.

**Design split**:
- `Get-UsageSnapshot` — pure data-gathering: enumerates slots, calls `Get-SlotUsage`, returns `{ Results, NoSlots, HasCacheFallback }`. Never renders. Used by both one-shot and watch paths. Reconcile runs once per poll boundary.
- `Format-UsageFrame` — pure renderer: snapshot + optional footer → table-or-verbose + optional advisory + footer. Used identically from both paths.
- `Invoke-UsageWatch` — the loop itself (untested). Alt-buffer + sync-mode wrapper around `Format-UsageFrame` on a 1 s `Start-Sleep` tick. No keyboard listeners — Ctrl-C terminates via runtime default; `finally` emits `ESC[?25h` + `ESC[?1049l` and restores `[Console]::CursorVisible`.

**Runtime guards** (both throw):
- `-Watch -Json` mutex — enforced at binder level (parameter sets) AND runtime (for direct callers like the test suite that bypass `Invoke-Main`).
- `[Console]::IsOutputRedirected` — `sca usage -Watch > file.txt` refused; error points at `-Json`.

**Interval clamping**: values below `$Script:UsageWatchMinInterval = 60` clamp up to 60 with a yellow advisory. Floor matches the default — `-Interval` can only *slow* the poll.

**Error handling**: HTTP failure mid-loop keeps previous snapshot on screen; second line under footer reads `[Watch] Last poll failed: <msg> (keeping previous data; will retry on next tick)`.

**Terminal title (OSC 0)**: each successful poll emits `ESC ] 0 ; <title> BEL` via `Write-VTSequence` so the tab label / Windows taskbar / Alt-Tab tooltip carries live usage when the watch window is in the background. Format: `[<prefix>] <5h%> | <7d%> | Switch Claude Account` — built by `Format-WatchTitle` (pure helper). Source row priority: explicit `-Name <slot>` match → row where `IsActive = $true` → bare suffix. Active-slot-only is deliberate: a multi-slot pool mean averaged a burned slot's 100% down to noise (1 of 5 slots at 100% reads as ~20% mean), defeating the alarm-glance value of the title. Alarm prefix tiers reuse `$Script:UtilWarnPct` / `$Script:UtilLimitPct` so the title prefix and the body Status column stay in lockstep: `[!]` when any bucket ≥ `UtilLimitPct` (matches `Get-PlanStatus`'s `limited 5h` / `limited 7d` / `limited`), `[~]` when any bucket ≥ `UtilWarnPct` and all below `UtilLimitPct` (matches `near limit`), no prefix below warn. `[!]` wins over `[~]` when buckets straddle. Null buckets render as `—` and contribute nothing to the alarm tier. Bare brand suffix when no usable row exists (no slots, source row missing, or source row's `Status -ne 'ok'` — covers expired / unauthorized / error / no-oauth / rate-limited uniformly, since stale numbers from a failed poll would mislead). Brand string lives in `$Script:WatchTitleSuffix`. Pre-watch title captured via `$Host.UI.RawUI.WindowTitle` (best-effort; some hosts throw) and restored with OSC 0 in the `finally` block; empty payload falls back to terminal-default tab label. Failed polls do NOT update the title — title and body go stale together until the next successful tick. Control bytes (`\x00-\x1F\x7F`) stripped before emit as defense-in-depth against OSC envelope breakout.

## Identity sidecar — filename parser

```
^\.credentials\.(.+?)(?:\(([^()]*@[^()]*)\))?\.json$
    group 1 = slot name (lazy)
    group 2 = email      (only captured when parens contain '@')
```

The `@`-in-parens requirement keeps a slot named `work(v2)` parsing as *slot = `work(v2)`, email = none*. `Get-SafeName` sanitizes `(` and `)` in user-provided slot names to `_`, so user input cannot inject parens.

**Filename-email vs sidecar-email**: by save-time construction the filename `<email>` always equals the sidecar's `oauthAccount.emailAddress`. `Format-AccountCell` reads the filename email; reconcile and switch use the sidecar block.

**Sidecar shape** — see `.account.json` files for canonical structure: `{ schema: 1, captured_at, source: "claude_json"|"api_profile", oauthAccount: { accountUuid, emailAddress, organizationUuid, displayName, organizationName } }`. Whitelist excludes volatile metadata (`billingType`, `accountCreatedAt`, `subscriptionCreatedAt`, `ccOnboardingFlags`, `claudeCodeTrialEndsAt`, etc.) — restoring stale values for those would diverge from Claude Code's own picture.

## `~/.claude.json` write internals

`Set-OAuthAccountInClaudeJson`: targeted regex substitution within the `"oauthAccount": { ... }` block, NOT a full JSON round-trip. Block's opening `{` located by regex; brace-counting finds matching close; whitelisted fields substituted via `[regex]::Replace` with a `MatchEvaluator` (avoids `$1`/`$&` replacement-token surprises). Every other byte preserved.

Why not parse-and-reserialize: `~/.claude.json` is large, structurally complex, and `ConvertTo-Json -Depth 12` round-trip introduces subtle differences (key ordering, integer vs decimal, casing). Targeted substitution is the safer minimum. Tests assert byte-equal preservation of unrelated top-level fields through a save → switch round trip.
