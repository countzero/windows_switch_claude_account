# CLAUDE.md

## Editing this file

- Hard ceiling: 200 lines (Anthropic guideline; longer files reduce adherence).
- Describe the **current** shape only. Rationale, design history, and "why not the alternative" prose belong in commit messages.
- When you remove a design from the code, remove its references here too.
- Per-script-only details live in `.claude/rules/script-internals.md`; test-writing conventions in `.claude/rules/tests.md`. Both are path-scoped — they auto-load only when Claude reads matching files.

## Repo structure

Single-file PowerShell tool — core logic lives in `switch_claude_account.ps1`. Tests live in `tests/` and use Pester 5.

## Key facts

- **Credential directory**: `%USERPROFILE%\.claude\`
- **Active credentials**: `.credentials.json` — written by Claude Code via atomic rename on every OAuth refresh. `sca` writes it via the same atomic-rename primitive (`Set-CredentialFileAtomic`) so the file is byte-equal to the tracked slot file after every `sca save` / `sca switch` / reconcile pass.
- **Claude Code config**: `%USERPROFILE%\.claude.json` (top-level, NOT inside `.claude\`) — Claude Code's persistent config. Its top-level `oauthAccount` block is what `/status` displays as "Email:". `sca` reads this block at save time (primary identity source) and writes the destination slot's captured `oauthAccount` back to it on `sca switch`. See "`~/.claude.json` ownership" below.
- **State file**: `%USERPROFILE%\.claude\.sca-state.json` — schema v1: `{ schema, active_slot, last_sync_hash }`. Single source of truth for "which slot is active." Read with `Read-ScaState` (auto-migrates from a 1.x install on first read by hashing `.credentials.json` against existing slot files); written via `Update-ScaState`.
- **Named slots**: `.credentials.<name>(<email>).json` (labeled) or `.credentials.<name>.json` (unlabeled, only for the dedup case where slot name equals email).
- **Identity sidecars**: `.credentials.<name>(<email>).account.json` alongside each slot file. JSON snapshot of the slot's `oauthAccount` (whitelisted: accountUuid, emailAddress, organizationUuid, displayName, organizationName) captured at save time. Restored to `~/.claude.json` on `sca switch`. **Slots without a valid sidecar are HIDDEN from `list` / `usage` / rotation and refused by `switch`** — re-running `sca save <name>` while that slot is active recaptures the sidecar.
- **PS version**: Requires PowerShell 7.2+ (`#Requires -Version 7.2`). Uses `$PROFILE.CurrentUserAllHosts` for the install target. The 7.2 floor is the version that introduced `$PSStyle.OutputRendering`, used by no-color mode.
- **Alias installer**: `sca` and `switch-claude-account` added to PowerShell profile via marker-delimited block (`# === Claude Account Switcher ===`).

## Windows-specific gotchas

- **Atomic-rename writes survive an open Claude Code (for `.credentials.json` only)**. `Set-CredentialFileAtomic` calls `[System.IO.File]::Replace` / `::Move`, both of which invoke `MoveFileEx` and succeed against the FILE_SHARE_DELETE handle Claude Code keeps on `.credentials.json`. Retry policy: 3 attempts with 50 ms backoff to absorb transient sharing violations from antivirus / indexer scanners. **`sca save` / `sca switch` still refuse to operate while Claude Code is running** — but for a different reason: they read/write `~/.claude.json`'s `oauthAccount` block, which Claude Code keeps in an in-memory cache that may flush back and clobber our update.
- **Execution policy**: May need `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` on first run.
- **Token expiry**: OAuth tokens refresh / expire after ~1 hour of inactivity. Without a daemon, the slot file is at most one Claude-Code-refresh behind the active file at any moment; the next `sca usage` or `sca switch` invocation captures the refresh into the slot via `Invoke-Reconcile`. "One refresh behind" is harmless — the slot's previous refresh_token is still valid until rotated again. `Update-SlotTokens` (called by `sca usage` when the active slot's access token is expired) propagates new tokens to BOTH the slot file AND `.credentials.json`.
- **Reconcile fires on usage and switch only** — not on `list` (pure offline render) or `remove`. Auto-migration from 1.x is silent inside `Read-ScaState`; users who haven't reconciled yet see a stale `last_sync_hash` until their first `sca usage`.
- **Cross-account swap detection**: when reconcile sees `.credentials.json` bytes differ from `state.last_sync_hash`, it identifies the live email by reading `~/.claude.json`'s `oauthAccount.emailAddress`. If the email matches the tracked slot's sidecar email, mirror through; if it differs, auto-save under `auto-<UTC-timestamp>(<new-email>)`. When `~/.claude.json` has no `oauthAccount`, falls back to a `/api/oauth/profile` HTTP call. Both probes failing falls into the same-identity mirror branch.
- **Name sanitization**: invalid Windows filename characters (`\ / : * ? " < > |` and control chars), PowerShell wildcard brackets (`[` `]`), and spaces are replaced with `_`. Brackets are sanitized because PowerShell's `-Path` parameter treats them as character-class wildcards; without sanitization, `sca remove foo[bar]` would silently wildcard-match unrelated slot files. Paired with `-LiteralPath` on every credential-file op as defense-in-depth.

## Script actions

| Action     | Requires name | What it does |
|------------|---------------|--------------|
| `save`     | Yes           | Refuses if Claude Code is running. Resolves identity from `~/.claude.json`'s `oauthAccount` (primary, offline); falls back to `/api/oauth/profile` only when the cache is empty. Both failing → refuses. Atomic-writes `.credentials.json` bytes into `.credentials.<name>(<email>).json` AND a paired `.account.json` sidecar. Updates `state.active_slot` and `state.last_sync_hash`. No reconcile prelude — explicit save IS the capture. |
| `switch`   | Optional      | Refuses if Claude Code is running. Reconciles first (so a pending refresh on the outgoing slot is captured), then atomic-writes the target slot's bytes into `.credentials.json`, then atomic-writes the destination slot's captured `oauthAccount` (whitelisted fields) into `~/.claude.json`. If `<name>` omitted, rotates to the next saved slot in alphabetical order (wraps). Refuses to activate a slot with no sidecar. |
| `list`     | No            | Renders saved slots as `Slot \| Account` table with leading active-marker column. Pure offline render — no network IO, no reconcile, no hashing. `*` marker comes from `state.active_slot`. Sidecar-less slots silently filtered out. |
| `remove`   | Yes           | Deletes a named slot AND its sidecar. Walks the raw filesystem (not `Get-Slots`) so sidecar-less legacy slots can be cleaned by name. Refuses to remove the slot tracked as active in state. |
| `usage`    | Optional      | Reconciles first, then calls Claude Code's **undocumented** `GET /api/oauth/usage` per slot for 5h / 7d plan-usage percentages. Auto-refreshes expired tokens via `Update-SlotTokens`. Accepts `-Json` for scripted output, or `-Watch` (optional `-Interval <seconds>`, floor 60) for live view. With `<name>`, renders verbose single-slot block. |
| `install`  | No            | Adds wrapper function + aliases to PowerShell profile. |
| `uninstall`| No            | Removes wrapper function + aliases from profile. |
| `help`     | No            | Shows detailed help. |

## Editing the script

The profile install/uninstall uses marker comments (`# === Claude Account Switcher ===`) to isolate its block. When modifying `Add-To-Profile` or `Remove-From-Profile`, keep these markers intact.

The top-level dispatcher is wrapped in `Invoke-Main` and guarded by `if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }` so tests can dot-source the script without triggering a live run. Each action body is extracted into an `Invoke-*Action` function so tests can call it directly. New actions: put the body in `Invoke-<Action>Action`, add a one-line dispatch to `Invoke-Main`.

The two credentials-touching actions that need a fresh slot file (`switch`, `usage`) call `Invoke-Reconcile` first; `save` skips reconcile (the explicit save IS the capture); `list` and `remove` skip reconcile too. New actions follow the same rule: reconcile only when the slot file's bytes feed downstream logic.

For color/output, table layout, watch-mode, and `/api/oauth/usage` schema details, see `.claude/rules/script-internals.md` (auto-loads when reading the script).

## Unofficial endpoints (`usage` action)

The `usage` action depends on five pinned constants extracted from `claude.exe` 2.1.119 (a Bun-compiled binary). They live at the top of `switch_claude_account.ps1` under the `# --- Unofficial /api/oauth/usage constants ---` comment:

- `$Script:UsageEndpoint`  — `https://api.anthropic.com/api/oauth/usage`
- `$Script:TokenEndpoint`  — `https://platform.claude.com/v1/oauth/token`
- `$Script:OAuthClientId`  — `9d1c250a-e61b-44d9-88ed-5944d1962f5e` (Claude.ai subscription flow)
- `$Script:AnthropicBeta`  — `oauth-2025-04-20`
- `$Script:UsageUserAgent` — `claude-code/2.1.119`

**Undocumented and unsupported by Anthropic.** When the call starts returning 4xx after a Claude Code upgrade, re-extract from `$(Get-Command claude).Source` using the grep recipe in the script header comment, bump the constants, and re-run `tests/Invoke-Tests.ps1`. The tests mock `Invoke-RestMethod` by `$Uri` and verify shape contract only — they will not catch the constants drifting out of date.

Response schema summary: `five_hour` and `seven_day` (rendered as *Session* / *Week*) carry `{ utilization: 0..100, resets_at: ISO-8601|null }`. Plus `seven_day_opus`, `seven_day_sonnet`, `extra_usage`, and internal buckets that round-trip via `-Json` but are not rendered. Full schema: `.claude/rules/script-internals.md`.

## Identity capture: filename + sidecar

A slot's identity is captured ONCE at save time and frozen in two paired files:

```
.credentials.<name>(<email>).json          ← OAuth tokens (what Claude Code reads)
.credentials.<name>(<email>).account.json  ← identity sidecar (sca-only; whitelisted oauthAccount)
```

**Identity resolution at save time** (`Invoke-SaveAction`, priority order):

1. `~/.claude.json`'s `oauthAccount` (read by `Get-OAuthAccountFromClaudeJson`) — preferred. Same source Claude Code uses for `/status`, so the slot's labeled email cannot drift from Claude Code's display by construction. Offline.
2. `/api/oauth/profile` (via `Get-SlotProfile`) — fallback for fresh installs where `oauthAccount` is empty. Yields only `emailAddress`; the other four whitelisted fields default to `null` in the sidecar.
3. Both failing → save is **refused**. There are no unlabeled-no-identity slots.

**Atomic-pair invariant**: tokens file is written first, then the sidecar. If the sidecar write fails, the tokens file is rolled back so a half-saved slot can never appear invisible-but-present.

**On-disk cleanup from v1**: `Get-Slots` silently removes any leftover `.credentials.*.profile.json` cache sidecars from the cache-based v1 implementation on each enumeration (different filename pattern from the current `.account.json` sidecar; cleanup is cheap and idempotent).

## `~/.claude.json` ownership

`~/.claude.json` is Claude Code's persistent config — `oauthAccount` at the top level alongside ~50 other fields (project history, mcp configs, statsig gates, settings). `sca` interacts with it minimally and surgically:

- **Read** (`Get-OAuthAccountFromClaudeJson`): full JSON parse via `ConvertFrom-Json`, extract whitelisted fields. Failure modes (missing, parse error, no oauthAccount, empty emailAddress) all return `$null` so callers fall through to `/api/oauth/profile` or refuse. Used by `Invoke-SaveAction` (primary identity source) and `Invoke-Reconcile` (identity probe).
- **Write** (`Set-OAuthAccountInClaudeJson`): targeted regex substitution within the `"oauthAccount": { ... }` block, NOT a full JSON round-trip. Whitelisted fields substituted via `[regex]::Replace` with a `MatchEvaluator`. Every other byte preserved. Tests assert byte-equal preservation of unrelated top-level fields. Implementation details in `.claude/rules/script-internals.md`. Used only by `Invoke-SwitchAction`.
- **Lock contract**: there is **no** lockfile. Claude Code uses `proper-lockfile` to serialize its own writes via `~/.claude.json.lock`; `sca` deliberately does NOT participate. Instead, `sca save` and `sca switch` refuse to operate when Claude Code is running (`Test-ClaudeRunning`). Stronger guarantee than locking: zero possibility of a stale in-memory cache, because Claude Code is not running to hold one.
- **Backup recovery**: Claude Code maintains rolling timestamped backups at `~/.claude.json.backup.<unix-ms>` (last 5, throttled to ≥1 minute apart). If a `sca` write ever corrupts `~/.claude.json`, restore from the latest backup. `sca` itself does NOT create backups.
- **Failure mode**: if `Set-OAuthAccountInClaudeJson` throws, `Invoke-SwitchAction` catches, prints a yellow advisory, and proceeds. The credentials swap has already happened; only the email-display update fails. Re-run the switch once the issue is fixed.

## Reconcile semantics

`Invoke-Reconcile` fires on `usage` and `switch` only (not `list`, not `remove`). Identity probe priority:

1. `Get-OAuthAccountFromClaudeJson` — preferred; offline; returns full `oauthAccount` for the auto-save sidecar.
2. `Get-SlotProfile` against `.credentials.json` — fallback. Yields only `emailAddress`.
3. Both failing → falls into the same-identity mirror branch (no auto-save).

Identity comparison: live `~/.claude.json` email vs. the tracked slot's **sidecar** `oauthAccount.emailAddress` (NOT the filename email — sidecar is the source of truth). Mismatch → auto-save under `auto-<UTC-timestamp>(<new-email>)` and update `state.active_slot`. Auto-save without identity yields a sidecar-less slot file that `Get-Slots` will hide on the next enumeration.

## Testing

```powershell
pwsh -NoProfile -File tests/Invoke-Tests.ps1
```

Run a single test or context (`-FullNameFilter` is wildcard/regex against full `Describe > Context > It` path):

```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5.0; Invoke-Pester -Path tests/ -FullNameFilter '*Get-SafeName*' -Output Detailed"
```

The runner auto-installs Pester 5 (CurrentUser scope) on first use. PSScriptAnalyzer, if installed, runs in advisory mode. Tests sandbox `$env:USERPROFILE` and `$PROFILE.CurrentUserAllHosts` per test via `$TestDrive`. Test-writing conventions: `.claude/rules/tests.md`.
