# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Common Changelog](https://common-changelog.org),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.5.0] - 2026-05-27

### Changed
- `sca usage -Watch -Warmup` round-robins through every saved slot before entering the steady-state polling loop: per slot in alphabetical order, `Invoke-SlotSwap` makes it active (writes `.credentials.json` + `~/.claude.json` `oauthAccount` + `state.active_slot`), then `Get-SlotUsage` probes `/api/oauth/usage` as the now-active slot, then the next slot. A `finally` block restores the original active slot via one more swap so the user ends warmup where they started. Reinstates the v2.3.0 design that was removed in v2.3.1. The v2.3.1 CHANGELOG called the round-robin a no-op based on warm-slot measurements; v2.5.0 reverses that under the empirical observation that the measurement only covered slots already primed by recent manual switches, and a truly cold slot's `/api/oauth/usage` can return empty bucket data until the slot is made active locally. Swap and probe failures both surface as `Status='error'` with the exception message in the row's Error tail; the loop continues with the remaining slots.
- `Test-ClaudeRunning` guard extended to `-Warmup` (pre-loop refusal). Mirrors `-Auto`'s existing guard since both flags now write `~/.claude.json`'s `oauthAccount` block, which Claude Code keeps in an in-memory cache. Combined guard message branches on whether `-Auto` or `-Warmup` triggered it.
- `New-WarmupScaffold` row projection carries the slot's `Sidecar` so `Invoke-WarmAllSlots` can pass the row straight to `Invoke-SlotSwap` without re-walking the filesystem per slot.

## [2.4.0] - 2026-05-27

### Added
- `-Warmup` flag on `sca usage -Watch`. Performs the first `/api/oauth/usage` poll serially per slot before entering the steady-state polling loop, with per-slot progress visible in the Status column: `warming up` (queued) -> `refreshing` (call in flight) -> the real HTTP outcome (`ok` / `rate-limited` / `no-oauth` / `expired` / `unauthorized` / `error`). End-state snapshot is handed off to the polling loop as its first frame; no immediate re-poll. Independent of `-Auto`: works with bare `-Watch` (`sca usage -Watch -Warmup`) and combines with `-Auto` (`sca usage -Watch -Auto -Warmup`). Aggregate Session/Week bars grow as `ok` rows accumulate during the warmup phase, so the layout during warmup matches the steady-state polling layout.

### Changed
- `sca usage -Watch -Auto` no longer warms slots automatically. Pass `-Warmup` to restore the prior behavior (`sca usage -Watch -Auto -Warmup`). Users who want the auto-rotation policy without the per-slot startup latency get a faster `-Auto` invocation; users who want warmup without auto-rotation can use it standalone.

### Removed
- `state.last_warmup_at` map and the `Get-SlotWarmupTimestamp` / `Set-SlotWarmupTimestamp` helpers. The previous warmup design needed a per-slot 60 s cooldown to avoid thrashing `/v1/oauth/token` across rapid `-Watch -Auto` restarts. The new warmup calls `Get-SlotUsage` (which is what the polling loop does anyway and has its own cache + retry budget), so the cooldown's premise is gone. Legacy state files carrying the field continue to parse cleanly; the field is silently ignored and dropped by the next state-mutating write. State schema stays at `1`.
- `$Script:WarmupCooldownMs` constant.

## [2.3.1] - 2026-05-26

### Fixed
- `sca usage -Watch -Auto` startup warmup now actually warms slots. The 2.3.0 design rotated `.credentials.json` through each slot via `Invoke-SlotSwap` and restored the original, on the premise that the swap itself "activated" each slot from Anthropic's side. This was a no-op: a local file rewrite generates no observable event server-side. Replaced with a direct refresh: `Invoke-WarmAllSlots` calls `Update-SlotTokens` for every saved slot whose access token is at or near expiry, so the first poll sees fresh bearers and returns real bucket numbers for every slot whose `refresh_token` Anthropic still trusts.
- `Update-SlotTokens` retries `/v1/oauth/token` 429 responses up to `$Script:TokenRefreshRetryMax` times (default 3) with exponential backoff (`$Script:TokenRefreshRetryDelayMs`, default 2 s → 4 s). The refresh endpoint's per-token rate limit unlocks within seconds, so a slot whose first refresh attempt got 429d during a polling tick now self-recovers in the same tick instead of showing `rate-limited` until the user happens to invoke another sca command. Benefits every call path that triggers a refresh: `sca usage`, `sca usage -Watch`, `sca usage -Watch -Auto`, `sca switch`.

### Changed
- `Invoke-WarmAllSlotsBySwitch` renamed to `Invoke-WarmAllSlots` (the `BySwitch` suffix no longer describes what the function does). The function signature is unchanged; only the orchestrator's body and its rendered progress messages were rewritten.
- Warmup no longer rotates `.credentials.json` or `~/.claude.json`. The Ctrl-C-safe credentials restore step and the sidecar-less-active refusal both go away with the swap; the warmup is now pure-network and leaves no state behind to roll back. A new 300 ms `$Script:WarmupSpacingMs` sleep between slots dodges per-IP burst rate limits on `/v1/oauth/token`.

## [2.3.0] - 2026-05-26

### Added
- `sca usage -Watch -Auto` warms every saved slot at startup by briefly switching to each one via `Invoke-SlotSwap`, then restoring the original active slot. Anchors each slot's 5h window so the first poll's Status column reports real bucket numbers instead of empty `—` cells or `rate-limited` from cold slots. Visible to the user as `warming up` (yellow) in the Status column with per-slot progress on the `[Auto]` footer line; no flashed output before the alt-screen UI appears.
- Per-slot warmup cooldown: `Invoke-WarmAllSlotsBySwitch` records each attempt in `state.last_warmup_at` and skips slots warmed less than 60 seconds ago. Prevents thrashing across rapid `-Watch -Auto` restarts. The state file's schema stays at `1`; the new `last_warmup_at` field is additive and missing on legacy files.
- `anthropic-version: 2023-06-01` header sent on every authenticated request (`Get-SlotUsage`, `Get-SlotProfile`, `Update-SlotTokens`). The OAuth-namespaced endpoints accept calls without it today; sending it uniformly insulates the script from a future tightening at any endpoint.

### Fixed
- Sidecar-less active slot during `-Watch -Auto` startup: the warmup pass now refuses with a one-line advisory pointing at `sca save <name>` instead of silently rotating the user onto the last peer slot.
- Ctrl-C mid-warmup: a `finally` inside the warmup orchestrator attempts to restore the original active slot before the watch loop's outer alt-screen teardown runs, so an interrupted startup does not leave `.credentials.json` on an unexpected peer.

## [2.2.1] - 2026-05-20

### Fixed
- `sca -Version` prints the version string instead of `True`, and every other action no longer emits a red `InvalidArgument` error at startup. The internal version constant collided with the `[switch] $Version` parameter; renamed to `$Script:ScriptVersion`.

## [2.2.0] - 2026-05-19

### Added
- `-Version` flag prints `$Script:Version` and exits.

### Changed
- `sca usage -Watch -Auto` title shows the pool mean across HTTP-ok slots, not the active slot.
- Pool-mean math extracted into `Get-PoolMeanUtilization`, shared by `Format-AggregateBars` and `Format-WatchTitle -Aggregate`.

## [2.1.0] - 2026-05-18

### Added
- `sca usage -Watch -Auto [-Threshold <1..100>]` auto-rotates to the next eligible slot when the active slot's utilization reaches the threshold (default 95).
- Right-aligned `▶ switching slot at N%` header indicator and latched `[Auto] …` footer line on the watch frame when `-Auto` is set.
- `Invoke-SlotSwap` extracted from `Invoke-SwitchAction` as the shared atomic swap primitive used by `sca switch` and the auto-rotation step.
- `docs/images/usage-watch-auto.svg` rendered example for the auto-mode watch frame; promoted to the README hero image.

### Changed
- `sca switch` output no longer ends with the cyan `[Info]` apply hint.
- README restructured: dashboard hoisted above the fold, watch content relocated into the Usage subsection, disclaimer blockquote-styled, Support section reframed.
- README usage screenshots rendered at a uniform 720px canvas and pinned to 1× intrinsic width via the HTML `width` attribute.

## [2.0.2] - 2026-05-03

### Added
- MIT license.
- GitHub Sponsors and Ko-fi funding via `.github/FUNDING.yml`.
- Unofficial-tool disclaimer and Anthropic-ToS discretion note in README.

### Changed
- Project canonically renamed to "Switch Claude Account". Profile-installer block markers renamed from `# === Claude Account Switcher ===` to `# === Switch Claude Account ===`. Existing installs: re-run `sca install` on the new version, then manually remove the leftover old-marker block from `$PROFILE`.

### Fixed
- `sca save` rolls back to the pre-existing slot pair when the sidecar write fails after the tokens-file write. The previous behaviour (delete-then-write) could leave the user with no slot for a name on a transient AV / disk-full / share-violation persisting past the 3-attempt retry on `Set-CredentialFileAtomic`.
- `sca usage` emits a yellow advisory pointing at `sca save` / `sca switch` when an OAuth refresh rotates tokens for the active slot but the slot's `.account.json` sidecar is missing (so `Find-SlotByName` returns null and `.credentials.json` is not updated). Previously the rotation silently desynchronised, forcing a Claude Code re-login on its next own-refresh.

## [2.0.1] - 2026-05-03

### Added
- GitHub Actions workflow `release-assets.yml` attaching `switch_claude_account.ps1` to each published release (skips pre-releases; `workflow_dispatch` fallback for backfill).
- `plan-review` skill for second-pass review of multi-step plans.
- Cross-project agent conventions: scratch-file discipline under `.tmp/sessions/<id>/`, multi-agent working-tree rules, version-control basics, em-dash punctuation rule.
- Explicit `@`-references in `CLAUDE.md` so OpenCode picks up `.claude/rules/script-internals.md` and `.claude/rules/tests.md` (Claude Code already auto-loads them).
- LF line-ending enforcement via `.gitattributes`.

### Changed
- Empty progress-bar cells render with U+2593 DARK SHADE instead of U+2591 LIGHT SHADE for cell-uniform width with U+2588 FULL BLOCK in terminal fonts.
- `sca usage -Watch` footer collapsed to a single advisory line.
- README screenshots regenerated against actual `Format-AggregateBars` and `Format-UsageTable` output; use ASCII space for empty bar cells for GitHub render alignment.
- Em-dash punctuation rule applied across docs, script, and tests; rate-limit advisory repunctuated from em dash to semicolon.
- Refreshed `pr-code-review` skill with metadata header, severity glyphs, and Pass-1 test-coverage check.
- README Download section replaced with a click-to-download link to `releases/latest/download/switch_claude_account.ps1`, which serves `Content-Disposition: attachment` via `objects.githubusercontent.com`.

### Removed
- `next in Xs` countdown footer from `sca usage -Watch`.

### Fixed
- Stale `Format-WatchTitle` prose claiming pool-mean across slots; the watch-mode title shows the active slot only.
- Unreachable `api-key / no-oauth` row in the lower README screenshot (slots without OAuth are refused at save time).

## [2.0.0] - 2026-04-26

### Added
- State file at `%USERPROFILE%\.claude\.sca-state.json` (schema v1) as the single source of truth for which slot is active; auto-migrates from 1.x installs on first read by content-hashing `.credentials.json` against existing slot files.
- Atomic-rename credential-file writes via `MoveFileEx`, surviving the share-delete handle Claude Code holds on `.credentials.json` while running. Retry policy: 3 attempts with 50 ms backoff.
- Reconcile pass that mirrors active credentials into the tracked slot or auto-saves under `auto-<UTC-timestamp>(<email>)` on cross-account swap; fires before `usage`, `switch`, and `list`.
- Active-slot OAuth-refresh propagation into `.credentials.json` with paired state-hash update, so the next reconcile no-ops.
- Identity sidecars `.credentials.<name>(<email>).account.json` capturing the slot's whitelisted `oauthAccount` snapshot at save time and restoring it to `~/.claude.json` on `sca switch`. Tokens-then-sidecar atomic-pair invariant: sidecar-write failure rolls back the tokens file.
- Identity resolution at save time reads `~/.claude.json`'s `oauthAccount` block first (offline) and falls back to `/api/oauth/profile` only when the cache is empty; both failing refuses the save.
- Targeted regex substitution into `~/.claude.json`'s `oauthAccount` block via `MatchEvaluator`, preserving every other byte (project history, mcp configs, ~50 other fields). Null-valued whitelisted fields are skipped.
- `-NoColor` flag and `NO_COLOR` env-var support via `$PSStyle.OutputRendering = 'PlainText'`.
- `Write-Color` helper routing all colored output through inline SGR codes; replaces 33 `-ForegroundColor` call sites.
- `Write-VTSequence` helper bypassing PowerShell's `StringDecorated.AnsiRegex` so DEC private modes survive regardless of `OutputRendering`.
- Flicker-free `sca usage -Watch` via DEC 2026 synchronized output mode and alternate screen buffer; pre-watch scrollback restored on Ctrl-C.
- Watch-mode terminal title via OSC 0, with `[!]` / `[~]` alarm prefix when any bucket crosses `UtilLimitPct` / `UtilWarnPct`.
- 429 cache-fallback path covering both `/api/oauth/usage` and `/v1/oauth/token`; non-429 refresh failures route through 60-char tail truncation so timeouts and 5xx no longer wrap the table.
- `is_cached_fallback` field on `-Json` rows served from cache; rate-limit advisory retitled to the endpoint-agnostic "Anthropic API rate limited".
- `[CmdletBinding()]`, parameter sets separating `-Json` from `-Watch`, and `[ValidateRange(1, [int]::MaxValue)]` on `-Interval`.
- Path-scoped agent rules under `.claude/rules/` (`script-internals.md`, `tests.md`) with per-path triggers; root `CLAUDE.md` trimmed from 390 to 122 lines.
- Pester suite: 36 new cases covering state-file atomic-rename behaviour, reconcile branches, `-NoColor` / `NO_COLOR`, watch-mode VT rendering, null-sidecar preservation, and refresh-429 / cache-fallback paths.
- `tests/Measure-Complexity.ps1` advisory AST walker reporting LOC, McCabe CC, and max nesting per function.

### Changed
- **BREAKING**: active-slot tracking moved from NTFS hardlinks to a state file. The hardlink approach was structurally fragile against Claude Code's atomic-rename token-refresh writes, which silently detached `.credentials.json` from any hardlink graph.
- **BREAKING**: `#Requires -Version` bumped from 7.0 to 7.2 for `$PSStyle.OutputRendering` support.
- **BREAKING**: synthetic `<active>` row removed from the `sca usage` data model. Reconcile guarantees the active credentials live in a real slot before rendering, so `<active>` and `<active> (unsaved)` argument aliases are no longer accepted.
- **BREAKING**: slots without a valid sidecar are hidden from `list` / `usage` / rotation and refused by `switch`. Re-running `sca save <name>` while the slot is active recaptures the sidecar.
- `sca save` and `sca switch` no longer require closing Claude Code to update `.credentials.json`, but still refuse to operate while it is running because they read/write `~/.claude.json`'s `oauthAccount` block.
- `Invoke-Reconcile` now fires on `list` as well so cross-account swaps surface in the active-marker column on the next render.
- Cross-account identity comparison uses the sidecar email as source of truth, not the filename email.
- `Invoke-RemoveAction` refuses to delete the slot tracked as active in state, and walks the raw filesystem so sidecar-less legacy slots can still be cleaned by name.
- Reset-delta rendering: `in 2h 37m` becomes `(2h 37m)`, matching the rest of the table.
- Top-level `Param` block migrated to PowerShell-idiomatic shape: PascalCase names, explicit `[Parameter(Position = …)]` for `Action` / `Name`.
- `-NoColor` flag spelled `-nocolor` for consistency with `-help` / `-json` / `-watch` / `-interval`.
- `Get-Slots` is now a thin enumerator: no per-slot SHA-256 hashing, sources `IsActive` from state, and silently sweeps leftover `.credentials.*.profile.json` cache sidecars from v1.
- README rewritten for the state-file plus sidecar model; CLAUDE.md split into root plus path-scoped rules.

### Removed
- `Test-HardlinkSupport` and its preflight call sites; non-NTFS volumes are no longer rejected.
- Synthetic-slot machinery in `Get-UsageSnapshot` / `Format-UsageFrame` and the `-SuppressAdvisory` parameter.
- Hardlink-broken / `not hardlinked to any slot` / `ActiveLocked` advisories from `sca list`.

### Fixed
- Token-refresh 429 from `/v1/oauth/token` no longer surfaces as wrapped `expired:` rows; classified via `Test-Is429` and routed through the cache-fallback path.
- Watch-mode color rendering on Windows. `Write-Host -ForegroundColor` called `SetConsoleTextAttribute` out-of-band, landing on a different channel than the buffered cell writes inside the DEC 2026 sync envelope; inline SGR codes via `Write-Color` now render correctly.
- `sca usage -Watch -nocolor` no longer flickers. `OutputRendering = 'PlainText'` was stripping DEC private modes via `StringDecorated.AnsiRegex`; `Write-VTSequence` bypasses the filter.
- `Set-OAuthAccountInClaudeJson` no longer wipes Claude Code's cached `oauthAccount` fields when the sidecar carries nulls (e.g. from the `/api/oauth/profile`-fallback save path).
- Token-sync propagation-failure advisory rewritten: now names `sca switch <slot>` as the recovery and states the realistic refresh-token rotation consequence (Claude Code's next own-refresh fails with 401).

## [1.2.0] - 2026-04-25

### Added
- `usage` action reporting live 5-hour Session and 7-day Week plan-usage percentages per slot via Anthropic's undocumented `GET /api/oauth/usage`. Auto-refreshes expired OAuth tokens against `platform.claude.com/v1/oauth/token`.
- `sca usage -watch` live self-refreshing view with 1 s redraw cadence and `-interval`-controlled polling (default and floor 60 s); refuses non-interactive output.
- `sca usage <name>` verbose single-slot view with `Account`, `Status`, `Session`, and `Week` rows including absolute local-timezone reset stamps.
- Pool-wide aggregate Session and Week progress bars rendered above the `sca usage` summary table.
- Plan-usability `Status` column (`ok`, `near limit`, `limited 5h`, `limited 7d`, `limited`, `expired`, `unauthorized`, `error: …`, `no-oauth`) derived from `UtilWarnPct = 90` and `UtilLimitPct = 100` thresholds.
- Synthetic `<active>` row when `.credentials.json` is not hardlinked to any saved slot, addressable via `sca usage '<active>'` for verbose drill-down.
- OAuth account email embedded in slot filenames as `.credentials.<slot>(<email>).json`; resolved at save time via `GET /api/oauth/profile` and rendered in a new `Account` column.
- `sca list` rebuilt as `Slot | Account` table sharing layout with `Format-UsageTable`.
- `sca switch` output rebuilt with DarkYellow header, post-switch saved-slot table, and cyan `[Info]` hint as the last line.
- 429 rate-limit resilience in `Get-SlotUsage`: per-slot in-memory cache reused with a yellow `displaying cached data` advisory.
- `(` and `)` sanitized in user-provided slot names to avoid filename-grammar ambiguity.
- `Get-UsageSnapshot` / `Format-UsageFrame` / `Invoke-UsageWatch` split: pure data, pure rendering, thin timing loop.
- Pester suite split into per-action files; total 152 in-process tests.

### Changed
- Section-title headers recolored from Yellow to DarkYellow; Yellow reserved for advisories. Green / Red / Cyan / DarkGray roles codified.
- Help screen `FILES` section emits literal `%USERPROFILE%` placeholders instead of interpolating the running user's name.
- README expanded with `usage`, `usage -watch`, aggregate-bar, Status-column, Account-column, and synth-row sections.
- `.claude/worktrees/` added to `.gitignore`.

### Fixed
- `save` no longer aborts when the `/api/oauth/profile` response carries an email with NTFS-invalid characters or when a labeled slot file is locked. Slot persists unlabeled with a yellow advisory; success line no longer claims an email label that did not land on disk.

## [1.1.0] - 2026-04-24

### Added
- `Test-HardlinkSupport` preflight for `save` and `switch` failing early on filesystems that cannot create hardlinks (FAT32, most network shares).
- `list` warns when `.credentials.json` is no longer hardlinked to any saved slot and suggests `sca switch <name>` to repair auto-sync.

### Changed
- `save` and `switch` replace `.credentials.json` with a hardlink to the named slot file instead of copying bytes; OAuth token refreshes flow into the saved slot through the shared inode.
- Slot names containing `[` or `]` are sanitized to `_`; all credential-file operations use `-LiteralPath` as defense-in-depth.
- README documents `sca switch` (no name) auto-rotation in its own subsection.

### Fixed
- `uninstall` preserves profile line endings byte-for-byte via raw regex splice instead of `Get-Content` + `-join "`r`n"`, no longer converting LF or mixed-ending profiles to CRLF.
- Test suite restores `$env:USERPROFILE` and `$global:PROFILE` in `AfterAll` so interactive `Invoke-Pester` runs do not leak the sandbox into the caller's session.

## [1.0.0] - 2026-04-23

### Added
- Single-file PowerShell switcher with `save`, `switch`, `list`, `remove`, `install`, `uninstall`, and `help` actions.
- Named credential slots stored as `.credentials.<name>.json` under `%USERPROFILE%\.claude\`.
- Auto-rotation: `sca switch` without a name rotates to the next saved slot alphabetically, wrapping.
- Help screen as default action plus `-h` / `--help` switch.
- `sca` and `switch-claude-account` aliases installed into the PowerShell profile via marker-delimited block.
- Windows filename sanitization with reserved device-name rejection (`CON`, `PRN`, `AUX`, `NUL`, `COM1-9`, `LPT1-9`).
- Profile install / uninstall preserving existing encoding (UTF-8 with or without BOM, UTF-16 LE/BE) and refusing to mutate on orphan markers.
- Pester 5 test suite (65 in-process tests) with auto-install and sandboxed `$env:USERPROFILE` / `$PROFILE.CurrentUserAllHosts` per test.
- Optional PSScriptAnalyzer advisory pass in the test runner.
- README with installation, usage, workflow, Windows notes, and testing sections.
- `CLAUDE.md` with agent guidance for repo structure, gotchas, and script-shape conventions.
