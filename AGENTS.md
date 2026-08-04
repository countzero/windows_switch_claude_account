# AGENTS.md

This file is the canonical agent-instructions source for this repository, read natively by OpenCode and loaded by Claude Code through the `CLAUDE.md` import shim. Single-file PowerShell tool: core logic lives in `switch_claude_account.ps1`; tests live in `tests/` and use Pester 5.

## Editing this file

- Hard ceiling: 200 lines (Anthropic guideline; longer files reduce adherence).
- Describe the **current** shape only. Rationale, design history, and "why not the alternative" prose belong in commit messages.
- When you remove a design from the code, remove its references here too.
- Per-script-only details live in `.claude/rules/script-internals.md`; test-writing conventions in `.claude/rules/tests.md`. Both are path-scoped; load triggers in "Path-scoped rule files" below.

## Path-scoped rule files

Two extra rule files live under `.claude/rules/` and apply only to specific paths. Lazy-load them with the Read tool when (and only when) the trigger condition holds; do NOT preemptively load both at session start. Treat loaded content as mandatory for the current task. Claude Code auto-loads these via native path-scoping; this explicit instruction is what makes OpenCode pick them up too. Reading or editing `switch_claude_account.ps1` → also read @.claude/rules/script-internals.md (color/output, table layout, watch-mode, `/api/oauth/usage` schema, `Set-OAuthAccountInClaudeJson` regex details). Reading, editing, or creating files under `tests/` → also read @.claude/rules/tests.md (test-writing conventions).

## Key facts

- **Credential directory**: `%USERPROFILE%\.claude\`
- **Active credentials**: `.credentials.json`, written by Claude Code via atomic rename on every OAuth refresh. `sca` writes it via the same atomic-rename primitive (`Set-CredentialFileAtomic`) so the file is byte-equal to the tracked slot file after every `sca save` / `sca switch` / reconcile pass.
- **Claude Code config**: `%USERPROFILE%\.claude.json` (top-level, NOT inside `.claude\`), Claude Code's persistent config. Its top-level `oauthAccount` block is what `/status` displays as "Email:". `sca` reads this block at save time (primary identity source) and writes the destination slot's captured `oauthAccount` back to it on `sca switch`. See "`~/.claude.json` ownership" below.
- **State file**: `%USERPROFILE%\.claude\.sca-state.json`, schema v1: `{ schema, active_slot, last_sync_hash }`. Single source of truth for "which slot is active." Read with `Read-ScaState` (auto-migrates from a 1.x install on first read by hashing `.credentials.json` against existing slot files); written via `Update-ScaState` (`active_slot` / `last_sync_hash`). State files written by v2.3.0 - v2.4.0-draft carry a `last_warmup_at` field that is tolerated by `Read-ScaState` and dropped by the next state-mutating write (one-way; a build that still expects the field reads our field-less files cleanly because its reader defaults the field to `@{}` when absent).
- **Named slots**: `.credentials.<name>(<email>).json` (labeled) or `.credentials.<name>.json` (unlabeled, only for the dedup case where slot name equals email).
- **Identity sidecars**: `.credentials.<name>(<email>).account.json` alongside each slot file. JSON snapshot of the slot's `oauthAccount` (whitelisted: accountUuid, emailAddress, organizationUuid, displayName, organizationName) captured at save time. Restored to `~/.claude.json` on `sca switch`. **Slots without a valid sidecar are HIDDEN from `list` / `usage` / rotation and refused by `switch`**; re-running `sca save <name>` while that slot is active recaptures the sidecar.
- **PS version**: Requires PowerShell 7.2+ (`#Requires -Version 7.2`). Uses `$PROFILE.CurrentUserAllHosts` for the install target. The 7.2 floor is the version that introduced `$PSStyle.OutputRendering`, used by no-color mode.
- **Alias installer**: `sca` and `switch-claude-account` added to PowerShell profile via marker-delimited block (`# === Switch Claude Account ===`).

## Windows-specific gotchas

- **Atomic-rename writes survive an open Claude Code (for `.credentials.json` only)**. `Set-CredentialFileAtomic` calls `[System.IO.File]::Replace` / `::Move`, both of which invoke `MoveFileEx` and succeed against the FILE_SHARE_DELETE handle Claude Code keeps on `.credentials.json`. Retry policy: 3 attempts with 50 ms backoff to absorb transient sharing violations from antivirus / indexer scanners. **`sca save` / `sca switch` still refuse to operate while Claude Code is running**; but for a different reason: they read/write `~/.claude.json`'s `oauthAccount` block, which Claude Code keeps in an in-memory cache that may flush back and clobber our update.
- **Execution policy**: May need `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` on first run.
- **Token expiry**: OAuth tokens refresh / expire after ~1 hour of inactivity. Without a daemon, the slot file is at most one Claude-Code-refresh behind the active file at any moment; the next `sca usage` or `sca switch` invocation captures the refresh into the slot via `Invoke-Reconcile`. "One refresh behind" is harmless; the slot's previous refresh_token is still valid until rotated again. `Update-SlotTokens` (called by `sca usage` when the active slot's access token is expired) propagates new tokens to BOTH the slot file AND `.credentials.json`.
- **Reconcile fires on `list`, `usage`, `switch`, and `warmup`**, not on `save` (the explicit save IS the capture) or `remove` (no downstream read of the active slot's bytes). Inside `sca usage -Watch`, reconcile re-fires at every poll boundary so a Claude Code refresh that landed since the last poll is captured before `/api/oauth/usage` reads the slot bytes (this is also what makes `sca monitor` race-safe against background token refreshes on the outgoing slot). Auto-migration from 1.x is silent inside `Read-ScaState`; the first reconciling action after the upgrade refreshes `last_sync_hash`.
- **Cross-account swap detection**: when reconcile sees `.credentials.json` bytes differ from `state.last_sync_hash`, it identifies the live email by reading `~/.claude.json`'s `oauthAccount.emailAddress`. If the email matches the tracked slot's sidecar email, mirror through; if it differs, auto-save under `auto-<UTC-timestamp>(<new-email>)`. When `~/.claude.json` has no `oauthAccount`, falls back to a `/api/oauth/profile` HTTP call. Both probes failing falls into the same-identity mirror branch.
- **Name sanitization**: invalid Windows filename characters (`\ / : * ? " < > |` and control chars), parentheses (`(` `)`), PowerShell wildcard brackets (`[` `]`), and spaces are replaced with `_`. Brackets are sanitized because PowerShell's `-Path` parameter treats them as character-class wildcards; without sanitization, `sca remove foo[bar]` would silently wildcard-match unrelated slot files (paired with `-LiteralPath` on every credential-file op as defense-in-depth). Parens are sanitized because slot filenames encode the OAuth account email as `.credentials.<name>(<email>).json`; parens in the slot name would confuse `Get-SlotFileInfo`'s `(name, email)` split. `Get-SafeName` additionally strips trailing dots and hard-rejects reserved Windows device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`9`, `LPT1`-`9`).

## Script actions

| Action     | Requires name | What it does |
|------------|---------------|--------------|
| `save`     | Yes           | Refuses if Claude Code is running. Resolves identity from `~/.claude.json`'s `oauthAccount` (primary, offline); falls back to `/api/oauth/profile` only when the cache is empty. Both failing → refuses. Atomic-writes `.credentials.json` bytes into `.credentials.<name>(<email>).json` AND a paired `.account.json` sidecar. Updates `state.active_slot` and `state.last_sync_hash`. No reconcile prelude; explicit save IS the capture. |
| `switch`   | Optional      | Refuses if Claude Code is running. Reconciles first (so a pending refresh on the outgoing slot is captured), then atomic-writes the target slot's bytes into `.credentials.json`, then atomic-writes the destination slot's captured `oauthAccount` (whitelisted fields) into `~/.claude.json`. If `<name>` omitted, rotates to the next saved slot in alphabetical order (wraps). Refuses to activate a slot with no sidecar. |
| `list`     | No            | Reconciles first (so cross-account swaps detected since the last `sca` call surface in the marker column), then renders saved slots as `Slot \| Account` with leading active-marker column. `*` marker comes from `state.active_slot`. Sidecar-less slots silently filtered out. |
| `remove`   | Yes           | Deletes a named slot AND its sidecar. Walks the raw filesystem (not `Get-Slots`) so sidecar-less legacy slots can be cleaned by name. Refuses to remove the slot tracked as active in state. |
| `usage`    | Optional      | Read-only. Reconciles first, then calls Claude Code's **undocumented** `GET /api/oauth/usage` per slot for 5h / 7d plan-usage percentages. Auto-refreshes expired tokens via `Update-SlotTokens`. Accepts `-Json` for scripted output, or `-Watch` (optional `-Interval <seconds>`, floor 60) for a live view. With `<name>`, renders verbose single-slot block. |
| `monitor`  | No            | Live, side-effecting supervisor: `Invoke-MonitorAction` → the shared watch engine `Invoke-UsageWatch` with `-Auto` always set (rotation is the point, so no `-Auto` flag). Auto-rotates to the next eligible slot when the active slot's `max(5h, 7d)` utilization hits `-Threshold` (default 95, range 1..100); refuses if Claude Code is running (OpenCode-scoped). `-KeepWarm` (maps to the engine's `-Warmup`) also keeps every slot warm for the life of the watch via `Invoke-KeepWarmStep`. A positional `<name>` is ignored (whole-fleet). |
| `warmup`   | Optional      | Refuses if Claude Code is running or the `claude` binary is absent. One-shot, non-watch warm pass: reconciles, then for each saved slot (or just `<name>`) in alphabetical order runs `Invoke-WarmAllSlots` (swap → `claude -p` activation → mirror → usage read), restores the original active slot, and prints the usage table. Billable (~$0.004/slot on Haiku). |
| `install`  | No            | Adds wrapper function + aliases to PowerShell profile. |
| `uninstall`| No            | Removes wrapper function + aliases from profile. |
| `help`     | No            | Shows detailed help. |

## Editing the script

The profile install/uninstall uses marker comments (`# === Switch Claude Account ===`) to isolate its block. When modifying `Add-To-Profile` or `Remove-From-Profile`, keep these markers intact.

The top-level dispatcher is wrapped in `Invoke-Main` and guarded by `if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }` so tests can dot-source the script without triggering a live run. Each action body is extracted into an `Invoke-*Action` function so tests can call it directly. New actions: put the body in `Invoke-<Action>Action`, add a one-line dispatch to `Invoke-Main`.

`switch`, `usage`, `list`, and `warmup` call `Invoke-Reconcile` first (`switch` / `usage` / `warmup` need a fresh slot file; `list` needs an accurate active-slot marker after a possible cross-account swap). `save` skips reconcile (the explicit save IS the capture) and `remove` skips it too. New actions follow the same rule: reconcile when the action's output or downstream writes depend on a fresh slot file or accurate `state.active_slot`.

For color/output, table layout, watch-mode, and `/api/oauth/usage` schema details, see @.claude/rules/script-internals.md.

## Unofficial endpoints (`usage` action)

The `usage` action and the reconcile / save identity-fallback path depend on pinned constants extracted from `claude.exe` 2.1.119 (a Bun-compiled binary). They live at the top of `switch_claude_account.ps1` under the `# --- Unofficial Claude Code OAuth-flow constants ---` comment:

- `$Script:UsageEndpoint`       : `https://api.anthropic.com/api/oauth/usage`
- `$Script:ProfileEndpoint`     : `https://api.anthropic.com/api/oauth/profile` (`Get-SlotProfile`; email-only identity fallback when `~/.claude.json` has no `oauthAccount`)
- `$Script:TokenEndpoint`       : `https://platform.claude.com/v1/oauth/token`
- `$Script:OAuthClientId`       : `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (Claude.ai subscription flow)
- `$Script:AnthropicBeta`       : `oauth-2025-04-20`
- `$Script:AnthropicApiVersion` : `2023-06-01` (sent on every authenticated request for defense-in-depth against future endpoint tightening)
- `$Script:UsageUserAgent`      : `claude-code/2.1.119`

Per-endpoint HTTP budgets sit alongside them: `$Script:UsageTimeoutSec` (12), `$Script:TokenTimeoutSec` (15), `$Script:ProfileTimeoutSec` (10). Measured `/api/oauth/usage` round-trips span 46-2108 ms, so the shared 5 s these replaced left under 2.4x headroom and one spike wiped a slot's row. The refresh POST has its own larger budget because it does server-side crypto plus refresh-token rotation; it previously borrowed the usage constant and ran tightest of the three. A failed read never discards known-good data: see the failed-read ladder in @.claude/rules/script-internals.md.

Warmup no longer hits `/v1/messages` directly: the `warmup` action and `monitor -KeepWarm` open each slot's 5h window by running the real Claude Code CLI (`claude -p`, via `Invoke-SlotActivator`), pinned by `$Script:ActivatorModel` (`haiku`), `$Script:ActivatorPrompt` (`Hi`), and `$Script:ActivatorTimeoutSec`. That delegates the OAuth refresh to Claude Code's own flow, so warmup depends on the `claude` binary being installed and logged in rather than on a pinned messages endpoint.

**Undocumented and unsupported by Anthropic.** When the call starts returning 4xx after a Claude Code upgrade, re-extract from `$(Get-Command claude).Source` using the grep recipe in the script header comment, bump the constants, and re-run `tests/Invoke-Tests.ps1`. The tests mock `Invoke-RestMethod` by `$Uri` and verify shape contract only; they will not catch the constants drifting out of date.

Response schema summary: `five_hour` and `seven_day` (rendered as *Session* / *Week*) carry `{ utilization: 0..100, resets_at: ISO-8601|null }`. Plus `seven_day_opus`, `seven_day_sonnet`, `extra_usage`, and internal buckets that round-trip via `-Json` but are not rendered. Full schema: @.claude/rules/script-internals.md.

## Identity capture: filename + sidecar

A slot's identity is captured ONCE at save time and frozen in two paired files:

```
.credentials.<name>(<email>).json          ← OAuth tokens (what Claude Code reads)
.credentials.<name>(<email>).account.json  ← identity sidecar (sca-only; whitelisted oauthAccount)
```

**Identity resolution at save time** (`Invoke-SaveAction`, priority order):

1. `~/.claude.json`'s `oauthAccount` (read by `Get-OAuthAccountFromClaudeJson`). Preferred; same source Claude Code uses for `/status`, so the slot's labeled email cannot drift from Claude Code's display by construction. Offline.
2. `/api/oauth/profile` (via `Get-SlotProfile`); fallback for fresh installs where `oauthAccount` is empty. Yields only `emailAddress`; the other four whitelisted fields default to `null` in the sidecar.
3. Both failing → save is **refused**. There are no unlabeled-no-identity slots.

**Atomic-pair invariant on save**: existing slot bytes are snapshotted in memory first; tokens file is written, then the sidecar. If either write fails, the partial new pair is removed and the pre-existing pair is restored from the snapshot. A half-saved slot can never appear invisible-but-present, and a save failure cannot delete the user's existing slot.

## `~/.claude.json` ownership

`~/.claude.json` is Claude Code's persistent config: `oauthAccount` at the top level alongside ~50 other fields (project history, mcp configs, statsig gates, settings). `sca` interacts with it minimally and surgically:

- **Read** (`Get-OAuthAccountFromClaudeJson`): full JSON parse via `ConvertFrom-Json`, extract whitelisted fields. Failure modes (missing, parse error, no oauthAccount, empty emailAddress) all return `$null` so callers fall through to `/api/oauth/profile` or refuse. Used by `Invoke-SaveAction` (primary identity source) and `Invoke-Reconcile` (identity probe).
- **Write** (`Set-OAuthAccountInClaudeJson`): targeted regex substitution within the `"oauthAccount": { ... }` block, NOT a full JSON round-trip. Whitelisted fields substituted via `[regex]::Replace` with a `MatchEvaluator`. Every other byte preserved. Null-valued whitelisted fields on the source `$OAuthAccount` are skipped; they preserve the existing `~/.claude.json` value rather than overwriting with `null`. The asymmetry is deliberate: `null` → real (upgrading a previously-null cached field) still works because the substituted value is non-null; real → `null` (which would wipe Claude Code's cached identity when an `/api/oauth/profile`-fallback sidecar carries the four non-email defaults as `null`) is blocked. Tests assert byte-equal preservation of unrelated top-level fields AND the null-skip preservation. Implementation details in @.claude/rules/script-internals.md. Called by `Invoke-SlotSwap` (shared by `Invoke-SwitchAction` and the `sca monitor` rotation step).
- **Lock contract**: there is **no** lockfile. Claude Code uses `proper-lockfile` to serialize its own writes via `~/.claude.json.lock`; `sca` deliberately does NOT participate. Instead, `sca save`, `sca switch`, and `sca monitor` refuse to operate when Claude Code is running (`Test-ClaudeRunning`). Stronger guarantee than locking: zero possibility of a stale in-memory cache, because Claude Code is not running to hold one.
- **Backup recovery**: Claude Code maintains rolling timestamped backups at `~/.claude.json.backup.<unix-ms>` (last 5, throttled to ≥1 minute apart). If a `sca` write ever corrupts `~/.claude.json`, restore from the latest backup. `sca` itself does NOT create backups.
- **Failure mode**: if `Set-OAuthAccountInClaudeJson` throws, `Invoke-SwitchAction` catches, prints a yellow advisory, and proceeds. The credentials swap has already happened; only the email-display update fails. Re-run the switch once the issue is fixed.

## Reconcile semantics

`Invoke-Reconcile` fires on `list`, `usage`, `switch`, and `warmup` (one-shot prelude), plus per-poll inside `monitor` / `usage -Watch`; not on `save` or `remove`. Identity probe priority:

1. `Get-OAuthAccountFromClaudeJson`: preferred; offline; returns full `oauthAccount` for the auto-save sidecar.
2. `Get-SlotProfile` against `.credentials.json`: fallback. Yields only `emailAddress`.
3. Both failing → falls into the same-identity mirror branch (no auto-save).

Identity comparison: live `~/.claude.json` email vs. the tracked slot's **sidecar** `oauthAccount.emailAddress` (NOT the filename email; sidecar is the source of truth). Mismatch → auto-save under `auto-<UTC-timestamp>(<new-email>)` and update `state.active_slot`. Auto-save without identity yields a sidecar-less slot file that `Get-Slots` will hide on the next enumeration.

## Auto-rotation (`sca monitor`)

OpenCode-scoped (issue #8): requires `opencode-claude-auth >= 1.5.4`, which re-reads `.credentials.json` on cache miss so a swap propagates without restarting OpenCode. Claude Code itself is NOT supported (its in-memory `~/.claude.json` cache would race the swap); `monitor` refuses at startup AND re-checks `Test-ClaudeRunning` before every rotation. Trigger: `Get-AutoRotationDecision` compares the active slot's `Get-RowMaxUtilization` against `-Threshold` (default 95, range 1..100; the 5-pt margin absorbs `/api/oauth/usage` reporting lag). At or above → walk peer slots in alphabetical wrap order (matches `Get-NextSlotName`), skip non-ok HTTP rows and peers themselves at/above threshold, swap into the first eligible peer via `Invoke-SlotSwap` (the extracted core shared with `Invoke-SwitchAction`). No eligible peer → render `[Monitor] No free slot available! Cooling down for <delta>` with the soonest future reset across all slots/buckets. UI: right-aligned `▶ switching slot at N%` header indicator (glyph white + text DarkGray; silent fallback when terminal too narrow) plus an extra blank line under the header in `monitor`, plus a latched `[Monitor]` footer line per frame (`Enabled` / `Rotated from "A" to "B" at HH:mm:ss` / `No free slot available! Cooling down for X` / `Active slot usage unknown (<status>); rotation paused.` / `Rotation refused! Claude Code is running.` / `Rotation failed! <message>`). Internally the engine still calls this its `-Auto` mode.

`Get-RowMaxUtilization` is the single definition of "at limit", shared with `Test-WarmEligible`. It is `max(five_hour, seven_day)` over `$Row.Data` **whenever Data is present, regardless of Status** (matching `Format-UsageTable`, which already renders percentages from Data alone: a row good enough to show the user is good enough to decide on), with a bucket whose `resets_at` has passed counting 0 (its window rolled, so the number we hold is obsolete; without this, cached data with no upper age bound could rotate away from a slot that is actually free) and null/missing buckets counting 0. A non-ok active row **with** cached data is judged on it, so a throttled slot at 100% still rotates. A non-ok active row with **no** data yields `Action='active-unknown'` (carrying `ActiveStatus`) and rotation deliberately does not fire: moving off a slot we know nothing about would burn a healthy account. Reporting it is the point, because the previous `noop` there silently disarmed rotation while the frame kept showing a reassuring `Rotated ...` line. A snapshot with no active row at all stays `noop`; that is a state problem, not a network one. Peers still require `Status -eq 'ok'`, because cached evidence is enough to decide to LEAVE a slot but not to ENTER an unverified one.

## Warmup (`warmup` action and `monitor -KeepWarm`)

Both warmup entry points share `Invoke-WarmAllSlots`. The standalone `sca warmup [name]` action runs one warm pass and prints the usage table (no live view); `sca monitor -KeepWarm` runs the same pass as the first frame before entering the polling loop, then keeps slots warm for the life of the watch via `Invoke-KeepWarmStep` (per-poll re-warm of closed windows; see below). Per saved slot in alphabetical order: `Invoke-SlotSwap` makes it active, then `Invoke-SlotActivator` runs the real Claude Code CLI (`claude -p "Hi" --safe-mode --model haiku --output-format json --no-session-persistence`) as that slot so Anthropic opens its server-side 5h session window. This is exactly the manual "switch + send one message" routine; running the real client (not a hand-rolled request) delegates the OAuth token refresh to Claude Code's own flow. `--safe-mode` keeps OAuth but disables this repo's own `CLAUDE.md` / MCP / hooks / skills (cheap, no project context). Cost: ~$0.004/slot (the base Claude Code system prompt is ~3k input tokens even in safe-mode).

`Invoke-SlotActivator` returns Get-SlotUsage's status vocabulary: a no-OAuth slot is short-circuited to `no-oauth` without spawning claude; otherwise the `--output-format json` envelope is parsed (exit 0 + `is_error:false` → `ok`; else the message text is scanned to classify `rate-limited` / `unauthorized` / `expired` / `error`). `Invoke-ClaudeActivatorProcess` is the mockable seam that actually spawns claude (Start-Process, redirected stdio, `$Script:ActivatorTimeoutSec` kill-on-timeout). **Mirror-then-verify** after an `ok` activation: `Invoke-Reconcile` copies the token claude just refreshed from `.credentials.json` back into the slot file (same-identity mirror; the swap wrote this slot's email to `~/.claude.json`, so it never auto-saves) **before** `Get-SlotUsage` reads live percentages — reading first would hit the slot's stale pre-activation token and trigger sca's own refresh. A non-ok activation skips both the mirror and the usage read, so a throttled slot incurs zero sca refresh calls. A `finally` block restores the original active slot.

Per-slot progress in the Status column (watch path): `warming up` (queued) → `priming` (`claude -p` in flight) → real outcome. The end-state snapshot IS the first frame of the polling loop. `$Script:WarmupSpacingMs` (300 ms) between slots dodges per-IP burst limits. Both entry points refuse pre-loop when Claude Code is already running (the per-slot swap writes `~/.claude.json`'s `oauthAccount`, which a live Claude Code caches); the short-lived `claude -p` warmup spawns is awaited to exit before the next swap, so it never overlaps a file write. The `warmup` action additionally refuses when the `claude` binary is absent. Swap failures share the `error` label with activation failures; the exception message in the row's Error tail names the failing operation. `-Name` narrows warmup to a single slot. Refused when no slots match.

Watch keep-warm (`Invoke-KeepWarmStep`, runs each poll after the rotation step): re-warms every slot the pure `Test-WarmEligible` predicate flags. First clause, before all others: a slot at or above `-Threshold` (by `Get-RowMaxUtilization`) is skipped, because warming opens the 5h window and a window that is open and full gains nothing from a billable `claude -p`; checking it first is what gates the rate-limited branch, where an exhausted slot usually surfaces, and sharing the helper with rotation is what keeps warm-eligible and rotation-source disjoint by construction. `-Threshold` is mandatory on `Test-WarmEligible` and `Invoke-KeepWarmStep` so a wiring mistake fails loudly (it cannot become a `$Script:` constant: the top-level `Param` block's default binds before the script body runs, and `[ValidateRange]` cannot take a variable). Otherwise eligible: an HTTP-ok slot whose `five_hour` window has closed (bucket missing or `resets_at` null/past; a mid-window slot carries a future `resets_at`), OR a `rate-limited` slot (the recovery path out of the "frozen on rate-limited until restart" state: a real `claude -p` refreshes tokens through Claude Code's own OAuth flow and reopens the window). Hard-fail rows (`expired` / `unauthorized` / `no-oauth` / `error`) are skipped, as is any slot re-warmed within `$Script:WarmupCooldownMin` (default 5; in-memory per-session map seeded by the startup pass, never persisted). A 5h window can only be RE-opened after it closes, so for ok slots this is reactive. It re-checks `Test-ClaudeRunning` per tick (the swap writes `~/.claude.json`), reuses `Invoke-WarmAllSlots -Names <cold>` (`6>$null`), does NOT merge results into the snapshot (the next poll re-reads `/api/oauth/usage`), and latches a `[Warmup]` footer line (`Keeping all slots warm.` / `Rate-limited; will re-warm when cooldown clears.` / `Re-warmed '<names>' at HH:mm:ss` / `Re-warm refused! Claude Code is running.` / `Re-warm failed! <message>`).

## Testing

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1
```

Run a single test or context (`-FullNameFilter` is wildcard/regex against full `Describe > Context > It` path):

```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ -FullNameFilter '*Get-SafeName*' -Output Detailed"
```

The runner auto-installs Pester 5 (CurrentUser scope) on first use. PSScriptAnalyzer, if installed, runs in advisory mode. Tests sandbox `$env:USERPROFILE` and `$PROFILE.CurrentUserAllHosts` per test via `$TestDrive`. Test-writing conventions: @.claude/rules/tests.md.

Code coverage on `switch_claude_account.ps1` runs by default and prints a console summary; the JaCoCo XML lands in `tests/TestResults/coverage.xml` (gitignored). Coverage gate: 90% minimum via Pester's `CoveragePercentTarget`, overridable with `-CoverageThreshold <int>` (`0` disables the gate but keeps the summary). Use `-SkipCoverage` for the fastest local loop.

Per-function complexity diagnostic (advisory, on-demand): `pwsh -NoProfile -File tests/Measure-Complexity.ps1`, an AST walker reporting LOC, McCabe CC, max nesting per function. Rows with CC ≥ 10 or nest ≥ 4 flagged.

## README image regeneration

Four SVG terminal-output examples in `docs/images/` (`usage-watch`, `usage-table`, `usage-verbose`, `monitor`) are rendered by `tools/Render-ReadmeImages.ps1` via [`charmbracelet/freeze`](https://github.com/charmbracelet/freeze) (install: `winget install charmbracelet.freeze`). The harness is **hand-authored ANSI matching the README literally**; it does NOT call `Format-UsageFrame`. Colors are emitted as **truecolor SGR** (`ESC[38;2;R;G;Bm`) targeting Microsoft's Campbell palette (Windows Terminal default), so the rendered SVGs match what users see in default `pwsh.exe` rather than freeze's hardcoded charm palette (`freeze/ansi.go`'s `ansiPalette` map can't be overridden via flag/config; truecolor passes through verbatim as `fill="#RRGGBB"`). Background is set to Campbell's `#0C0C0C` for the same reason. Re-run when: (a) README example numbers / emails change, (b) `Write-Color` / `Get-StatusColor` / `Get-AggregateBarColor` mappings change in `switch_claude_account.ps1`, or (c) Microsoft ships a new Campbell — edit the truecolor constants at `tools/Render-ReadmeImages.ps1:137-143` and run: `pwsh -NoProfile -File tools/Render-ReadmeImages.ps1`. JetBrains Mono is embedded in each SVG (~360 KB) for pixel-identical rendering across viewers. README contract: each SVG is wrapped in `<p align="center"><img ... width="720"></p>`; the HTML `width` attribute (not CSS `style`, which GitHub's Markdown sanitizer rewrites to `max-width:100%`) must equal `--width` in the renderer so the image renders at 1x intrinsic and centered in the GitHub content column. If you change `--width`, change all five `width` values in `README.md` to match (`monitor.svg` is referenced twice).

## Default Change Workflow

After any code change, run `pwsh -NoProfile -File tests/Invoke-Tests.ps1` (Pester + PSScriptAnalyzer advisory; the implicit parse-time check when the script is dot-sourced is the only "typecheck"). Commit and push are **not** automatic: commit only when explicitly asked, push only when explicitly asked, and "commit" does not imply "push."

## Code Comments

Comments explain **why**, not **what**; the code already states what it does, and a comment that restates it drifts out of sync.

- **Default to no comment.** Prefer a clearer name or a smaller function; comment only when the *reason* is non-obvious from the code.
- **One source of truth per rationale.** Document a non-obvious decision once at the authoritative place and reference it tersely from other call sites.
- **History lives in git.** The commit message and `git blame` carry change history, not comments.
- **No WHAT-comments.** Don't preface a line or block with prose that paraphrases it.
- **Length is a smell.** A why-comment over ~3 lines usually signals unclear code or naming; fix the code first.

## Scratch files

Ad-hoc agent artifacts (screenshots, diffs, scratch scripts, traces) go under `.tmp/sessions/<session-id>/`. `.tmp/` is gitignored. Never write scratch files to `.claude/`, the repo root, or `tests/`.

## Multi-Agent Working Tree Discipline

Multiple agents may share this directory; foreign uncommitted changes and untracked files are untouchable.

1. **Foreign changes off-limits.** Never run `git checkout --`, `restore --`, `reset --hard`, `clean`, `rm`, `mv`, or `git stash pop/apply` on a path another agent modified or an untracked file another agent created. "Commit and push" does NOT authorise destructive cleanup of foreign paths.
2. **Preflight.** `git status --porcelain -u` at task start and again before `git commit`.
3. **Session-scoped scratch.** Use `<session-id>` from your runtime's session metadata if exposed; otherwise mint `YYYYMMDD-HHMMSS-<random6>`.
4. **Stashes session-scoped.** Only with explicit pathspec and tagged message: `git stash push --message "session-<id>: <reason>" -- <files>`. Bare `git stash`, `-u`, `--all`, and pop/apply of foreign stashes are forbidden.
5. **Edit and shell writes are mutually exclusive per file.** If a file was written outside the Edit tool, the cached content is stale. Re-Read before the next Edit. If Edit fails with "oldString not found", assume concurrent foreign write: surface to the user, do not guess.
6. **Worktrees.** `.claude/worktrees/<branch-name>/` is gitignored. Cleanup with `git worktree remove <path>`; no `--force`.

When your changes overlap foreign WIP in the same file, stop and ask. Do not reset, restore, or stash.

## Version Control

- [Semantic Versioning](https://semver.org/).
- Changelog follows [Common Changelog](https://common-changelog.org).
- LF line endings enforced via `.gitattributes`.
- No `Co-Authored-By` trailer in commit messages.

## Skills

- `plan-review` / `pr-code-review` (under `.claude/skills/`): second-pass design review before non-trivial plans; multi-pass PR review.

## Punctuation: prefer specific marks over the em dash

The em dash (`—`) is reserved for genuine emphatic interruption or a sudden break in thought. For every other use, prefer the more specific mark (rewriting the sentence is also fine), and do not strip a dash where it is the right mark: a comma for a short aside tightly bound to the sentence; parentheses for a tangential aside; a colon to introduce an explanation, list, or summary; a semicolon or period to join two related independent clauses; a rewrite or period for a rhetorical "not X, Y" contrast; an en dash (`–`) for a numeric or date range; a hyphen (`-`) for a compound modifier. The rule is to stop using `—` as a default joiner where `:`, `;`, `,`, `(...)`, or a period would be clearer.
