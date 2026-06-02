#Requires -Version 7.2
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Switch between multiple Claude Code accounts on Windows.

.DESCRIPTION
This script manages named credential slots for Claude Code. It saves, switches,
lists, and removes account slots by copying credentials files within the .claude
directory. Each slot is stored as a separate .credentials.<name>.json file.

.PARAMETER Action
Specifies the action to perform. Supported values are: save, switch, list, remove,
usage, install, uninstall, help.

.PARAMETER Name
Specifies the name of the credential slot. Required for save and remove.
Optional for switch: when omitted, switch rotates to the next saved slot in
alphabetical order (wrapping from the last slot back to the first). Special
characters are automatically sanitized to underscores.

.EXAMPLE
# Snapshot the currently logged-in account into a slot called "work".
.\switch_claude_account.ps1 save work

.EXAMPLE
# Restore the "personal" slot as the active Claude Code account.
.\switch_claude_account.ps1 switch personal

.EXAMPLE
# Rotate to the next saved slot (alphabetical order, wraps).
.\switch_claude_account.ps1 switch

.EXAMPLE
# Show all saved slots (the active one is marked with *).
.\switch_claude_account.ps1 list

.EXAMPLE
# Add the `sca` / `switch-claude-account` aliases to your PowerShell profile.
.\switch_claude_account.ps1 install
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param (
    [Parameter(Position = 0)]
    [ValidateSet('save', 'switch', 'list', 'remove', 'usage', 'install', 'uninstall', 'help')]
    [string] $Action,

    [Parameter(Position = 1)]
    [string] $Name,

    [switch] $Help,

    # -Json: emit the `usage` action's output as a machine-parseable JSON
    # object keyed by slot name. Ignored by other actions. Lives in its
    # own parameter set so the binder rejects -Json -Watch combinations
    # before any function body runs (Get-Help shows them as separate
    # syntax forms).
    [Parameter(ParameterSetName = 'Json')]
    [switch] $Json,

    # -Watch: render a live, self-refreshing `usage` view that polls
    # /api/oauth/usage every -Interval seconds and redraws every second
    # (so reset deltas refresh and a terminal resize is reflected within
    # ~1 s rather than at the next poll). Interactive only; exits on
    # Ctrl-C (runtime default). Mutually exclusive with -Json (enforced
    # by parameter sets). Ignored by other actions.
    # Mandatory in the 'Watch' set so it anchors the set: passing -Interval
    # alone resolves the binder to the 'Watch' set and then fails with
    # "Cannot process command because of one or more missing mandatory
    # parameters: Watch", giving an immediate diagnosis instead of silently
    # falling through to a non-watch usage call.
    [Parameter(ParameterSetName = 'Watch', Mandatory = $true)]
    [switch] $Watch,

    # -Interval: seconds between HTTP polls when -Watch is set. Bound to
    # the 'Watch' parameter set so the binder rejects -Interval without
    # -Watch (-Watch is the set's mandatory anchor; see above).
    # [ValidateRange] rejects zero / negatives at bind time. The
    # 60-second floor is enforced as a runtime clamp-with-advisory inside
    # Invoke-UsageWatch (deliberate; see CLAUDE.md "Watch mode").
    [Parameter(ParameterSetName = 'Watch')]
    [ValidateRange(1, [int]::MaxValue)]
    [int] $Interval = 60,

    # -Auto: in `sca usage -Watch -Auto`, auto-rotate to the next eligible
    # slot when the active slot's max(five_hour, seven_day) utilization
    # reaches -Threshold. Bound to the 'Watch' parameter set so the
    # binder rejects -Auto without -Watch. OpenCode-scoped (matches
    # issue #8): the opencode-claude-auth plugin re-reads .credentials.json
    # on cache miss (v1.5.4+), so rotation propagates without restarting
    # OpenCode. Claude Code's in-memory ~/.claude.json cache makes the
    # same rotation unsafe under a running Claude Code, so -Auto refuses
    # to operate while claude.exe is running (same guard as `sca switch`).
    [Parameter(ParameterSetName = 'Watch')]
    [switch] $Auto,

    # -Threshold: utilization percentage at or above which -Auto rotates.
    # Applied to max(five_hour.utilization, seven_day.utilization) on the
    # active slot; null bucket counts as 0%. Bound to the 'Watch' set so
    # the binder rejects it without -Watch. Range [1, 100]; default 95
    # leaves a small safety margin because /api/oauth/usage reporting
    # lags real consumption; rotating exactly at 100 risks overshooting
    # before the next poll lands. Ignored when -Auto is absent.
    [Parameter(ParameterSetName = 'Watch')]
    [ValidateRange(1, 100)]
    [int] $Threshold = 95,

    # -Warmup: in `sca usage -Watch`, prime every saved slot before the
    # first poll. For each slot in alphabetical order, Invoke-WarmAllSlots
    # makes the slot active (Invoke-SlotSwap) then sends a minimal
    # billable /v1/messages request (Invoke-SlotPrime) so Anthropic opens
    # a server-side 5h session window for the slot. Subsequent
    # /api/oauth/usage polls then return real bucket data instead of
    # empty/rate-limited responses. Cost: ~2 tokens per slot per warmup
    # on the pinned Haiku model (fractions of a cent). Bound to the
    # 'Watch' parameter set so the binder rejects -Warmup without
    # -Watch. Independent of -Auto: works with bare -Watch and with
    # -Watch -Auto. The pre-loop Test-ClaudeRunning guard refuses to
    # operate when Claude Code is running because the per-slot swap
    # writes ~/.claude.json's oauthAccount, which Claude Code keeps in
    # an in-memory cache.
    [Parameter(ParameterSetName = 'Watch')]
    [switch] $Warmup,

    # -NoColor: suppress all ANSI color output for this invocation. We
    # implement no-color via two cooperating pieces:
    #   1. The `Write-Color` helper wraps every colored message string
    #      with inline ANSI SGR codes (NOT the legacy -ForegroundColor
    #      attribute path, which is structurally broken on Windows for
    #      this purpose -- see the helper's docstring for the full
    #      mechanism).
    #   2. A single `$PSStyle.OutputRendering = 'PlainText'` toggle in
    #      Invoke-Main: PowerShell's `WriteImpl` -> `GetOutputString`
    #      then strips inline SGR codes from every Write-Host message
    #      before they reach stdout, so the terminal sees plain text.
    # Precedence: -NoColor flag > $env:NO_COLOR non-empty > default colored.
    # NO_COLOR (https://no-color.org) is honored as the de facto industry
    # standard for opting out of colors without per-invocation flags.
    # Watch mode's alt-buffer / sync-mode / clear-screen / cursor-home VT
    # sequences are message bytes (not SGR), so they remain unaffected --
    # watch mode keeps working in B&W; only color tinting is suppressed.
    [switch] $NoColor,

    # -Version: print the script version ($Script:ScriptVersion) and exit
    # before any action runs. Lives outside the 'Json' / 'Watch' parameter
    # sets so it participates in __AllParameterSets and composes with
    # -NoColor (and with any positional Action, which it short-circuits
    # past). Note: `-V` is ambiguous (prefix-matches both -Version and
    # -Verbose from CmdletBinding), so the shortest unambiguous prefix is
    # `-Versi`. The internal storage variable is $Script:ScriptVersion
    # (NOT $Script:Version): a [switch]-typed parameter named $Version
    # would shadow $Script:Version and silently coerce the string
    # assignment to a boolean.
    [switch] $Version
)

# We are resolving the script path to reference this file when
# installing the alias into the user's PowerShell profile.
$ScriptPath     = (Resolve-Path $PSCommandPath).Path
$CredDir        = Join-Path $env:USERPROFILE ".claude"
$CredFile       = Join-Path $CredDir ".credentials.json"
$StateFile      = Join-Path $CredDir ".sca-state.json"
# Claude Code's persistent config (top-level dotfile, NOT inside .claude/).
# We read its `oauthAccount` block as the authoritative identity source
# (it's what /status displays) and write whitelisted identity fields back
# at switch time so Claude Code's display follows the active slot.
$ClaudeJsonPath = Join-Path $env:USERPROFILE ".claude.json"
$ProfilePath    = $PROFILE.CurrentUserAllHosts

# Version of this script. Bumped in the same commit that adds the matching
# CHANGELOG.md release section and the git tag (vX.Y.Z) so `sca -Version`
# matches the tag for users who downloaded the standalone .ps1 from the
# GitHub release asset and have no git context. A Helpers.Tests.ps1 case
# cross-checks this string against the most recent CHANGELOG section header.
# Named $Script:ScriptVersion (not $Script:Version) to avoid colliding with
# the [switch] $Version parameter declared above: a same-named parameter
# enforces its [switch] type on every assignment to the script-scope
# variable, silently coercing this string to $true.
$Script:ScriptVersion = '2.3.0'

# Marker constants delimiting the block we manage in the user's profile.
# Kept at script scope so both Add-To-Profile and Remove-From-Profile share
# a single source of truth.
$MarkerStart = "# === Switch Claude Account ==="
$MarkerEnd   = "# === End Switch Claude Account ==="

# --- Unofficial Claude Code OAuth-flow constants ---
#
# These values power the `usage` action, which replicates the live 5h /
# 7d rate-limit read that Claude Code's own `/usage` slash command
# performs. Extracted from claude.exe 2.1.119 (a Bun-compiled binary
# that embeds the JS source) by string-scanning the file.
#
# These endpoints are UNDOCUMENTED and unsupported by Anthropic. Expect
# them to break when Anthropic bumps the beta flag, rotates the OAuth
# client id, or reshapes the response body. To re-extract after an
# upstream change, from a PowerShell 7 prompt:
#
#   $bin   = (Get-Command claude -ErrorAction Stop).Source
#   $bytes = [IO.File]::ReadAllBytes($bin)
#   $text  = [Text.Encoding]::ASCII.GetString($bytes)
#   # Usage endpoint path:    $text | Select-String '/api/oauth/usage'
#   # Profile endpoint path:  $text | Select-String '/api/oauth/profile' (function Ql)
#   # Base API URL + TOKEN_URL + CLIENT_ID: Select-String 'TOKEN_URL:"'
#   # Beta header value:      Select-String 'lj="oauth-'
#   # API version header:     Select-String 'anthropic-version'
#   # UA version convention:  Select-String 'claude-code/\$\{'
#
# The client id below is the Claude.ai subscription flow's client id
# (matches the `user:sessions:claude_code` scope slot files carry); the
# other client id in the binary (22422756-...) is for the Console API-key
# flow and does not accept our refresh tokens.
$Script:UsageEndpoint       = "https://api.anthropic.com/api/oauth/usage"
$Script:ProfileEndpoint     = "https://api.anthropic.com/api/oauth/profile"
$Script:MessagesEndpoint    = "https://api.anthropic.com/v1/messages"
$Script:TokenEndpoint       = "https://platform.claude.com/v1/oauth/token"
$Script:OAuthClientId       = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
$Script:AnthropicBeta       = "oauth-2025-04-20"
# anthropic-version: sent on every authenticated request for defense-in-
# depth. The OAuth-namespaced endpoints (/api/oauth/usage, /api/oauth/
# profile, /v1/oauth/token) accept calls without it today, but if
# Anthropic later tightens any of them the script keeps working without
# an emergency patch. Pinned to the stable 2023-06-01 API version that
# Claude Code itself ships with.
$Script:AnthropicApiVersion = "2023-06-01"
$Script:UsageUserAgent      = "claude-code/2.1.119"
$Script:UsageTimeoutSec     = 5
$Script:ProfileTimeoutSec   = 10
# Priming model + timeout for Invoke-SlotPrime. /v1/messages accepts the
# claudeAiOauth bearer when paired with the same anthropic-beta header
# the OAuth-namespaced endpoints use; the OAuth client flow is allowed
# to call the standard messages API. Pin Haiku as the cheapest current
# model so each prime costs ~2 tokens (1 in, 1 out). Drifts when
# Anthropic deprecates the pinned model id; same maintenance recipe as
# the constants above. /v1/messages can be slower than /api/oauth/usage
# (model load on cold path), so the timeout is more generous than
# $UsageTimeoutSec. Model identifier MUST be JSON-safe (no quotes /
# backslashes): Invoke-SlotPrime inlines it into a format-string body
# without escaping. All Anthropic model identifiers to date are
# `[a-z0-9-]+` so this is a non-issue in practice.
$Script:PrimeModel          = "claude-haiku-4-5"
$Script:PrimeTimeoutSec     = 15

# Retry policy for /v1/oauth/token on a 429 response. Empirically the
# refresh endpoint's per-token rate limiter has a short cooldown
# (~seconds): a slot whose access token expired days ago is "stuck"
# only until one retry slips through. Three total attempts with
# exponential backoff (2 s, then 4 s) gives a ~6 s worst-case extra
# latency per stuck slot, which the watch loop absorbs inside the 60 s
# poll cadence. Without retry the same slot showed `rate-limited`
# every poll until the user happened to invoke another sca command
# during the brief unlock window; the retry collapses that gap.
# Tunable for tests (Pester overrides them to zero so mocked 429 paths
# run instantly).
$Script:TokenRefreshRetryMax     = 3
$Script:TokenRefreshRetryDelayMs = 2000

# Cache of the last successful /api/oauth/usage response per slot path.
# Used as a fallback when the endpoint returns 429 (rate limited) so the
# watch display stays functional during rate-limited periods. Entries
# expire after $Script:UsageCacheTTL minutes.
$Script:SlotUsageCache = @{}
$Script:UsageCacheTTL  = 10

# Plan-usability thresholds used by Get-PlanStatus / Format-UsageTable /
# Format-UsageVerbose. The Status column on the usage table mixes HTTP
# health (expired / unauthorized / error / no-oauth) with plan-state
# derived from these two thresholds:
#
#   util < UtilWarnPct                   -> 'ok'         (green if active, gray otherwise)
#   UtilWarnPct  <= util < UtilLimitPct  -> 'near limit' (yellow)
#   UtilLimitPct <= util (5h only)       -> 'limited 5h' (red; slot cannot serve prompts until 5h reset)
#   UtilLimitPct <= util (7d only)       -> 'limited 7d' (red)
#   UtilLimitPct <= util (both)          -> 'limited'    (red)
#
# 100% is the hard cap enforced by Anthropic; 90% is the heads-up tier.
# Keep these as script-scope constants so tests can reason about the
# thresholds without duplicating magic numbers.
$Script:UtilWarnPct            = 90
$Script:UtilLimitPct           = 100

# Color thresholds for the aggregate progress bars rendered above the
# usage table. The bars show pool-wide USAGE (sum of utilization across
# HTTP-ok slots divided by N*100, equivalently the mean utilization
# across eligible rows), so the thresholds align with the per-slot
# UtilWarn/UtilLimit semantics above (in spirit, not in value -- pool
# aggregates flip to red sooner because one fully-burned slot in a
# multi-slot pool barely moves the aggregate):
#
#   usedPct >= AggregateRedPct      -> Red     (pool nearly exhausted)
#   usedPct >= AggregateYellowPct   -> Yellow  (half or more burned)
#   otherwise                       -> Green
#
# Red anchored to UtilWarnPct (90) so 'red' carries the same near-cap
# meaning at per-slot and pool scale; pure 100% would be a knife-edge
# transition that fires only after the pool is already exhausted.
# Yellow at the half-burned mark.
$Script:AggregateRedPct        = 90
$Script:AggregateYellowPct     = 50

# Middle-truncation target for the Account column in the usage table.
# Emails longer than this get rendered as `aaa…zzz` with an ellipsis in
# the middle so the domain (which disambiguates accounts under the same
# local-part) stays visible. The verbose `sca usage <name>` view and
# `-Json` output always carry the full email.
$Script:AccountColumnMaxWidth  = 32

# --- State file + atomic credential-file write primitives -----------------
#
# `sca` tracks the currently-active slot in $StateFile (a small JSON
# document) rather than relying on inode equality between .credentials.json
# and a saved slot file. This is robust against Claude Code's atomic-rename
# token-refresh writes, which previously broke the hardlink and silently
# detached .credentials.json from any tracked slot.
#
# Schema v1:
#   { "schema": 1, "active_slot": "<name>"|null, "last_sync_hash": "<sha256>"|null }
#
# Concurrent writes: every write goes through Set-CredentialFileAtomic,
# which is atomic on NTFS. Two concurrent updates -> last writer wins;
# the loser's changes are silently dropped. Acceptable for an interactive
# tool that is rarely (and never deliberately) invoked in parallel.

# Atomic temp-file-plus-rename write of $Bytes to $Path. The single write
# primitive used by every credential-shaped file (.credentials.json, slot
# files, .sca-state.json).
#
# Why atomic-rename rather than truncate-and-write: Claude Code keeps
# .credentials.json open with FILE_SHARE_DELETE while running, and the
# only Windows write path that succeeds against an open-but-share-delete
# handle is `MoveFileEx` / `ReplaceFile` (the Win32 primitives behind
# [System.IO.File]::Move / ::Replace). A plain Set-Content / Out-File
# would fail with a sharing violation while Claude Code is running.
#
# Side effect: the destination always becomes a fresh inode after Replace.
# We accept this; the script no longer relies on hardlinks for any
# auto-sync property; the state file tracks the active slot instead.
#
# Retry: up to 3 attempts on transient sharing violations with 50 ms
# backoff. Persistent failure throws after the final attempt; the temp
# file is cleaned up in the finally block whether we succeeded or not
# (Replace consumes the temp on success so Test-Path is false there).
function Set-CredentialFileAtomic {
    Param (
        [Parameter(Mandatory)] [String] $Path,
        # AllowEmptyCollection so callers can write a zero-byte placeholder
        # without tripping PowerShell's mandatory-collection guard. Real
        # credential / state writes are always non-empty, but defensive
        # callers (and tests) shouldn't have to special-case zero-length.
        [Parameter(Mandatory)] [AllowEmptyCollection()] [byte[]] $Bytes
    )

    # Random suffix lets two concurrent writes coexist safely: each picks
    # its own tmp name, the rename then serializes at the destination.
    $tmp = "$Path.sca-tmp.$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $maxAttempts = 3

    try {
        [System.IO.File]::WriteAllBytes($tmp, $Bytes)

        $lastErr = $null
        for ($i = 1; $i -le $maxAttempts; $i++) {
            try {
                if (Test-Path -LiteralPath $Path) {
                    # [NullString]::Value passes a real .NET null; a bare $null
                    # would be coerced to "" by PowerShell's argument binder
                    # and Replace would reject it as an invalid backup path.
                    [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
                } else {
                    [System.IO.File]::Move($tmp, $Path)
                }
                return
            }
            catch [System.IO.IOException] {
                $lastErr = $_
                if ($i -lt $maxAttempts) {
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        throw $lastErr
    }
    finally {
        # Cleanup on failure path. Success path leaves $tmp consumed by
        # Replace/Move so Test-Path is already false here.
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

# Persist $State to $StateFile via atomic rename. The schema field is
# enforced to 1 here so callers cannot accidentally write a stale or
# missing version. last_sync_hash and active_slot may be $null (initial
# state where reconcile has not yet captured any sync).
function Write-ScaState {
    Param (
        [Parameter(Mandatory)] [psobject] $State
    )

    $payload = [ordered]@{
        schema         = 1
        active_slot    = $State.active_slot
        last_sync_hash = $State.last_sync_hash
    }
    $json  = $payload | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    Set-CredentialFileAtomic -Path $StateFile -Bytes $bytes
}

# Load the state file. Returns a [pscustomobject] with .schema /
# .active_slot / .last_sync_hash on success, or $null when the file is
# missing, unreadable, or schema-incompatible.
#
# Auto-migration: when no state file exists AND .credentials.json exists,
# this function attempts to identify the active slot by hashing every
# slot file for a content match (mirrors the pre-state-file IsActive
# computation). On a hit, it persists the fresh state and returns it. On
# a miss it returns $null and Invoke-Reconcile (the only caller that
# acts on the null branch) auto-saves the unidentified bytes under a
# generated name. Other callers tolerate $null gracefully: Invoke-
# RemoveAction's active-slot guard short-circuits when state is null;
# Invoke-ListAction reconciles before reading state, so by then the
# state has been bootstrapped.
#
# Legacy field tolerance: state files written by v2.3.0 - v2.4.0-draft
# carry a `last_warmup_at` field. We parse the file unchanged but
# silently ignore the field; the next state-mutating write drops it.
# This is one-way: a downgrade to an older script reading our
# field-less file works because v2.3.0's Read-ScaState defaults the
# field to @{} when absent.
#
# Errors are swallowed so a corrupt state file or a transient migration
# write failure does not break the tool; the next state-mutating call
# rewrites it.
function Read-ScaState {
    if (Test-Path -LiteralPath $StateFile) {
        try {
            $raw = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($obj.schema -ne 1) { return $null }
            return [pscustomobject]@{
                schema         = [int]$obj.schema
                active_slot    = if ($obj.active_slot)    { [string]$obj.active_slot }    else { $null }
                last_sync_hash = if ($obj.last_sync_hash) { [string]$obj.last_sync_hash } else { $null }
            }
        }
        catch {
            return $null
        }
    }

    # No state file. Try to bootstrap by hash-matching .credentials.json
    # against existing slot files (transparent upgrade for users coming
    # from the hardlink-based version).
    if (-not (Test-Path -LiteralPath $CredFile)) { return $null }
    try {
        $activeHash = Get-SHA256Hex -Path $CredFile
    }
    catch {
        return $null
    }

    # Exclude `.account.json` sidecars (introduced in v2.1.0); they
    # match the wildcard but are not credential files. Without this
    # filter the auto-migration could hash a sidecar and never find
    # a match (harmless), but still wastes I/O and is a defensive
    # cleanup against future bugs.
    $files = Get-ChildItem -LiteralPath $CredDir -Filter '.credentials.*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.credentials.json' -and $_.Name -notlike '*.account.json' }
    foreach ($f in $files) {
        $parsed = Get-SlotFileInfo -FileName $f.Name
        if (-not $parsed) { continue }
        try {
            if ((Get-SHA256Hex -Path $f.FullName) -eq $activeHash) {
                $state = [pscustomobject]@{
                    schema         = 1
                    active_slot    = $parsed.Name
                    last_sync_hash = $activeHash
                }
                # Persist the migration so subsequent reads are O(1).
                # Failure here is non-fatal; callers see correct behavior
                # for this call and the migration retries on the next read.
                try { Write-ScaState -State $state } catch { Write-Verbose "ScaState migration write deferred: $_" }
                return $state
            }
        }
        catch { continue }
    }
    return $null
}

# Read-modify-write helper. Pass any subset of -ActiveSlot / -LastSyncHash;
# parameters not bound are left at their current state-file value (or null
# when no state file existed). -ClearActiveSlot wins over -ActiveSlot in
# the unusual case both are bound, so callers expressing "forget the
# active slot" cannot accidentally re-set it.
function Update-ScaState {
    Param (
        [String] $ActiveSlot,
        [String] $LastSyncHash,
        [switch] $ClearActiveSlot
    )

    $current = Read-ScaState
    if (-not $current) {
        $current = [pscustomobject]@{
            schema         = 1
            active_slot    = $null
            last_sync_hash = $null
        }
    }

    if ($PSBoundParameters.ContainsKey('ActiveSlot'))   { $current.active_slot    = $ActiveSlot }
    if ($PSBoundParameters.ContainsKey('LastSyncHash')) { $current.last_sync_hash = $LastSyncHash }
    if ($ClearActiveSlot)                               { $current.active_slot    = $null }

    Write-ScaState -State $current
    return $current
}

# --- ~/.claude.json identity bridge ---------------------------------------
#
# Claude Code keeps `oauthAccount` (accountUuid, emailAddress, organizationUuid,
# displayName, organizationName, plus billing/trial metadata) in a top-level
# `~/.claude.json` config file. The /status screen's "Email:" line reads
# `oauthAccount.emailAddress` from this cache; the cache is populated once at
# login (from /api/oauth/profile) and is NOT refreshed on subsequent token
# refreshes (see binary RE in CLAUDE.md). This file is therefore the single
# authoritative source of "what email is Claude Code displaying right now."
#
# sca uses ~/.claude.json two ways:
#   1. READ (sca save / reconcile identity probe): the email Claude Code
#      shows IS what we want to label slots with. Drift between sca and
#      Claude Code becomes structurally impossible.
#   2. WRITE (sca switch): we copy the destination slot's captured oauthAccount
#      block back into ~/.claude.json so Claude Code's display follows the
#      active slot across switches.
#
# Writing is gated by Test-ClaudeRunning: Claude Code holds ~/.claude.json
# in an in-memory cache (Un.config) that is not auto-invalidated on external
# changes, and a flush from a running Claude Code instance would silently
# overwrite our oauthAccount mutation. Refuse-while-running is the chosen
# mitigation; see decision (2) in CLAUDE.md's planning history.

# Returns $true if any process named 'claude' is running on the host.
# Get-Process enumerates processes from ALL users on the system (limited
# detail for processes owned by other users, but the Process objects
# themselves still come back), so this refuses save/switch even when a
# DIFFERENT user on a shared Windows host has Claude Code open. That is
# intentional multi-user safety: if any user's Claude Code holds the
# ~/.claude.json in-memory cache, our oauthAccount mutation could race
# its flush. Wrapped as a function so tests can mock it without driving
# real process state.
function Test-ClaudeRunning {
    return [bool](Get-Process -Name 'claude' -ErrorAction SilentlyContinue)
}

# Read Claude Code's `oauthAccount` block out of ~/.claude.json. Returns a
# pscustomobject with the whitelisted identity fields when the file exists,
# parses, and contains a populated oauthAccount.emailAddress; otherwise $null.
#
# Whitelist (these are the fields that determine identity; volatile metadata
# like billingType / trial dates is intentionally not surfaced: it changes
# over time and should not round-trip through sca):
#   accountUuid, emailAddress, organizationUuid, displayName, organizationName
#
# Failure modes (all -> $null, never throws):
#   * file missing                     (fresh install / Claude Code never run)
#   * file unparseable                 (corrupt JSON; Claude Code probably broken too)
#   * no oauthAccount key              (logged out / API-key-only mode)
#   * oauthAccount.emailAddress empty  (incomplete cache; treat as no identity)
function Get-OAuthAccountFromClaudeJson {
    if (-not (Test-Path -LiteralPath $ClaudeJsonPath)) { return $null }

    try {
        $obj = Get-Content -LiteralPath $ClaudeJsonPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    if (-not $obj.oauthAccount) { return $null }
    $oa = $obj.oauthAccount
    if ([string]::IsNullOrWhiteSpace([string]$oa.emailAddress)) { return $null }

    return [pscustomobject]@{
        accountUuid      = if ($oa.accountUuid)      { [string]$oa.accountUuid }      else { $null }
        emailAddress     = [string]$oa.emailAddress
        organizationUuid = if ($oa.organizationUuid) { [string]$oa.organizationUuid } else { $null }
        displayName      = if ($oa.displayName)      { [string]$oa.displayName }      else { $null }
        organizationName = if ($oa.organizationName) { [string]$oa.organizationName } else { $null }
    }
}

# JSON-encode a string value. Returns the value with surrounding double
# quotes and standard JSON escapes applied (\\ \" \n \r \t \b \f). Used by
# Set-OAuthAccountInClaudeJson to substitute new field values into the
# raw JSON text without depending on PowerShell's JSON serializer (which
# would re-format the entire 18 KB+ config file and risk drift).
function ConvertTo-ScaJsonString {
    Param ([AllowEmptyString()] [AllowNull()] [string] $Value)
    if ($null -eq $Value) { return 'null' }
    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped.Replace("`b", '\b').Replace("`f", '\f').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t')
    return '"' + $escaped + '"'
}

# Compute SHA-256 of bytes (or a file's bytes) as uppercase hex with no
# separators. This format matches Get-FileHash's .Hash output exactly,
# which is the implicit invariant that state.last_sync_hash equality
# depends on: callers may produce a hash here from in-memory bytes
# during a save / switch / refresh, and Read-ScaState's auto-migration
# may produce a hash here from a slot file on disk. Both code paths
# need to compare equal byte-for-byte. Centralizing the format in one
# helper makes that contract enforced rather than convention.
function Get-SHA256Hex {
    [CmdletBinding(DefaultParameterSetName = 'Bytes')]
    Param (
        [Parameter(Mandatory, ParameterSetName = 'Bytes', Position = 0)]
        [byte[]] $Bytes,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [String] $Path
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $Bytes = [System.IO.File]::ReadAllBytes($Path)
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try   { return [BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '' }
    finally { $sha.Dispose() }
}

# Replace the whitelisted identity fields inside ~/.claude.json's
# oauthAccount block, leaving every other top-level field byte-equal.
#
# Strategy: locate the `"oauthAccount": { ... }` block by brace-counting,
# then substitute each whitelisted "field": "value" pair within the block
# via a single regex replace. The non-whitelisted fields (billingType,
# claudeCodeTrialEndsAt, etc.) inside oauthAccount are also preserved
# byte-equal; we only touch the five identity fields.
#
# Null-valued whitelisted fields are skipped (they preserve the existing
# ~/.claude.json value). The asymmetry is deliberate: null → real
# (upgrading a previously-null cached field to a populated value) still
# works because the substituted value is non-null; real → null (which
# would wipe Claude Code's cached identity when the sidecar carries the
# /api/oauth/profile-fallback's null defaults) is blocked.
#
# Pre-flight test (CLAUDE.md history) verified this approach: editing
# emailAddress and restarting Claude Code makes /status report the new
# value, and the rest of the file round-trips byte-equal.
#
# Errors:
#   * file missing                  -> throw
#   * oauthAccount block missing    -> throw
#   * unbalanced braces in block    -> throw (never seen in practice;
#                                            indicates a corrupt file
#                                            and we refuse to touch it)
function Set-OAuthAccountInClaudeJson {
    Param ([Parameter(Mandatory)] [pscustomobject] $OAuthAccount)

    if (-not (Test-Path -LiteralPath $ClaudeJsonPath)) {
        throw "~/.claude.json not found at '$ClaudeJsonPath'. Sign in to Claude Code first ('claude /login')."
    }

    $raw = Get-Content -LiteralPath $ClaudeJsonPath -Raw -ErrorAction Stop

    # Locate the opening `"oauthAccount": {`. We accept whitespace variations
    # because Claude Code's serializer indents with 2 spaces but a hand-edited
    # file might have different whitespace; we tolerate that.
    $startMatch = [regex]::Match($raw, '"oauthAccount"\s*:\s*\{')
    if (-not $startMatch.Success) {
        throw "~/.claude.json has no oauthAccount block. Sign in to Claude Code first."
    }

    # Brace-count from the opening { to find the matching close. Naive
    # counter; does NOT track string-literal context. Per RFC 8259, JSON
    # strings may legally contain unescaped `{` and `}`; only `"`, `\`,
    # and U+0000-U+001F must be escaped. So this counter would miscount
    # an oauthAccount value like `"organizationName": "Acme {LLC}"`.
    #
    # Why this is acceptable in practice (NOT by JSON-spec construction):
    #   * Of the five whitelisted identity fields, three are UUIDs and
    #     one is an RFC 5321 email; none can contain `{` / `}`.
    #   * `displayName` / `organizationName` are user-set in Anthropic's
    #     console, but braces in those values are vanishingly rare.
    #   * Non-whitelisted oauthAccount fields Claude Code emits today
    #     (billingType enum, ISO timestamps, booleans, `ccOnboardingFlags`
    #     nested object) cannot contain string-literal `}`; nested
    #     object close-braces ARE real structural braces and counted
    #     correctly.
    #   * If a future Claude Code field with brace-bearing string content
    #     trips this, ~/.claude.json may be corrupted; recovery is via
    #     Claude Code's own `~/.claude.json.backup.<unix-ms>` rolling
    #     backups (last 5 retained).
    # If this assumption ever stops holding (e.g., Anthropic adds a free-
    # form notes field), upgrade this to a string-literal-aware scanner.
    $openBrace = $startMatch.Index + $startMatch.Length - 1
    $depth = 1
    $i = $openBrace + 1
    while ($i -lt $raw.Length -and $depth -gt 0) {
        $ch = $raw[$i]
        if     ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') { $depth-- }
        $i++
    }
    if ($depth -ne 0) {
        throw "~/.claude.json oauthAccount block has unbalanced braces; refusing to write."
    }
    # $i now points just past the closing `}`. The block text spans
    # [openBrace .. i), inclusive of both braces.
    $blockText = $raw.Substring($openBrace, $i - $openBrace)

    $whitelist = @('accountUuid', 'emailAddress', 'organizationUuid', 'displayName', 'organizationName')
    $newBlock  = $blockText
    foreach ($field in $whitelist) {
        if (-not $OAuthAccount.PSObject.Properties[$field]) { continue }
        $value = $OAuthAccount.$field
        # Skip null values: preserve the existing ~/.claude.json field rather
        # than nulling it out. This handles /api/oauth/profile-fallback
        # sidecars that captured only emailAddress (the other four
        # whitelisted fields default to $null in that path). The asymmetry
        # is deliberate: a null value carries no information about Claude
        # Code's actual identity, so the existing cached value is the better
        # source of truth. The inverse direction (null → real, upgrading a
        # previously-null cache to a populated value) still works because
        # the new value is non-null and falls through to the substitution
        # below.
        if ($null -eq $value) { continue }
        # Field-pattern: `"name": "<any-string-or-null>"`. The capture
        # accepts both quoted strings and the bare `null` literal so a
        # null-valued cached field can be replaced with a real value.
        $pattern = '"' + [regex]::Escape($field) + '"\s*:\s*("(?:[^"\\]|\\.)*"|null)'
        $rx = [regex]::new($pattern)

        $encoded = ConvertTo-ScaJsonString $value
        # MatchEvaluator avoids `$1` / `$&` regex-replacement-token
        # surprises if the JSON-encoded value happens to contain `$`.
        $replacement = '"' + $field + '": ' + $encoded
        $newBlock = $rx.Replace($newBlock, [System.Text.RegularExpressions.MatchEvaluator] {
            Param ($m)
            return $replacement
        }, 1)
    }

    if ($newBlock -eq $blockText) { return }  # no-op write

    $newRaw = $raw.Substring(0, $openBrace) + $newBlock + $raw.Substring($i)
    Set-CredentialFileAtomic -Path $ClaudeJsonPath -Bytes ([System.Text.Encoding]::UTF8.GetBytes($newRaw))
}

# --- Per-slot identity sidecar -------------------------------------------
#
# Each slot has a sidecar `.account.json` file alongside its credentials
# file that captures the slot's frozen identity at save time:
#
#   .credentials.<name>(<email>).json         <- tokens (what Claude Code reads)
#   .credentials.<name>(<email>).account.json <- identity sidecar (sca-only)
#
# Claude Code never reads the sidecar; it's purely sca state. The sidecar
# is the authoritative source for switching: when sca switches, the
# captured oauthAccount is written back into ~/.claude.json so Claude
# Code's display follows. The slot filename's email and the sidecar's
# emailAddress agree by construction (save writes both atomically).
#
# Slots without a valid sidecar are HIDDEN from list/usage/rotation and
# refused by switch; there is no migration path from old states.
# Re-running `sca save <name>` while that slot is active recaptures the
# sidecar, making the slot visible again.

# Map a slot credentials file path to its sidecar path.
function Get-SidecarPath {
    Param ([Parameter(Mandatory)] [string] $SlotPath)
    return $SlotPath -replace '\.json$', '.account.json'
}

# Read the sidecar JSON for a slot. Returns a pscustomobject with the
# parsed contents, or $null if the sidecar is missing, unparseable, or
# fails the schema/email shape check.
function Read-Sidecar {
    Param ([Parameter(Mandatory)] [string] $SlotPath)

    $sidecarPath = Get-SidecarPath -SlotPath $SlotPath
    if (-not (Test-Path -LiteralPath $sidecarPath)) { return $null }

    try {
        $obj = Get-Content -LiteralPath $sidecarPath -Raw -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }

    if ($obj.schema -ne 1) { return $null }
    if (-not $obj.oauthAccount) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$obj.oauthAccount.emailAddress)) { return $null }
    return $obj
}

# Atomic-write a sidecar for the given slot path. Source is informational:
# 'claude_json' when oauthAccount came from ~/.claude.json (preferred),
# 'api_profile' when it came from /api/oauth/profile (fallback), 'test'
# in tests, etc. captured_at is informational for diagnostics.
function Write-Sidecar {
    Param (
        [Parameter(Mandatory)] [string]       $SlotPath,
        [Parameter(Mandatory)] [pscustomobject] $OAuthAccount,
        [string] $Source = 'claude_json'
    )

    $payload = [ordered]@{
        schema       = 1
        captured_at  = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        source       = $Source
        oauthAccount = [ordered]@{
            accountUuid      = $OAuthAccount.accountUuid
            emailAddress     = $OAuthAccount.emailAddress
            organizationUuid = $OAuthAccount.organizationUuid
            displayName      = $OAuthAccount.displayName
            organizationName = $OAuthAccount.organizationName
        }
    }
    $json  = $payload | ConvertTo-Json -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Set-CredentialFileAtomic -Path (Get-SidecarPath -SlotPath $SlotPath) -Bytes $bytes
}

# Best-effort sidecar deletion. Silent on missing file.
function Remove-Sidecar {
    Param ([Parameter(Mandatory)] [string] $SlotPath)
    $sidecarPath = Get-SidecarPath -SlotPath $SlotPath
    if (Test-Path -LiteralPath $sidecarPath) {
        Remove-Item -LiteralPath $sidecarPath -Force -ErrorAction SilentlyContinue
    }
}

# We are detecting the profile file's encoding so install/uninstall can
# preserve it. Without this, reading a UTF-16 profile as UTF-8 corrupts
# the content on rewrite. Files without a BOM are treated as utf8NoBOM
# per PowerShell 7 convention; ANSI-encoded profiles are indistinguishable
# from utf8NoBOM without a BOM and are out of scope.
function Get-ProfileEncoding {
    Param ([String] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 'utf8NoBOM' }

    $buf    = New-Object byte[] 4
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $n = $stream.Read($buf, 0, 4)
    }
    finally {
        $stream.Dispose()
    }

    if ($n -ge 3 -and $buf[0] -eq 0xEF -and $buf[1] -eq 0xBB -and $buf[2] -eq 0xBF) { return 'utf8BOM' }
    if ($n -ge 2 -and $buf[0] -eq 0xFF -and $buf[1] -eq 0xFE)                      { return 'unicode' }
    if ($n -ge 2 -and $buf[0] -eq 0xFE -and $buf[1] -eq 0xFF)                      { return 'bigendianunicode' }

    return 'utf8NoBOM'
}

# We are rendering a compact, locale-independent help screen so the
# user always sees the same layout regardless of Windows UI language.
function Show-Help {
    $cmd = if (Get-Alias -Name sca -ErrorAction SilentlyContinue) { "sca" } else { ".\switch_claude_account.ps1" }

    $lines = @(
        "",
        "Switch Claude Account - manage multiple Claude Code logins on Windows.",
        "",
        "USAGE",
        "  $cmd <action> [name]",
        "",
        "ACTIONS",
        "  save <name>      Snapshot the active login into a named slot",
        "  switch [name]    Restore a named slot; without <name>, rotate to the next slot (alphabetical, wraps)",
        "  list             List saved slots (active slot marked with *)",
        "  remove <name>    Delete a named slot",
        "  usage [name]     Show Session / Week plan usage per slot (network; unofficial Anthropic API)",
        "  install          Add 'sca' + 'switch-claude-account' aliases to your PS profile",
        "  uninstall        Remove the aliases from your PS profile",
        "  help, -h         Show this help",
        "",
        "OPTIONS",
        "  -NoColor         Suppress all ANSI color output (also: set NO_COLOR env var)",
        "  -Version         Print the script version and exit",
        "",
        "EXAMPLES",
        "  $cmd save slot-1                       # save current login as 'slot-1'",
        "  $cmd switch slot-2                     # activate the 'slot-2' slot",
        "  $cmd switch                            # rotate to the next saved slot",
        "  $cmd list                              # show all slots",
        "  $cmd remove slot-1                     # delete a slot",
        "  $cmd usage                             # show Session + Week usage for every slot",
        "  $cmd usage -Watch                      # live refresh; 60s polls; Ctrl-C to quit",
        "  $cmd usage -Watch -Interval 300        # slower refresh (floor is 60s)",
        "  $cmd usage -Watch -Warmup              # prime all slots (billable; ~2 tokens/slot on Haiku)",
        "  $cmd usage -Watch -Auto                # auto-rotate when active slot hits 95% (OpenCode only)",
        "  $cmd usage -Watch -Auto -Threshold 90  # rotate earlier (default is 95%)",
        "  $cmd usage -Watch -Auto -Warmup        # auto-rotate and prime all available slots",
        "  $cmd usage -Json                       # emit usage as JSON for scripting",
        "  $cmd usage -NoColor                    # B&W output (or: `$env:NO_COLOR='1'; $cmd usage)",
        "",
        "FILES",
        "  Active login : %USERPROFILE%\.claude\.credentials.json",
        "  Saved slots  : %USERPROFILE%\.claude\.credentials.<name>.json",
        "  PS profile   : %USERPROFILE%\Documents\PowerShell\profile.ps1",
        "",
        "NOTES",
        "  * Close Claude Code / VS Code before 'save' or 'switch' (file locks).",
        "  * OAuth tokens expire after ~1h idle; stale slots need re-saving.",
        "  * Invalid Windows filename chars in <name> are replaced with '_'.",
        "  * -Auto requires Claude Code to be closed (it writes ~/.claude.json's identity",
        "    block; Claude Code caches it in memory). OpenCode + opencode-claude-auth",
        "    >= 1.5.4 picks up the credentials swap from .credentials.json automatically;",
        "    no OpenCode restart needed.",
        ""
    )

    $lines | ForEach-Object { Write-Host $_ }
}

# Single chokepoint for ALL colored output. Replaces every previous
# `Write-Host -ForegroundColor X` call site.
#
# Why this exists: on Windows, `Write-Host -ForegroundColor` does NOT
# emit ANSI SGR codes. It calls the legacy Win32 `SetConsoleTextAttribute`
# API (an out-of-band kernel RPC into conhost), then writes the text
# bytes via `Console.Out.Write`, then restores the attribute. The two
# channels (byte stream + Win32 attribute API) are not synchronized
# with each other -- inside DEC 2026 sync mode + the alternate screen
# buffer (`sca usage -Watch`) the per-cell attributes don't align with
# the buffered cell writes, and the body renders in default colors.
# Verified against PS 7.6 source: ConsoleHostUserInterface.cs's
# `Write(fg, bg, value, newLine)` is `RawUI.ForegroundColor = X` ->
# `WriteImpl` -> restore. No ANSI emission anywhere.
#
# `Write-Color` puts SGR codes INTO the message string itself:
#   `\e[<color>m<message>\e[0m`
# That moves the color information into the byte stream, which:
#   1. Sits inside the DEC 2026 sync envelope correctly -> watch mode
#      renders in color.
#   2. Flows through PowerShell's `WriteImpl(string)` -> `GetOutputString
#      (value, supportsVT)` filter, which strips SGR when
#      `$PSStyle.OutputRendering = 'PlainText'` -> -NoColor mode works.
#
# The previous `$PSStyle.OutputRendering = 'PlainText'` toggle (in
# `Invoke-Main`) was structurally broken on Windows for the legacy
# `-ForegroundColor` path before this refactor; this helper is what
# actually makes that toggle effective.
#
# Color name mapping: PowerShell legacy `ConsoleColor` and PS7's
# `$PSStyle.Foreground` use opposite naming conventions. Legacy
# "Dark*" names = the standard ANSI 30-37 colors; legacy un-prefixed
# names (Yellow, Green, Red...) = ANSI bright 90-97. So our existing
# `DarkYellow` (warm amber/mustard headers) maps to
# `$PSStyle.Foreground.Yellow` (ANSI 33), and `Yellow` (advisory)
# maps to `BrightYellow` (ANSI 93). Visually equivalent to the
# pre-refactor rendering on every modern terminal palette.
function Write-Color {
    Param (
        [Parameter(Mandatory)] [String]              $Message,
        [AllowEmptyString()]   [AllowNull()] [String] $Color,
        [switch] $NoNewline
    )

    $sgr = switch ($Color) {
        'Yellow'     { $PSStyle.Foreground.BrightYellow }
        'DarkYellow' { $PSStyle.Foreground.Yellow       }
        'Green'      { $PSStyle.Foreground.BrightGreen  }
        'Red'        { $PSStyle.Foreground.BrightRed    }
        'Cyan'       { $PSStyle.Foreground.BrightCyan   }
        'Gray'       { $PSStyle.Foreground.White        }
        'DarkGray'   { $PSStyle.Foreground.BrightBlack  }
        default      { '' }
    }

    if ($sgr) { $Message = "$sgr$Message$($PSStyle.Reset)" }

    if ($NoNewline) {
        Write-Host -NoNewline $Message
    } else {
        Write-Host $Message
    }
}

# Single chokepoint for ALL non-color VT control sequences in the watch
# lifecycle (alt screen buffer, cursor hide/show, DEC 2026 synchronized
# output, clear screen, cursor home).
#
# Why this exists: PowerShell's `OutputRendering = 'PlainText'` (set by
# `-NoColor` / `$env:NO_COLOR` in `Invoke-Main`) routes every `Write-Host`
# string through `StringDecorated.AnsiRegex`, which is the union of
#   GraphicsRegex  : \x1b\[\d*(;\d+)*m       SGR (color/style)
#   CsiRegex       : \x1b\[\?\d+[hl]         DEC private modes
#   HyperlinkRegex : \x1b\]8;;.*?\x1b\\      OSC 8 hyperlinks
# (verified against PowerShell `StringDecorated.cs`). The DEC 2026 sync
# envelope (`ESC[?2026h`/`l`), alt buffer (`ESC[?1049h`/`l`), and cursor
# hide/show (`ESC[?25l`/`h`) all match `CsiRegex` and are stripped through
# Write-Host -- which silently disables flicker-free rendering in NoColor
# watch mode. `[Console]::Out.Write` bypasses `StringDecorated` entirely,
# so DEC private modes survive regardless of `OutputRendering`.
#
# Body color SGR continues to flow through `Write-Color` -> `Write-Host`
# so `PlainText` still strips body color in `-NoColor` mode (correct).
# `ESC[2J` (clear) and `ESC[H` (cursor home) survive both paths because
# their terminators (J, H) match neither regex; they could go through
# Write-Host without harm, but routing them through this helper keeps
# the watch lifecycle's VT writes consistent.
#
# `[Console]::Out.Flush()` is belt-and-suspenders -- on an interactive
# console handle .NET's TextWriter wrapper writes through immediately,
# but the explicit flush guarantees ordering vs. subsequent Write-Host
# body emission and costs nothing on a 1Hz loop.
function Write-VTSequence {
    Param ([Parameter(Mandatory)] [String] $Sequence)

    [Console]::Out.Write($Sequence)
    [Console]::Out.Flush()
}

# We are sanitizing names to ensure compatibility with the
# Windows filesystem by replacing invalid characters with underscores,
# trimming trailing dots (also invalid on Windows), and rejecting
# reserved device names like CON, PRN, AUX, NUL, COM1-9, LPT1-9.
function Get-SafeName {
    Param ([String] $inputName)

    if ([string]::IsNullOrWhiteSpace($inputName)) { throw "Name required." }

    # Replace Windows-invalid filename characters (including space) with _.
    # [ and ] are valid on the Windows filesystem but PowerShell's -Path
    # parameter treats them as character-class wildcards, so we sanitize
    # them to keep every Test-Path / Copy-Item / Remove-Item call below
    # unambiguous (defense-in-depth alongside -LiteralPath on those calls).
    # ( and ) are sanitized because slot filenames encode the OAuth account
    # email as `.credentials.<slot>(<email>).json`; parens in the slot
    # name would confuse the parser in Get-SlotFileInfo and produce the
    # wrong (slot, email) split.
    $clean = $inputName -replace '[\\/:*?"<>|\[\]()\x00-\x1F ]', '_'

    # Strip trailing dots (Windows silently drops them, which would
    # collapse e.g. 'foo.' and 'foo' into the same slot file).
    $clean = $clean.TrimEnd('.')

    if ([string]::IsNullOrEmpty($clean) -or $clean -eq '.' -or $clean -eq '..') {
        throw "Name '$inputName' resolves to an invalid filename."
    }

    # Windows reserves these device names regardless of extension, so
    # CON.bak is just as forbidden as CON. Compare the pre-first-dot
    # segment against the reserved list.
    $baseSegment = ($clean -split '\.', 2)[0]
    $reserved    = @('CON','PRN','AUX','NUL') + (1..9 | ForEach-Object { "COM$_" }) + (1..9 | ForEach-Object { "LPT$_" })
    if ($reserved -contains $baseSegment.ToUpperInvariant()) {
        throw "'$clean' uses the reserved Windows device name '$baseSegment'."
    }

    if ($clean -ne $inputName) {
        Write-Color "Sanitized to: '$clean'" 'Yellow'
    }

    return $clean
}

# Parse a slot filename (base name, e.g. ".credentials.work(alice@x.com).json")
# into a (Name, Email) tuple. The filename format is:
#   .credentials.<slot-name>.json                    -> unlabeled
#   .credentials.<slot-name>(<email>).json           -> labeled; email must
#                                                       contain '@' to be
#                                                       treated as an email
# The @-in-parens requirement keeps a slot named e.g. "work(v2)" parsing as
# "slot = work(v2), email = none" rather than mis-splitting at the parens.
# Slot names cannot themselves contain '(' or ')' because Get-SafeName
# replaces them with '_' at save time. Returns $null if the filename does
# not match the .credentials.*.json convention.
function Get-SlotFileInfo {
    Param ([String] $FileName)

    # Group 1 = slot name (lazy, so the optional parens-email group wins
    # when present). Group 2 = email (optional; only matches when the
    # parenthesized content contains '@'). .NET regex groups default to
    # empty string when the group did not participate; we coerce to $null
    # below for clarity at the call site.
    if ($FileName -notmatch '^\.credentials\.(.+?)(?:\(([^()]*@[^()]*)\))?\.json$') {
        return $null
    }
    $slotName = $Matches[1]
    $email    = if ($Matches.Count -ge 3 -and $Matches[2]) { $Matches[2] } else { $null }
    return [pscustomobject]@{
        Name  = $slotName
        Email = $email
    }
}

# Build the slot filename for a given (name, email) pair. When email is
# absent, or when the email (case-insensitively) equals the slot name, the
# unlabeled form is returned: the slot name already conveys the account
# and a redundant parenthesized email suffix would only add visual noise.
function Get-SlotFileName {
    Param (
        [String] $Name,
        [String] $Email
    )

    if (-not $Email -or $Name.ToLowerInvariant() -eq $Email.ToLowerInvariant()) {
        return ".credentials.$Name.json"
    }
    return ".credentials.$Name($Email).json"
}

# Enumerate saved credential slots and fingerprint each one against the
# active .credentials.json so callers (list, rotation, usage) share a
# single source of truth. Slots are returned sorted alphabetically by
# name for deterministic rotation order and consistent list output.
#
# Sidecar requirement (post-v2.1.0): slots without a valid
# `.credentials.<name>(<email>).account.json` sidecar are HIDDEN. The
# sidecar carries the captured oauthAccount block restored to
# ~/.claude.json on switch; without it, sca cannot keep Claude Code's
# /status display in sync with the active slot, so the slot is
# unusable. Re-running `sca save <name>` while that slot is active
# recaptures the sidecar from ~/.claude.json and restores visibility.
# No automated migration; legacy slots from pre-v2.1.0 simply become
# invisible until re-saved.
#
# Returns an array of slot objects { Name, Email, Path, IsActive, Sidecar },
# sorted alphabetically by Name. Empty array when no slots saved.
#
# Sidecar is the parsed sidecar object (not raw JSON), which Invoke-
# SwitchAction needs to restore ~/.claude.json. Carrying it inline
# avoids re-reading the file at switch time.
#
# IsActive is sourced from $StateFile via Read-ScaState (which auto-
# migrates by content-hash on first call). This function itself makes
# zero network calls and zero hash computations on the slot files; HTTP
# and hashing live in the calling action's Invoke-Reconcile prelude
# (Invoke-ListAction, Invoke-SwitchAction, Invoke-UsageAction). Callers
# that want a true offline read should call Get-Slots without first
# reconciling.
function Get-Slots {
    # Filter out sidecar files (`.credentials.*.account.json`) themselves
    # so they don't get parsed as slot credentials. The wildcard
    # `.credentials.*.json` would otherwise match them.
    $files = @(
        Get-ChildItem -LiteralPath $CredDir -Filter '.credentials.*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.credentials.json' -and $_.Name -notlike '*.account.json' } |
            Sort-Object -Property Name
    )

    $state      = Read-ScaState
    $activeName = if ($state) { $state.active_slot } else { $null }

    $slots = foreach ($file in $files) {
        $parsed = Get-SlotFileInfo -FileName $file.Name
        if (-not $parsed) { continue }

        # Sidecar requirement: skip slots without a valid sidecar so
        # they don't appear in list / usage / rotation. The slot file
        # itself stays on disk untouched; re-saving via `sca save
        # <name>` while it's active will recapture the sidecar.
        $sidecar = Read-Sidecar -SlotPath $file.FullName
        if (-not $sidecar) { continue }

        [pscustomobject]@{
            Name     = $parsed.Name
            Email    = $parsed.Email
            Path     = $file.FullName
            IsActive = ($activeName -and $parsed.Name -eq $activeName)
            Sidecar  = $sidecar
        }
    }

    # `foreach` assignment yields $null / scalar / Object[] for 0 / 1 / N
    # iterations; PowerShell's pipeline unrolls on emit, so callers that
    # wrap with `@(Get-Slots)` or pipe through Where-Object / ForEach-Object
    # see the right shape across all three cases.
    $slots
}

# Find a slot file by its parsed slot-name, regardless of whether the
# file on disk has the labeled `(email)` suffix or not. Returns the
# matching slot object (same shape as entries in Get-Slots.Slots) or
# $null when no slot matches. Used by Invoke-SwitchAction /
# Invoke-RemoveAction / Invoke-UsageAction so callers can reference a
# slot by user-visible name only.
function Find-SlotByName {
    Param ([String] $Name)

    return Get-Slots | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

# We are determining which slot should become active when `switch` is
# called without an explicit name. Behavior:
#   * No slots saved          -> throw (nothing to rotate to).
#   * One slot, already active -> print warning and return $null (caller exits).
#   * Active slot tracked      -> return { To; HasActiveSlot=$true } for the
#                                next slot (alphabetical, wraps).
#   * No active slot tracked   -> return { To=first; HasActiveSlot=$false }
#                                so the caller can emit a yellow advisory.
#
# `To` is a `{ Name; Email }` object (Email may be $null for unlabeled
# slots) so callers can render the filename-encoded email inline without
# re-looking-up the slot. Active-slot identification reads $StateFile
# (slot.IsActive populated by Get-Slots from state); no content hashing.
function Get-NextSlotName {
    $slots = @(Get-Slots)

    if ($slots.Count -eq 0) {
        throw "No slots saved. Use: sca save <name>"
    }

    $activeIdx = -1
    for ($i = 0; $i -lt $slots.Count; $i++) {
        if ($slots[$i].IsActive) { $activeIdx = $i; break }
    }

    if ($slots.Count -eq 1 -and $activeIdx -eq 0) {
        Write-Color "[Switch] Only one slot ($(Format-SlotIdentity -Name $slots[0].Name -Email $slots[0].Email)) and it is already active. Nothing to do." 'Yellow'
        return $null
    }

    $toSlot = if ($activeIdx -lt 0) { $slots[0] } else { $slots[($activeIdx + 1) % $slots.Count] }

    return [pscustomobject]@{
        To            = [pscustomobject]@{ Name = $toSlot.Name; Email = $toSlot.Email }
        HasActiveSlot = ($activeIdx -ge 0)
    }
}

# We are adding the switch_claude_account_caller function and aliases
# sca (short) and switch-claude-account (long) to the user's PowerShell
# profile for convenient access. The block is written in a single
# Add-Content call so a failure mid-write cannot leave an orphan marker.
function Add-To-Profile {
    if (-not (Test-Path -LiteralPath $ProfilePath)) {
        New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
    }

    # Remove any existing block before re-adding to ensure the
    # wrapper function is always up to date. If the profile has an
    # orphan marker, Remove-From-Profile throws rather than proceeding.
    Remove-From-Profile -Quiet

    # Escape single quotes in the script path so an apostrophe in the
    # path cannot break the single-quoted string in the wrapper.
    $escapedPath = $ScriptPath -replace "'", "''"
    $funcDef     = "function switch_claude_account_caller { & '$escapedPath' @args }"

    $aliasShort  = "Set-Alias -Name sca -Value switch_claude_account_caller -Option AllScope"
    $aliasLong   = "Set-Alias -Name switch-claude-account -Value switch_claude_account_caller -Option AllScope"

    $block = @($MarkerStart, $funcDef, $aliasShort, $aliasLong, $MarkerEnd) -join "`r`n"

    # Separate our block from any preceding profile content with a blank
    # line. Works for every encoding because the separator is just text.
    $profileInfo = Get-Item -LiteralPath $ProfilePath
    if ($profileInfo.Length -gt 0) {
        $block = "`r`n" + $block
    }

    $encoding = Get-ProfileEncoding $ProfilePath
    Add-Content -LiteralPath $ProfilePath -Value $block -Encoding $encoding

    Write-Color "[Install] Installed! Close and reopen PowerShell, then use: sca save <name>" 'Green'
    Write-Host "   Quick ref: sca | sca -h | sca list | sca save <name> | sca switch <name> | sca remove <name>"
}

# We are removing the switch_claude_account_caller block from the
# user's PowerShell profile by splicing the marker-delimited region out
# of the raw file content. Reading with -Raw and writing -NoNewline
# preserves the user's existing line endings (LF, CRLF, or mixed), BOM,
# and trailing-newline convention byte-for-byte; the previous line-based
# implementation silently rewrote everything to CRLF. When only one of
# the two markers is present, we refuse to mutate the profile and throw
# so the user can inspect the damage manually. -Quiet suppresses only
# the benign "no block found" message; the orphan-marker throw is never
# silenced.
function Remove-From-Profile {
    param([switch]$Quiet)
    if (-not (Test-Path -LiteralPath $ProfilePath)) { return }

    $encoding = Get-ProfileEncoding $ProfilePath
    $raw      = Get-Content -LiteralPath $ProfilePath -Raw -Encoding $encoding
    if ($null -eq $raw) { $raw = '' }

    # Line-anchored, case-sensitive marker detection. [ \t]* allows trimmed
    # horizontal whitespace around the marker text on its line but nothing
    # else, so a user comment that merely contains the marker substring will
    # not be misclassified. The (?=\r?\n|\z) lookahead matches end-of-line
    # for both LF and CRLF as well as end-of-input; the simpler $ anchor
    # would fail on CRLF lines because .NET treats $ as "before \n" only.
    $startLine = '(?m)^[ \t]*' + [regex]::Escape($MarkerStart) + '[ \t]*(?=\r?\n|\z)'
    $endLine   = '(?m)^[ \t]*' + [regex]::Escape($MarkerEnd)   + '[ \t]*(?=\r?\n|\z)'

    $hasStart = [regex]::IsMatch($raw, $startLine)
    $hasEnd   = [regex]::IsMatch($raw, $endLine)

    if (-not $hasStart -and -not $hasEnd) {
        if (-not $Quiet) {
            Write-Color "[Uninstall] No Switch Claude Account block found; profile unchanged." 'Yellow'
        }
        return
    }

    if ($hasStart -xor $hasEnd) {
        $orphan = if ($hasStart) { $MarkerStart } else { $MarkerEnd }
        throw "Profile '$ProfilePath' has an orphan '$orphan' marker without its counterpart. Remove it manually and re-run. Profile left unchanged."
    }

    # Splice the block out of the raw content. The leading (?:\r?\n)? absorbs
    # the blank-line separator Add-To-Profile prepends when the profile was
    # non-empty; the trailing (?:\r?\n)? absorbs the line terminator Add-Content
    # appends after the block. Together they keep install -> uninstall
    # byte-identical to the pre-install state. (?s) so . matches newlines;
    # (?m) so ^ matches line starts; .*? is non-greedy so the earliest
    # MarkerEnd closes the match.
    $blockPattern =
        '(?sm)(?:\r?\n)?' +
        '^[ \t]*' + [regex]::Escape($MarkerStart) + '[ \t]*\r?\n' +
        '.*?' +
        '^[ \t]*' + [regex]::Escape($MarkerEnd)   + '[ \t]*' +
        '(?:\r?\n)?'

    $new = [regex]::Replace($raw, $blockPattern, '')

    # -NoNewline so Remove leaves no trailing newline of its own. Add-To-Profile
    # prepends a separator when the file is non-empty and Add-Content adds one
    # trailing newline, which keeps install -> install byte-idempotent.
    Set-Content -LiteralPath $ProfilePath -Value $new -Encoding $encoding -Force -NoNewline

    if (-not $Quiet) {
        Write-Color "[Uninstall] Uninstalled. Close and reopen PowerShell to remove the alias." 'Red'
    }
}

# Atomic-write a fresh auto-save slot file (and its identity sidecar, when
# OAuthAccount is non-null) and update state.active_slot to point at it.
# Returns the generated slot name on success.
#
# Caller owns the user-visible advisory message and the return-object
# `Action` discriminator. Invoke-Reconcile has two auto-save callers
# (cross-account swap detection vs unknown-state recovery) whose
# advisory text and return shape differ enough that merging them into
# one helper would conflate semantically distinct events; keeping the
# advisory + return at the call sites preserves that distinction while
# this helper handles the mechanical write sequence.
#
# Sidecar-write failure is non-fatal: a yellow advisory is printed
# (Get-Slots will hide a sidecar-less slot, so the orphan tokens file
# is invisible-but-on-disk and `sca remove` cleans it up by name).
function New-AutoSaveSlot {
    Param (
        [Parameter(Mandatory)] [byte[]] $Bytes,
        [String] $Email,
        $OAuthAccount,
        [String] $SourceLabel,
        [Parameter(Mandatory)] [String] $LastSyncHash
    )

    $autoName = 'auto-' + ([DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'"))
    $autoPath = Join-Path $CredDir (Get-SlotFileName -Name $autoName -Email $Email)
    Set-CredentialFileAtomic -Path $autoPath -Bytes $Bytes
    if ($OAuthAccount) {
        try {
            Write-Sidecar -SlotPath $autoPath -OAuthAccount $OAuthAccount -Source $SourceLabel
        }
        catch {
            Write-Color "[Sync] Auto-save sidecar write failed for '$autoName': $($_.Exception.Message)" 'Yellow'
        }
    }
    Update-ScaState -ActiveSlot $autoName -LastSyncHash $LastSyncHash | Out-Null
    return $autoName
}

# Reconcile .credentials.json with the saved slot tracked in $StateFile.
# Called at the start of every credentials-touching action that needs the
# tracked slot to reflect Claude Code's most recent token refresh (sca
# switch and sca usage in the redesigned model).
#
# Algorithm (5 outcomes; never throws unless an atomic write itself fails):
#   1. .credentials.json missing                   -> noop
#   2. hash matches state.last_sync_hash           -> noop
#   3. tracked slot exists, identity matches       -> mirror bytes -> slot
#   4. tracked slot exists, identity DIFFERS       -> auto-save under new name
#                                                     (cross-account swap detected;
#                                                      old slot file preserved)
#   5. no tracked slot, OR slot file is gone       -> auto-save under new name
#
# Identity probe (post-v2.1.0): ~/.claude.json's oauthAccount.emailAddress.
# This is the same source Claude Code uses for /status, so reconcile and
# Claude Code can never disagree about the active identity. The probe is
# offline (no HTTP), making it both faster and more reliable than the
# previous /api/oauth/profile probe (which could occasionally return a
# different email for the same account). When ~/.claude.json has no
# oauthAccount yet (rare: fresh install, never logged into Claude Code),
# we fall back to /api/oauth/profile so the noop / mirror branches still
# work for users in that transient state.
#
# Tracked slot's identity comes from the slot's sidecar (which was
# captured at save time from ~/.claude.json or /api/oauth/profile). This
# is what we compare ~/.claude.json's current value against.
#
# Race protection: bytes are read from .credentials.json once, then both
# hashed and written. If Claude Code rewrites the file between our read
# and our write, the slot file is consistent with our hash; the next
# reconcile catches up to the newer bytes. No retry loop needed.
#
# Returns a [pscustomobject] describing the outcome so tests and callers
# can assert on the action without parsing stdout. Stdout still carries
# the user-visible advisory for the two non-silent branches (auto-save,
# identity-change).
function Invoke-Reconcile {
    if (-not (Test-Path -LiteralPath $CredFile)) {
        return [pscustomobject]@{ Action = 'noop'; Reason = 'no-active-credentials' }
    }

    $bytes = [System.IO.File]::ReadAllBytes($CredFile)

    # Hash the bytes we just read (not the file path) so the (bytes, hash)
    # pair is internally consistent even if Claude Code rewrites the file
    # mid-reconcile. Get-SHA256Hex produces uppercase hex matching the
    # format Read-ScaState's auto-migration uses, so values round-trip
    # equality across credential-file sources.
    $hash = Get-SHA256Hex -Bytes $bytes

    $state = Read-ScaState
    if ($state -and $state.last_sync_hash -eq $hash) {
        return [pscustomobject]@{ Action = 'noop'; Reason = 'hash-match' }
    }

    # Bytes differ from last sync. Resolve new identity. Preferred: read
    # ~/.claude.json's oauthAccount.emailAddress (offline; same source
    # Claude Code uses). Fallback: /api/oauth/profile (network) when
    # ~/.claude.json has no oauthAccount populated yet.
    $newAccount = Get-OAuthAccountFromClaudeJson
    $newEmail   = if ($newAccount) { $newAccount.emailAddress } else { $null }
    if (-not $newEmail) {
        $profileResult = Get-SlotProfile -SlotPath $CredFile
        if ($profileResult.Status -eq 'ok') {
            $newEmail = $profileResult.Email
            # Synthesize a minimal accountInfo for the auto-save sidecar.
            $newAccount = [pscustomobject]@{
                accountUuid      = $null
                emailAddress     = $newEmail
                organizationUuid = $null
                displayName      = $null
                organizationName = $null
            }
        }
    }
    $sourceLabel = if ($newAccount -and $newAccount.accountUuid) { 'claude_json' } else { 'api_profile' }

    if ($state -and $state.active_slot) {
        $slot = Find-SlotByName -Name $state.active_slot
        if ($slot) {
            # Tracked slot's email comes from its sidecar (Get-Slots
            # always populates this on the slot object). Tolerate
            # offline / unknown-new-identity by falling into the
            # same-identity branch; preserves continuity over paranoia.
            $slotEmail    = if ($slot.Sidecar) { [string]$slot.Sidecar.oauthAccount.emailAddress } else { $slot.Email }
            $sameIdentity = (-not $newEmail) -or (-not $slotEmail) -or ($newEmail -eq $slotEmail)
            if ($sameIdentity) {
                Set-CredentialFileAtomic -Path $slot.Path -Bytes $bytes
                Update-ScaState -LastSyncHash $hash | Out-Null
                return [pscustomobject]@{
                    Action = 'mirror'
                    Slot   = $state.active_slot
                    Email  = $slotEmail
                }
            }

            # Cross-account swap detected. DON'T overwrite; auto-save the
            # new credentials under a fresh name so both identities are
            # preserved on disk and the user can resolve the conflict.
            $autoName = New-AutoSaveSlot -Bytes $bytes -Email $newEmail `
                                         -OAuthAccount $newAccount `
                                         -SourceLabel $sourceLabel `
                                         -LastSyncHash $hash

            $oldIdent = Format-SlotIdentity -Name $state.active_slot -Email $slotEmail
            Write-Color "[Sync] Active credentials are now $newEmail; previous slot $oldIdent preserved. Active slot is now '$autoName'." 'Yellow'
            return [pscustomobject]@{
                Action       = 'identity-change'
                Slot         = $autoName
                PreviousSlot = $state.active_slot
                Email        = $newEmail
            }
        }
        # state.active_slot pointed at a slot file that no longer exists
        # OR the slot file exists but has no sidecar (Get-Slots filtered
        # it out). Fall through to auto-save so the new bytes still land
        # in a fresh, sidecared slot.
    }

    # No tracked slot, or tracked slot file/sidecar is gone. Auto-save fallback.
    $autoName = New-AutoSaveSlot -Bytes $bytes -Email $newEmail `
                                 -OAuthAccount $newAccount `
                                 -SourceLabel $sourceLabel `
                                 -LastSyncHash $hash

    $autoIdent = Format-SlotIdentity -Name $autoName -Email $newEmail
    Write-Color "[Sync] Auto-saved unknown active credentials as $autoIdent." 'Yellow'
    return [pscustomobject]@{
        Action = 'auto-save'
        Slot   = $autoName
        Email  = $newEmail
    }
}

# We are extracting each action body into its own function so the logic
# is directly invokable from tests without spawning a subprocess and
# without re-parsing the $Action dispatcher. The dispatcher below becomes
# a thin switch that forwards to these functions.

function Invoke-SaveAction {
    Param ([String] $Name)

    $safeName = Get-SafeName $Name

    if (-not (Test-Path -LiteralPath $CredFile)) {
        throw "$CredFile not found. Log in via Claude Code first."
    }

    # Refuse if Claude Code is running. We resolve identity from
    # ~/.claude.json's oauthAccount, which Claude Code keeps in an
    # in-memory cache and may flush back to disk at any moment. Saving
    # while Claude Code runs would silently capture stale identity into
    # the sidecar AND risk overwriting our writes if a flush races our
    # write. Refuse-while-running is the chosen mitigation; see
    # CLAUDE.md's planning history for the binary-RE rationale.
    if (Test-ClaudeRunning) {
        throw "Claude Code is running. Close it before 'sca save' so identity capture is consistent."
    }

    # Resolve identity. ~/.claude.json's oauthAccount is the preferred
    # source (it's exactly what Claude Code's /status displays, drift-
    # proof by construction). Fall back to a live /api/oauth/profile
    # call only when ~/.claude.json has no oauthAccount yet (rare:
    # fresh install, user wiped the config, etc.). Failing both ->
    # refuse the save: a sidecar without identity is invalid by design.
    $accountInfo = Get-OAuthAccountFromClaudeJson
    $sourceLabel = 'claude_json'
    if (-not $accountInfo) {
        # Fallback path: live /api/oauth/profile. Returns only the email,
        # so the rest of the oauthAccount fields default to $null. The
        # slot is still usable (Claude Code re-derives missing fields
        # from the next refresh response). Use a non-automatic-variable
        # name (`$profileResult` rather than `$profile`); `$profile` is
        # PowerShell's automatic for the running profile path and a
        # collision could surprise downstream code.
        $profileResult = Get-SlotProfile -SlotPath $CredFile
        if ($profileResult.Status -eq 'ok' -and $profileResult.Email) {
            $accountInfo = [pscustomobject]@{
                accountUuid      = $null
                emailAddress     = $profileResult.Email
                organizationUuid = $null
                displayName      = $null
                organizationName = $null
            }
            $sourceLabel = 'api_profile'
        } else {
            $reason = if ($profileResult.Error) {
                Format-StatusErrorTail $profileResult.Error
            } else {
                $profileResult.Status
            }
            throw "Cannot resolve account identity: ~/.claude.json has no oauthAccount and /api/oauth/profile failed ($reason). Sign in to Claude Code first ('claude /login')."
        }
    }

    $email = $accountInfo.emailAddress
    if ([string]::IsNullOrWhiteSpace($email)) {
        throw "Resolved oauthAccount has no emailAddress; cannot save."
    }

    # Read .credentials.json bytes once. The same bytes are written to
    # the slot file via atomic rename and hashed for state.last_sync_hash;
    # this read-once-write-once approach ensures internal consistency
    # even if Claude Code rewrites .credentials.json during the save.
    # (Claude Code is closed, but a background process, antivirus or
    # backup tool, could still touch the file.)
    $bytes = [System.IO.File]::ReadAllBytes($CredFile)

    # Final filename now that identity is known. We write directly to the
    # final path; no unlabeled-then-rename dance.
    $finalSlotName = Get-SlotFileName -Name $safeName -Email $email
    $finalSlotPath = Join-Path $CredDir $finalSlotName

    # Find any pre-existing slot files / sidecars for this slot name
    # (labeled or unlabeled, possibly with stale email) and SNAPSHOT
    # their bytes into memory before any disk mutation. The snapshot is
    # the rollback source for the catch path: if either the tokens or
    # sidecar write fails, we restore from these buffers so a transient
    # failure on a re-save cannot leave the user with no slot for this
    # name. Get-Slots filters out sidecar-less slots, so we enumerate
    # the raw file system here to also catch invisible legacy slots
    # that share this slot name.
    $snapshots = @()
    $rawFiles = @(
        Get-ChildItem -LiteralPath $CredDir -Filter '.credentials.*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.credentials.json' -and $_.Name -notlike '*.account.json' }
    )
    foreach ($rf in $rawFiles) {
        $parsed = Get-SlotFileInfo -FileName $rf.Name
        if (-not $parsed -or $parsed.Name -ne $safeName) { continue }

        $snap = [pscustomobject]@{
            Path         = $rf.FullName
            Bytes        = $null
            SidecarPath  = Get-SidecarPath -SlotPath $rf.FullName
            SidecarBytes = $null
        }
        try {
            $snap.Bytes = [System.IO.File]::ReadAllBytes($rf.FullName)
        }
        catch {
            # Read failure (file locked / unreadable). Mark non-restorable
            # but proceed with the save: refusing on a stale file the
            # user is explicitly overwriting would be surprising.
            Write-Color "[Save] WARNING: could not snapshot $($rf.FullName) ($($_.Exception.Message)); rollback for this path will be skipped." 'Yellow'
        }
        if (Test-Path -LiteralPath $snap.SidecarPath) {
            try {
                $snap.SidecarBytes = [System.IO.File]::ReadAllBytes($snap.SidecarPath)
            }
            catch {
                Write-Color "[Save] WARNING: could not snapshot $($snap.SidecarPath) ($($_.Exception.Message)); rollback for this path will be skipped." 'Yellow'
            }
        }
        $snapshots += $snap
    }

    # Write tokens, then sidecar. Order matters for atomic-pair semantics.
    # On any failure we clear partial new state at $finalSlotPath, then
    # restore each snapshot's bytes (tokens AND sidecar) so the slot
    # returns to its pre-save state. An orphan sidecar without a matching
    # tokens file is harmless; Get-Slots only iterates tokens files,
    # sidecars are looked up by-path.
    try {
        Set-CredentialFileAtomic -Path $finalSlotPath -Bytes $bytes
        Write-Sidecar -SlotPath $finalSlotPath -OAuthAccount $accountInfo -Source $sourceLabel
    }
    catch {
        $innerMsg = $_.Exception.Message

        # Clear any partial new pair we wrote. If $finalSlotPath happened
        # to coincide with a snapshot path (same-email re-save), this
        # also wipes the just-overwritten old bytes; the restore loop
        # below puts them back.
        Remove-Item -LiteralPath $finalSlotPath -Force -ErrorAction SilentlyContinue
        Remove-Sidecar -SlotPath $finalSlotPath

        # Restore each snapshot. Per-snapshot try/catch so one restore
        # failure does not abort the others.
        foreach ($snap in $snapshots) {
            if ($null -ne $snap.Bytes) {
                try {
                    Set-CredentialFileAtomic -Path $snap.Path -Bytes $snap.Bytes
                }
                catch {
                    Write-Color "[Save] WARNING: could not restore $($snap.Path) ($($_.Exception.Message))." 'Yellow'
                }
            }
            if ($null -ne $snap.SidecarBytes) {
                try {
                    Set-CredentialFileAtomic -Path $snap.SidecarPath -Bytes $snap.SidecarBytes
                }
                catch {
                    Write-Color "[Save] WARNING: could not restore $($snap.SidecarPath) ($($_.Exception.Message))." 'Yellow'
                }
            }
        }

        throw "Save failed for slot '$safeName' ($innerMsg); attempted to restore previous slot state."
    }

    # New pair is durable. Delete obsolete siblings (any snapshot whose
    # path differs from $finalSlotPath). Same-path snapshots were
    # overwritten in place by the atomic Replace above and need no
    # further action.
    foreach ($snap in $snapshots) {
        if ($snap.Path -ne $finalSlotPath) {
            Remove-Item -LiteralPath $snap.Path -Force -ErrorAction SilentlyContinue
            Remove-Sidecar -SlotPath $snap.Path
        }
    }

    # Update state: this slot is now the active one, and its bytes match
    # .credentials.json (we just wrote them). Hash the bytes we wrote
    # rather than re-reading either file, for the read-once-write-once
    # consistency property described above.
    $hash = Get-SHA256Hex -Bytes $bytes
    Update-ScaState -ActiveSlot $safeName -LastSyncHash $hash | Out-Null

    $sourceTail = if ($sourceLabel -eq 'api_profile') { ' [identity from /api/oauth/profile]' } else { '' }
    Write-Color "[Save] Saved as $(Format-SlotIdentity -Name $safeName -Email $email)$sourceTail" 'Green'
}

# Pure swap mechanism, factored out of Invoke-SwitchAction so the watch
# loop's -Auto path can rotate without rendering the `[Switch]` header
# or the saved-slot table that follows it in the user-facing switch
# action. Side effects only:
#
#   1. Atomic-rename write the slot's bytes into .credentials.json.
#   2. Substitute the destination slot's captured oauthAccount into
#      ~/.claude.json's top-level oauthAccount block. Failure here is
#      surfaced as a yellow advisory (NOT fatal): the credentials swap
#      has already happened, so the user sees the partial-success state
#      and can re-run once the ~/.claude.json issue clears.
#   3. Update $StateFile so state.active_slot points at the destination
#      and state.last_sync_hash matches the new credentials bytes.
#
# Preconditions (callers MUST enforce):
#   * Test-ClaudeRunning returned $false. The ~/.claude.json write
#     races Claude Code's in-memory oauthAccount cache; this helper
#     does NOT recheck the running guard.
#   * $Slot has a valid sidecar (the caller resolved it via
#     Find-SlotByName / Get-Slots, both of which filter out
#     sidecar-less slots).
#
# No reconcile prelude here either; the caller's higher-level workflow
# already reconciled or has its own per-tick capture (the watch loop's
# per-poll Invoke-Reconcile covers the -Auto case).
function Invoke-SlotSwap {
    Param (
        [Parameter(Mandatory)] [pscustomobject] $Slot
    )

    # Atomic-rename copy: works even if Claude Code has .credentials.json
    # open (it grants share-delete); but with the running guard enforced
    # by the caller, this path normally only executes when Claude Code
    # is closed. Bytes are read from the slot file once and reused for
    # both the write and the state hash so the post-swap state.hash
    # matches the bytes we just wrote (not a re-read that could race a
    # concurrent refresh from another tool).
    $slotBytes = [System.IO.File]::ReadAllBytes($Slot.Path)
    Set-CredentialFileAtomic -Path $CredFile -Bytes $slotBytes

    # Restore the captured oauthAccount into ~/.claude.json so Claude
    # Code's /status display matches the active slot on next start.
    # Failure to write ~/.claude.json (file locked, malformed,
    # disappeared) is surfaced as an advisory; we do NOT rollback the
    # credentials write because Claude Code (or the OpenCode plugin in
    # the -Auto case) may have already started using the new tokens.
    try {
        Set-OAuthAccountInClaudeJson -OAuthAccount $Slot.Sidecar.oauthAccount
    }
    catch {
        Write-Color "[Switch] Tokens swapped to '$($Slot.Name)' but ~/.claude.json oauthAccount update failed: $($_.Exception.Message)" 'Yellow'
        Write-Color "[Switch] Claude Code's /status email may not reflect the new slot until you fix and re-run." 'Yellow'
    }

    $hash = Get-SHA256Hex -Bytes $slotBytes
    Update-ScaState -ActiveSlot $Slot.Name -LastSyncHash $hash | Out-Null
}

function Invoke-SwitchAction {
    Param ([String] $Name)

    # Refuse if Claude Code is running. Switch writes to ~/.claude.json's
    # oauthAccount block from the destination slot's sidecar, and a
    # running Claude Code instance keeps that file in an in-memory
    # cache that may flush and clobber our update. Refusing is the
    # simplest reliability guarantee; see CLAUDE.md's planning history.
    if (Test-ClaudeRunning) {
        throw "Claude Code is running. Close it before 'sca switch' so the email-display change applies cleanly."
    }

    # Reconcile FIRST so any pending Claude Code refresh on the outgoing
    # active slot is mirrored into the saved slot file before we
    # overwrite .credentials.json. If reconcile triggers an auto-save or
    # identity-change branch, its yellow advisory prints above the
    # subsequent switch output; that is desired (the user sees
    # context for the unusual state).
    Invoke-Reconcile | Out-Null

    # When invoked without a name, rotate to the next saved slot
    # (alphabetical, wrap-around). Get-NextSlotName returns $null for
    # the single-slot-already-active no-op and prints its own yellow
    # advisory; we return in that case so neither the success line nor
    # the table render (nothing has changed, the user already saw the
    # advisory).
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $rotation = Get-NextSlotName
        if (-not $rotation) { return }

        $safeName = $rotation.To.Name
        $toIdent  = Format-SlotIdentity -Name $rotation.To.Name -Email $rotation.To.Email

        # No-active-slot advisory: yellow line surfaced before the green
        # success line so the user notices the unusual state. Rotation
        # proceeds either way. The happy path (HasActiveSlot=true)
        # emits no advisory; the slot table beneath the success line
        # makes the transition self-evident via the `*` marker.
        if (-not $rotation.HasActiveSlot) {
            Write-Color "[Switch] No currently active slot detected. Rotating to $toIdent." 'Yellow'
        }
    } else {
        $safeName = Get-SafeName $Name
    }

    $slot = Find-SlotByName -Name $safeName
    if (-not $slot) {
        # Find-SlotByName goes through Get-Slots which filters out
        # sidecar-less slots, so the missing-slot error covers both
        # "never existed" and "exists on disk but no sidecar". Tell the
        # user about both possibilities so they can recover from a
        # stale-state scenario.
        throw "Slot '$safeName' not found (or missing its identity sidecar; re-save while active to recapture)."
    }

    # Perform the swap via the extracted pure-mechanism helper. Any
    # ~/.claude.json write failure is surfaced as an advisory by the
    # helper (yellow, not fatal) so the credentials swap is observable
    # even when the identity update fails.
    Invoke-SlotSwap -Slot $slot

    # DarkYellow header line; matches the `[List] Saved slots` /
    # `[Usage] Plan usage` convention so all three actions present a
    # consistent table-header look. No trailing period: this is a
    # header, not a complete sentence.
    $toIdent = Format-SlotIdentity -Name $slot.Name -Email $slot.Email
    Write-Color "[Switch] Switched to $toIdent" 'DarkYellow'

    # Render the saved-slot table beneath the success line so the user
    # sees the new active slot in context (the `*` marker now points at
    # the just-activated row). Re-enumerate via Get-Slots so IsActive
    # reflects the post-switch state. -SuppressHeader keeps the visual
    # weight low; the `[Switch]` line above is enough of a section
    # header.
    Write-Host ''
    Format-ListTable -Slots @(Get-Slots) -SuppressHeader
    Write-Host ''
}

function Invoke-ListAction {
    # Reconcile first so a cross-account swap that happened since the last
    # sca call surfaces in the marker column. state.active_slot only
    # changes through reconcile's identity-change branch (auto-save under
    # auto-<UTC>); same-identity drift mirrors bytes but leaves the
    # active slot unchanged, so the marker would be identical with or
    # without reconcile in that case. The reconcile is also what
    # bootstraps state on a fresh install (auto-migration via
    # Read-ScaState, then auto-save via Invoke-Reconcile if no slot
    # matched the active-credentials hash). Mirrors the prelude pattern
    # in Invoke-SwitchAction / Invoke-UsageAction.
    Invoke-Reconcile | Out-Null

    $slots = @(Get-Slots)

    if ($slots.Count -eq 0) {
        Write-Color "[List] No slots saved yet. Use: sca save <name>" 'Yellow'
        return
    }

    Format-ListTable -Slots $slots
}

function Invoke-RemoveAction {
    Param ([String] $Name)

    $safeName = Get-SafeName $Name

    # Lookup walks the raw filesystem rather than Get-Slots so the user
    # can clean up sidecar-less legacy slots that Get-Slots hides.
    # Without this, an invisible legacy slot would be impossible to
    # remove without manual filesystem editing.
    $rawFiles = @(
        Get-ChildItem -LiteralPath $CredDir -Filter '.credentials.*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.credentials.json' -and $_.Name -notlike '*.account.json' }
    )
    $matching = @()
    foreach ($rf in $rawFiles) {
        $parsed = Get-SlotFileInfo -FileName $rf.Name
        if ($parsed -and $parsed.Name -eq $safeName) {
            $matching += $rf
        }
    }
    if ($matching.Count -eq 0) {
        throw "Slot '$safeName' not found."
    }

    # Refuse to remove the currently-active slot. Forces the user to
    # explicitly switch to another slot first, which is the natural
    # workflow and avoids leaving .credentials.json pointing at bytes
    # we just deleted from disk.
    $state = Read-ScaState
    if ($state -and $state.active_slot -eq $safeName) {
        throw "Cannot remove active slot '$safeName'. Run 'sca switch <other>' first, or delete .credentials.json manually if you want to drop tracking."
    }

    foreach ($rf in $matching) {
        Remove-Item -LiteralPath $rf.FullName -Force
        Remove-Sidecar -SlotPath $rf.FullName
    }
    Write-Color "[Remove] Removed '$safeName'" 'Red'
}

# --- usage action internals ---

# True if $Exception came from an Invoke-RestMethod call that hit HTTP 429.
# Tolerates the two shapes our codebase encounters in practice:
#   * Real Microsoft.PowerShell.Commands.HttpResponseException whose
#     .Response.StatusCode is a System.Net.HttpStatusCode enum value
#     ([int][HttpStatusCode]::TooManyRequests = 429).
#   * The lightweight pscustomobject Response shim used by tests
#     (Invoke-UsageAction.Tests.ps1's 401 mock pattern), where
#     .Response.StatusCode is already an integer.
# Returns $false for null exceptions, exceptions without a Response member,
# and any non-429 status; the caller's catch block falls through to its
# pre-existing error handling for those.
function Test-Is429 {
    Param ($Exception)
    if (-not $Exception) { return $false }
    $r = $Exception.Response
    if (-not $r -or -not $r.StatusCode) { return $false }
    return ([int]$r.StatusCode -eq 429)
}

# Collapse and tail-truncate an exception message for rendering inside the
# Status column of the usage table. 60 characters keeps long messages from
# wrapping the row in typical 100-col terminals while still conveying enough
# context to debug; the whitespace collapse drops embedded newlines (some
# socket exceptions span multiple lines). Single helper so the 'expired'
# and 'error' arms of Format-UsageTable's status switch stay in lockstep.
function Format-StatusErrorTail {
    Param (
        [AllowNull()] [String] $Message,
        [int] $Max = 60
    )
    if ([string]::IsNullOrEmpty($Message)) { return '' }
    $msg = ($Message -replace "\s+", ' ').Trim()
    if ($msg.Length -gt $Max) { $msg = $msg.Substring(0, $Max) + '...' }
    return $msg
}

# Read OAuth material from a slot file. Returns an object carrying the
# parsed token fields plus the raw parsed JSON so Update-SlotTokens can
# round-trip unknown fields (subscriptionType, rateLimitTier, scopes,
# clientId, ...) without losing them. HasOAuth is false for slots that
# are API-key-only or otherwise lack the claudeAiOauth section.
function Get-SlotOAuth {
    Param ([String] $SlotPath)

    $json = Get-Content -LiteralPath $SlotPath -Raw -ErrorAction Stop
    $obj  = $json | ConvertFrom-Json -ErrorAction Stop
    $oa   = $obj.claudeAiOauth

    if (-not $oa -or -not $oa.accessToken -or -not $oa.refreshToken) {
        return [pscustomobject]@{
            HasOAuth     = $false
            AccessToken  = $null
            RefreshToken = $null
            ExpiresAt    = $null
            RawObject    = $obj
        }
    }

    # expiresAt is a Unix epoch in MILLISECONDS (Claude Code convention;
    # the OAuth2 'expires_in' -> absolute ms conversion is how the CLI
    # persists it). Treat 0 / missing as "unknown, force a refresh".
    $expiresAt = $null
    if ($oa.expiresAt) {
        $expiresAt = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$oa.expiresAt).UtcDateTime
    }

    return [pscustomobject]@{
        HasOAuth     = $true
        AccessToken  = [string]$oa.accessToken
        RefreshToken = [string]$oa.refreshToken
        ExpiresAt    = $expiresAt
        RawObject    = $obj
    }
}

# Refresh the slot's OAuth tokens against platform.claude.com/v1/oauth/token,
# using the same request shape Claude Code itself sends (verified against
# claude.exe 2.1.119). Writes the new tokens via Set-CredentialFileAtomic
# (single write primitive shared with save / switch / state-file writes),
# then, if the slot being refreshed is the currently-tracked active slot,
# also writes the same bytes to .credentials.json so Claude Code's next
# call sees the new refresh_token. This restores the auto-sync property
# the previous hardlink-based design provided implicitly.
#
# Returns the new access token on success; throws with a descriptive
# message on failure.
#
# Race with a running Claude Code: `sca usage` does NOT refuse while
# Claude Code is running (only `save` / `switch` do; see
# Test-ClaudeRunning callers), so an active-slot refresh triggered here
# can race against Claude Code's own refresh. Anthropic rotates the
# refresh_token on every successful /v1/oauth/token call: whichever
# party (sca or Claude Code) calls second presents the now-rotated old
# token and gets a 4xx, losing its session. We accept this as a
# deliberate trade-off: refusing `sca usage` while Claude Code runs
# would defeat the action's main use case (live monitoring during
# work). In practice the race is rare (the refresh window is a ~60s
# slice once per hour) and recoverable: if a refresh fails after this
# function rotated the token, the slot file holds the new tokens; rerun
# `sca switch <slot>` to repropagate them into .credentials.json. If
# Claude Code rotated first and our call here lost, the user re-logs
# into Claude Code and reruns `sca save <slot>` to recapture.
function Update-SlotTokens {
    Param ([String] $SlotPath)

    # Suppress PowerShell's built-in 'Web request' progress activity
    # (Write-Progress / stream 4: rotating status messages including
    # "Waiting for response..." and "Reading web response (NNN bytes)")
    # so it does not paint the host UI between `sca usage -Watch`
    # frames. The progress activity is host-managed and bypasses the
    # DEC 2026 byte-stream sync envelope around each frame, so without
    # this suppression it flashes in the alt buffer for the duration
    # of the HTTP call. Function-scoped: PowerShell's preference-
    # variable scope chain restores the parent value automatically on
    # function exit (no try/finally needed). Same suppression applied
    # identically in Get-SlotUsage and Get-SlotProfile (the other two
    # Invoke-RestMethod call sites in the script).
    $ProgressPreference = 'SilentlyContinue'

    $info = Get-SlotOAuth -SlotPath $SlotPath
    if (-not $info.HasOAuth) {
        throw "Slot '$SlotPath' has no OAuth material to refresh."
    }

    $body = @{
        grant_type    = 'refresh_token'
        refresh_token = $info.RefreshToken
        client_id     = $Script:OAuthClientId
    } | ConvertTo-Json -Compress

    $headers = @{
        'Content-Type'      = 'application/json'
        'anthropic-beta'    = $Script:AnthropicBeta
        'anthropic-version' = $Script:AnthropicApiVersion
        'User-Agent'        = $Script:UsageUserAgent
    }

    # 429 retry loop. The token endpoint's per-token rate limiter
    # unlocks within ~seconds, so a short exponential backoff
    # (2 s, 4 s) recovers a stuck slot inside one watch-loop tick
    # without surfacing a spurious 'rate-limited' status. Non-429
    # exceptions rethrow on the first failure (no point retrying a
    # 4xx with a malformed request or a 5xx with a server-side
    # problem). Tests override $Script:TokenRefreshRetryDelayMs to
    # zero so the mocked 429 paths complete instantly.
    $resp = $null
    for ($attempt = 1; $attempt -le $Script:TokenRefreshRetryMax; $attempt++) {
        try {
            $resp = Invoke-RestMethod -Method Post `
                                      -Uri $Script:TokenEndpoint `
                                      -Headers $headers `
                                      -Body $body `
                                      -TimeoutSec $Script:UsageTimeoutSec `
                                      -ErrorAction Stop
            break
        }
        catch {
            $is429 = Test-Is429 $_.Exception
            if (-not $is429 -or $attempt -ge $Script:TokenRefreshRetryMax) {
                throw
            }
            # Exponential backoff: 2 s, 4 s, 8 s ... capped by RetryMax.
            $sleepMs = $Script:TokenRefreshRetryDelayMs * [Math]::Pow(2, $attempt - 1)
            Start-Sleep -Milliseconds ([int]$sleepMs)
        }
    }

    if (-not $resp.access_token) {
        throw "OAuth refresh succeeded but response missing access_token."
    }
    if (-not $resp.expires_in) {
        throw "OAuth refresh succeeded but response missing expires_in."
    }

    $newAccess  = [string]$resp.access_token
    # The OAuth2 refresh response MAY omit refresh_token; per RFC 6749 the
    # client should continue using the old one in that case. Matches
    # Claude Code's `w.refresh_token || z` fallback.
    $newRefresh = if ($resp.refresh_token) { [string]$resp.refresh_token } else { $info.RefreshToken }
    $newExpMs   = [DateTimeOffset]::UtcNow.AddSeconds([double]$resp.expires_in).ToUnixTimeMilliseconds()

    # Mutate the parsed object in place, preserving any unknown fields
    # (scopes, subscriptionType, rateLimitTier, clientId, ...).
    $raw = $info.RawObject
    $raw.claudeAiOauth.accessToken  = $newAccess
    $raw.claudeAiOauth.refreshToken = $newRefresh
    $raw.claudeAiOauth.expiresAt    = $newExpMs

    $newJson  = $raw | ConvertTo-Json -Depth 10 -Compress
    $newBytes = [System.Text.Encoding]::UTF8.GetBytes($newJson)

    Set-CredentialFileAtomic -Path $SlotPath -Bytes $newBytes

    # Active-slot auto-sync: if this slot is currently tracked as active,
    # propagate the new tokens to .credentials.json so Claude Code's
    # next call uses the latest refresh_token. Without this propagation
    # the slot would silently drift ahead of .credentials.json after a
    # refresh, and Anthropic's refresh-token rotation could invalidate
    # the version Claude Code still holds. Belt-and-suspenders: also
    # update state.last_sync_hash so the next Invoke-Reconcile no-ops
    # rather than re-mirroring.
    $state = Read-ScaState
    if ($state -and $state.active_slot) {
        $activeSlot = Find-SlotByName -Name $state.active_slot
        if ($activeSlot -and $activeSlot.Path -eq $SlotPath) {
            try {
                Set-CredentialFileAtomic -Path $CredFile -Bytes $newBytes

                $newHash = Get-SHA256Hex -Bytes $newBytes
                Update-ScaState -LastSyncHash $newHash | Out-Null
            }
            catch {
                # Slot file holds the new tokens; .credentials.json still
                # has the old ones. The next Invoke-Reconcile will hash-
                # match-noop (state.last_sync_hash equals .credentials.json's
                # current bytes) so this gap does NOT auto-heal -- the
                # mirror direction is .credentials.json -> slot, never the
                # reverse. The user must re-propagate explicitly via
                # `sca switch <slot>` (which writes the slot's bytes back
                # into .credentials.json). Until they do, Anthropic may
                # have rotated the refresh_token we just consumed; Claude
                # Code reading the stale .credentials.json could fail its
                # own next refresh and require re-login.
                Write-Color "[Sync] Token refreshed in slot '$($state.active_slot)' but propagation to .credentials.json failed: $($_.Exception.Message). Run 'sca switch $($state.active_slot)' to propagate manually; otherwise Claude Code's own refresh may fail and require re-login." 'Yellow'
            }
        }
        elseif (-not $activeSlot) {
            # state.active_slot is set but Find-SlotByName returned $null,
            # so the tracked active slot has no valid sidecar and Get-Slots
            # filtered it out. If the slot we just refreshed IS that
            # sidecar-hidden active slot, the rotated tokens are now
            # orphaned in the slot file: .credentials.json still holds
            # the old refresh_token Anthropic just rotated away. Without
            # this branch the user gets no signal until Claude Code's own
            # next refresh fails and forces a re-login. The yellow
            # advisory in the catch above only covers the write-failure
            # path, not the "active slot was filtered out" path.
            #
            # Deliberate: do NOT auto-propagate. Sidecar absence is the
            # visibility-gate signal documented in CLAUDE.md ("Slots
            # without a valid sidecar are HIDDEN from list / usage /
            # rotation"); silently writing to .credentials.json for a
            # hidden slot would violate the contract enforced by
            # Get-Slots. Escalate to the user instead.
            #
            # Invariant: state.active_slot and last_sync_hash stay as-is.
            # .credentials.json is unchanged, so its bytes still hash to
            # last_sync_hash and the next Invoke-Reconcile no-ops cleanly
            # (no spurious cross-account swap detection) until the user
            # runs `sca save <name>` (recapture sidecar) or `sca switch
            # <name>` (force propagation).
            $parsed = Get-SlotFileInfo -FileName ([System.IO.Path]::GetFileName($SlotPath))
            if ($parsed -and $parsed.Name -eq $state.active_slot) {
                Write-Color "[Sync] Token refreshed in slot '$($state.active_slot)' but its identity sidecar is missing, so propagation to .credentials.json was skipped. Run 'sca save $($state.active_slot)' to recapture the sidecar, or 'sca switch $($state.active_slot)' to force propagation now; otherwise Claude Code's own refresh may fail and require re-login." 'Yellow'
            }
        }
    }

    return $newAccess
}

# Look up the slot's last successful /api/oauth/usage response in the
# per-process cache and return it wrapped as an IsCachedFallback result.
# Returns $null on cache miss (or on a stale entry unless -AllowStale).
#
# Used by Get-SlotUsage's two 429 fallback paths (token-endpoint catch
# and usage-endpoint catch) to collapse what would otherwise be a 4-level
# if-contains/if-fresh/return ladder into a single helper call.
#
# Freshness policy:
#   * Fresh entry (within $Script:UsageCacheTTL minutes) -> served as
#     'ok'+IsCachedFallback so the watch display stays fully functional
#     during a brief rate-limit (usage data only changes every few hours).
#   * Stale entry -> $null by default. With -AllowStale it is served as
#     'rate-limited'+IsCachedFallback: the LAST-KNOWN percentages stay
#     visible during a prolonged throttle (so the row keeps its numbers
#     instead of collapsing to em-dashes and looking like a dead slot),
#     but the status stays 'rate-limited' so the stale data is never
#     mistaken for a live reading. The caller serves stale only as a last
#     resort, after the fresh lookup and (where applicable) the retry have
#     failed.
function Get-CachedUsageOrNull {
    Param (
        [String] $SlotPath,
        [switch] $AllowStale
    )
    if (-not $Script:SlotUsageCache.ContainsKey($SlotPath)) { return $null }
    $entry   = $Script:SlotUsageCache[$SlotPath]
    $isStale = ([DateTime]::UtcNow - $entry.Timestamp).TotalMinutes -ge $Script:UsageCacheTTL
    if ($isStale) {
        if (-not $AllowStale) { return $null }
        return [pscustomobject]@{ Status = 'rate-limited'; Data = $entry.Data; IsCachedFallback = $true }
    }
    return [pscustomobject]@{ Status = 'ok'; Data = $entry.Data; IsCachedFallback = $true }
}

# Read a slot's OAuth tokens and return a non-expired access token,
# refreshing via /v1/oauth/token first if the cached token is past or
# within 60s of its expiry. Shared prelude for Get-SlotUsage,
# Get-SlotProfile, and Invoke-SlotPrime; collapses three near-identical
# 30-line blocks that previously each did Get-SlotOAuth + HasOAuth gate
# + 60s expiry threshold + Update-SlotTokens with 429-as-rate-limited /
# non-429-as-expired catches.
#
# Returns one of:
#   @{ Status = 'ok'; AccessToken = <string> }     # caller proceeds with HTTP
#   @{ Status = 'no-oauth' }                       # slot has no claudeAiOauth
#   @{ Status = 'rate-limited' }                   # 429 from /v1/oauth/token
#   @{ Status = 'expired'; Error = <msg> }         # token expired + refresh failed (non-429)
#   @{ Status = 'error';   Error = <msg> }         # Get-SlotOAuth threw (corrupt slot file etc.)
#
# Callers translate the non-ok statuses straight into their own return
# values. Get-SlotUsage additionally checks $Script:SlotUsageCache for a
# fresh entry before returning 'rate-limited' (the cache-fallback path);
# the other two callers have no cache and return the helper's result
# verbatim.
#
# Does NOT set $ProgressPreference: Get-SlotOAuth performs no HTTP, and
# Update-SlotTokens sets it inside its own scope.
function Resolve-SlotAccessToken {
    Param ([String] $SlotPath)

    try {
        $info = Get-SlotOAuth -SlotPath $SlotPath
    }
    catch {
        return [pscustomobject]@{ Status = 'error'; Error = $_.Exception.Message }
    }

    if (-not $info.HasOAuth) {
        return [pscustomobject]@{ Status = 'no-oauth' }
    }

    $accessToken = $info.AccessToken

    # Refresh if expired OR within a 60s grace window; covers clock skew
    # and the case where the token technically has 30s left but would
    # expire mid-call.
    $threshold = [DateTime]::UtcNow.AddSeconds(60)
    if ($info.ExpiresAt -and $info.ExpiresAt -lt $threshold) {
        try {
            $accessToken = Update-SlotTokens -SlotPath $SlotPath
        }
        catch {
            # 429 from the token endpoint: surface a clean 'rate-limited'
            # status. No retry; the token endpoint shares an upstream
            # limiter with the usage endpoint, so a 5s sleep would just
            # extend the user's wait without changing the outcome.
            if (Test-Is429 $_.Exception) {
                return [pscustomobject]@{ Status = 'rate-limited' }
            }
            # Non-429 refresh failure (timeout, 4xx other than 429, 5xx,
            # malformed JSON, ...): the token IS expired and we couldn't
            # refresh it, so 'expired' remains the accurate label.
            return [pscustomobject]@{ Status = 'expired'; Error = $_.Exception.Message }
        }
    }

    return [pscustomobject]@{ Status = 'ok'; AccessToken = $accessToken }
}

# Call /api/oauth/usage for one slot. Auto-refreshes a token that is
# expired or within 60s of expiry via Resolve-SlotAccessToken. Returns:
#   @{ Status = 'ok';           Data = <parsed response> }
#   @{ Status = 'ok'; Data; IsCachedFallback = $true }      # served from cache after a 429
#   @{ Status = 'no-oauth' }                                # slot has no claudeAiOauth
#   @{ Status = 'expired'; Error = <msg> }                  # token expired AND refresh failed (non-429)
#   @{ Status = 'rate-limited' }                            # 429 from refresh OR usage endpoint, no fresh cache
#   @{ Status = 'unauthorized' }                            # 401/403 from usage endpoint
#   @{ Status = 'error';   Error = <msg> }                  # network / shape / other
# Never throws to callers; surfaces every failure mode as a Status value
# so Invoke-UsageAction can render mixed-health tables without aborting.
function Get-SlotUsage {
    Param (
        [String] $SlotPath
    )

    # Suppress PowerShell's built-in 'Web request' progress activity
    # (Write-Progress / stream 4) so it does not paint over the watch
    # loop's alt-screen buffer between frames. See Update-SlotTokens
    # for the full rationale; same suppression is applied identically
    # in Get-SlotProfile / Invoke-SlotPrime.
    $ProgressPreference = 'SilentlyContinue'

    # Resolve a non-expired access token (refresh if needed). Rate-
    # limited from the token endpoint gets the cache-fallback path here;
    # other non-ok statuses return verbatim.
    $tok = Resolve-SlotAccessToken -SlotPath $SlotPath
    if ($tok.Status -ne 'ok') {
        if ($tok.Status -eq 'rate-limited') {
            $cached = Get-CachedUsageOrNull -SlotPath $SlotPath
            if ($cached) { return $cached }
            # Last resort: keep the last-known percentages visible (marked
            # cached, status stays 'rate-limited') rather than dropping the
            # row to a dead-looking em-dash line during a token-endpoint
            # throttle.
            $stale = Get-CachedUsageOrNull -SlotPath $SlotPath -AllowStale
            if ($stale) { return $stale }
        }
        return $tok
    }
    $accessToken = $tok.AccessToken

    $headers = @{
        'Authorization'     = "Bearer $accessToken"
        'anthropic-beta'    = $Script:AnthropicBeta
        'anthropic-version' = $Script:AnthropicApiVersion
        'Content-Type'      = 'application/json'
        'User-Agent'        = $Script:UsageUserAgent
    }

    try {
        $resp = Invoke-RestMethod -Method Get `
                                  -Uri $Script:UsageEndpoint `
                                  -Headers $headers `
                                  -TimeoutSec $Script:UsageTimeoutSec `
                                  -ErrorAction Stop
        # Cache the successful response so we can fall back on 429.
        $Script:SlotUsageCache[$SlotPath] = @{
            Data      = $resp
            Timestamp = [DateTime]::UtcNow
        }
        return [pscustomobject]@{ Status = 'ok'; Data = $resp }
    }
    catch {
        $status = $null
        $resp   = $_.Exception.Response
        if ($resp -and $resp.StatusCode) {
            $status = [int]$resp.StatusCode
        }
        if ($status -eq 401 -or $status -eq 403) {
            return [pscustomobject]@{ Status = 'unauthorized' }
        }
        # On 429 (rate limited), fall back to cached data if available and
        # still fresh. This keeps the watch display functional during rate-
        # limited periods; usage data only changes every few hours at most.
        # Three explicit branches (vs. the previous if/else where a stale
        # cache fell through to the bottom 'error' return at the end of
        # the catch; that hid behind Format-UsageTable's truncation but
        # mislabeled the status):
        #   1. Fresh cache  -> return cached as 'ok' with IsCachedFallback.
        #   2. Stale cache  -> 'rate-limited' (no retry; the cache being
        #                      stale means we've been seeing 429s for a
        #                      while and a 5s sleep won't change that).
        #   3. No cache yet -> one retry after a short delay; the original
        #                      back-to-back-poll-collision case.
        if ($status -eq 429) {
            $cached = Get-CachedUsageOrNull -SlotPath $SlotPath
            if ($cached) { return $cached }
            # Cache miss vs stale-entry both reach this point. If the
            # slot has ANY cache entry (stale or otherwise), drop to
            # 'rate-limited'; we've been seeing 429s long enough that
            # a 5s sleep won't change the outcome. If no cache entry
            # exists at all, retry once after a short delay so back-to-
            # back slot polls don't all hit the rate limit simultaneously.
            if ($Script:SlotUsageCache.ContainsKey($SlotPath)) {
                # Stale entry: serve the last-known percentages (marked
                # cached, status stays 'rate-limited') so the row keeps its
                # numbers during a prolonged throttle instead of collapsing
                # to em-dashes. No retry sleep: a stale entry means we've
                # been throttled long enough that a 5s wait won't help.
                $stale = Get-CachedUsageOrNull -SlotPath $SlotPath -AllowStale
                if ($stale) { return $stale }
                return [pscustomobject]@{ Status = 'rate-limited' }
            }
            Start-Sleep -Seconds 5
            try {
                $resp2 = Invoke-RestMethod -Method Get `
                                          -Uri $Script:UsageEndpoint `
                                          -Headers $headers `
                                          -TimeoutSec $Script:UsageTimeoutSec `
                                          -ErrorAction Stop
                # Cache the successful retry.
                $Script:SlotUsageCache[$SlotPath] = @{
                    Data      = $resp2
                    Timestamp = [DateTime]::UtcNow
                }
                return [pscustomobject]@{ Status = 'ok'; Data = $resp2 }
            }
            catch {
                # Second attempt also failed; return clean rate-limited status.
                return [pscustomobject]@{ Status = 'rate-limited' }
            }
        }
        return [pscustomobject]@{ Status = 'error'; Error = $_.Exception.Message }
    }
}

# Resolve the OAuth account email for a slot. Returns one of:
#   @{ Status = 'ok';           Email = <string> }
#   @{ Status = 'no-oauth' }                        # slot has no claudeAiOauth
#   @{ Status = 'expired' }                         # token expired + refresh failed (non-429)
#   @{ Status = 'rate-limited' }                    # 429 from refresh endpoint OR profile endpoint
#   @{ Status = 'unauthorized' }                    # 401/403 from profile endpoint
#   @{ Status = 'error';        Error = <msg> }     # network / shape / other
#
# No caching: email is authoritative only at `sca save` time, which writes
# it directly into the slot filename. Subsequent `sca usage` / `sca list`
# reads parse the filename via Get-SlotFileInfo. No HTTP. This keeps the
# email self-consistent with the stored OAuth tokens: the only way to
# update the email on a slot is to re-run `sca save`, which also re-runs
# this call against the freshly-saved tokens.
#
# The HTTP call mirrors Claude Code's Ql() shape: Authorization +
# Content-Type, no anthropic-beta / User-Agent. The single deliberate
# deviation is the `anthropic-version` header, which Ql() omits but
# which we send on every authenticated request for defense-in-depth (see
# the $Script:AnthropicApiVersion docstring up top). The OAuth-namespaced
# endpoints accept the call with or without it today; sending it
# uniformly insulates the script from a future tightening at this
# endpoint without an emergency patch.
function Get-SlotProfile {
    Param (
        [String] $SlotPath
    )

    # See Get-SlotUsage for the $ProgressPreference rationale; same
    # suppression here for the /api/oauth/profile HTTP call below.
    $ProgressPreference = 'SilentlyContinue'

    # Resolve a non-expired access token; non-ok statuses (including
    # 429-as-rate-limited from the token endpoint) return verbatim. No
    # profile cache to fall back on (Get-SlotProfile is no-cache by
    # design; see the function docstring above).
    $tok = Resolve-SlotAccessToken -SlotPath $SlotPath
    if ($tok.Status -ne 'ok') { return $tok }
    $accessToken = $tok.AccessToken

    $headers = @{
        'Authorization'     = "Bearer $accessToken"
        'anthropic-version' = $Script:AnthropicApiVersion
        'Content-Type'      = 'application/json'
    }

    try {
        $resp = Invoke-RestMethod -Method Get `
                                  -Uri $Script:ProfileEndpoint `
                                  -Headers $headers `
                                  -TimeoutSec $Script:ProfileTimeoutSec `
                                  -ErrorAction Stop
    }
    catch {
        $status = $null
        $r      = $_.Exception.Response
        if ($r -and $r.StatusCode) { $status = [int]$r.StatusCode }
        if ($status -eq 401 -or $status -eq 403) {
            return [pscustomobject]@{ Status = 'unauthorized' }
        }
        if ($status -eq 429) {
            return [pscustomobject]@{ Status = 'rate-limited' }
        }
        return [pscustomobject]@{ Status = 'error'; Error = $_.Exception.Message }
    }

    $email = $null
    if ($resp -and $resp.account -and $resp.account.email) {
        $email = [string]$resp.account.email
    }
    if (-not $email) {
        return [pscustomobject]@{ Status = 'error'; Error = 'profile response missing account.email' }
    }

    return [pscustomobject]@{ Status = 'ok'; Email = $email }
}

# Send a minimal billable request to /v1/messages so Anthropic opens a
# server-side 5h session window for this slot. Subsequent /api/oauth/usage
# calls against the slot then return real bucket data instead of an empty
# response (or 429, depending on the account's state). Cost: ~2 tokens
# per call on the pinned Haiku model (1 input "." + max_tokens=1 output).
# Used exclusively by Invoke-WarmAllSlots when `sca usage -Watch -Warmup`
# is set.
#
# Returns the same status vocabulary as Get-SlotUsage so the warmup
# orchestrator can copy the result onto the row without translation:
#   @{ Status = 'ok' }                                # 2xx; window opened
#   @{ Status = 'no-oauth' }                          # slot has no claudeAiOauth
#   @{ Status = 'expired'; Error = <msg> }            # token expired AND refresh failed (non-429)
#   @{ Status = 'rate-limited' }                      # 429 from refresh OR messages endpoint
#   @{ Status = 'unauthorized' }                      # 401/403 from messages endpoint
#   @{ Status = 'error'; Error = <msg> }              # network / shape / other
#
# Unlike Get-SlotUsage there is no Data payload (the prime is for the
# side effect, not the response body) and no per-slot cache (the response
# carries nothing worth replaying). 429 handling mirrors Get-SlotUsage's
# token-endpoint catch but without the cache fallback path: a clean
# 'rate-limited' status is the only signal available.
function Invoke-SlotPrime {
    Param (
        [String] $SlotPath
    )

    # See Get-SlotUsage for the $ProgressPreference rationale; same
    # suppression here for the /v1/messages POST below.
    $ProgressPreference = 'SilentlyContinue'

    # Resolve a non-expired access token; non-ok statuses (including
    # 429-as-rate-limited from the token endpoint) return verbatim. No
    # cache to fall back on (priming is fire-and-forget).
    $tok = Resolve-SlotAccessToken -SlotPath $SlotPath
    if ($tok.Status -ne 'ok') { return $tok }
    $accessToken = $tok.AccessToken

    $headers = @{
        'Authorization'     = "Bearer $accessToken"
        'anthropic-beta'    = $Script:AnthropicBeta
        'anthropic-version' = $Script:AnthropicApiVersion
        'Content-Type'      = 'application/json'
        'User-Agent'        = $Script:UsageUserAgent
    }

    # Minimal billable payload. `max_tokens=1` caps output; content is a
    # single "." so the input is one token. Aggregate cost: ~2 tokens
    # per slot per warmup on the pinned Haiku model (fractions of a cent).
    $body = '{{"model":"{0}","max_tokens":1,"messages":[{{"role":"user","content":"."}}]}}' -f $Script:PrimeModel

    try {
        Invoke-RestMethod -Method Post `
                          -Uri $Script:MessagesEndpoint `
                          -Headers $headers `
                          -Body $body `
                          -TimeoutSec $Script:PrimeTimeoutSec `
                          -ErrorAction Stop | Out-Null
        return [pscustomobject]@{ Status = 'ok' }
    }
    catch {
        $status = $null
        $resp   = $_.Exception.Response
        if ($resp -and $resp.StatusCode) {
            $status = [int]$resp.StatusCode
        }
        if ($status -eq 401 -or $status -eq 403) {
            return [pscustomobject]@{ Status = 'unauthorized' }
        }
        if ($status -eq 429) {
            return [pscustomobject]@{ Status = 'rate-limited' }
        }
        return [pscustomobject]@{ Status = 'error'; Error = $_.Exception.Message }
    }
}

# Coerce a reset-timestamp value (ISO-8601 string, DateTime, DateTimeOffset,
# or null/empty) to a [DateTimeOffset], or $null on missing / unparseable
# input. Centralizes the parser shared by Format-ResetDelta /
# Format-ResetAbsolute so both renderers cannot drift on accepted input
# shapes. ISO-8601 strings come from live /api/oauth/usage; DateTime /
# DateTimeOffset values come from tests passing pre-parsed timestamps.
function ConvertTo-DateTimeOffsetOrNull {
    Param ($Value)

    if ($null -eq $Value -or $Value -eq '') { return $null }
    try {
        if ($Value -is [DateTimeOffset]) { return $Value }
        if ($Value -is [DateTime])       { return [DateTimeOffset]$Value }
        return [DateTimeOffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
    }
    catch {
        return $null
    }
}

# Render an ISO-8601 reset timestamp as a compact relative delta for the
# summary table column. Verified shape from live /api/oauth/usage:
#   "resets_at": "2026-04-24T19:50:00.027299+02:00"  (ISO with tz offset)
#                 OR null (no active window yet; pairs with 0% utilization)
# Output (variant C: hours+minutes under 24h, integer hours above):
#   null / empty / parse fail        -> '—' (defensive: never throws)
#   timestamp in the past            -> 'now'
#   < 1 hour                         -> 'in 42m'
#   >= 1 hour and < 24 hours         -> '(2h 14m)'    (minute precision matters in the session window)
#   >= 24 hours                      -> '(42h)'       (integer total hours; minutes are noise at weekly scale)
function Format-ResetDelta {
    Param ($ResetsAt)

    $target = ConvertTo-DateTimeOffsetOrNull $ResetsAt
    if ($null -eq $target) { return '—' }

    $delta = $target - [DateTimeOffset]::UtcNow
    if ($delta.TotalSeconds -le 0) { return 'now' }

    if ($delta.TotalHours -ge 24) {
        # Total hours, floor; at this scale minutes would only add noise.
        $h = [int][math]::Floor($delta.TotalHours)
        return "(${h}h)"
    }

    $h = [int]$delta.Hours
    $m = [int]$delta.Minutes
    if ($h -gt 0) { return "(${h}h ${m}m)" }
    return "(${m}m)"
}

# Render an ISO-8601 reset timestamp as an absolute wall-clock time in the
# user's local timezone, mirroring Claude Code's own /usage rendering:
#   same calendar day    -> 'Resets 7:50pm Europe/Berlin'
#   different day        -> 'Resets Apr 26, 9am Europe/Berlin'
#   null / parse failure -> '—'
# The endpoint emits its own tz offset in the ISO string; we convert to
# the shell's local tz for display so "7:50pm" matches the user's watch.
function Format-ResetAbsolute {
    Param ($ResetsAt)

    $target = ConvertTo-DateTimeOffsetOrNull $ResetsAt
    if ($null -eq $target) { return '—' }

    $localTz   = [TimeZoneInfo]::Local
    $localTime = [TimeZoneInfo]::ConvertTime($target, $localTz).DateTime
    $now       = [DateTime]::Now

    # .NET's "h:mmtt" renders "7:50PM"; Claude Code uses lowercase am/pm.
    $timePart = $localTime.ToString('h:mmtt', [Globalization.CultureInfo]::InvariantCulture).ToLowerInvariant()

    if ($localTime.Date -eq $now.Date) {
        return "Resets $timePart $($localTz.Id)"
    }
    $datePart = $localTime.ToString('MMM d', [Globalization.CultureInfo]::InvariantCulture)
    # Second form also drops the ":00" for on-the-hour times like "9am" to
    # match the screenshot; keep ":mm" otherwise for unambiguous precision.
    if ($localTime.Minute -eq 0) {
        $timePart = $localTime.ToString('htt', [Globalization.CultureInfo]::InvariantCulture).ToLowerInvariant()
    }
    return "Resets $datePart, $timePart $($localTz.Id)"
}

# Render one utilization value (0..100 number or $null) as a fixed-width
# 4-char cell that aligns whether the value is numeric (' 34%') or the
# em-dash no-data sentinel ('   —'). Em-dash is a single visible char in
# monospace fonts, so right-pad with 3 spaces to match ' 34%'.
function Format-UtilCell {
    Param ($Utilization)

    if ($null -eq $Utilization) { return '   —' }
    return '{0,3}%' -f [int][math]::Round([double]$Utilization)
}

# Middle-truncate a string to at most $Max characters using '…' (U+2026)
# in the middle. A single ellipsis is one visible cell in monospace, so
# the truncated form is exactly $Max cells wide. Returns the input
# unchanged when it already fits, or '—' for null/empty (the caller
# decides whether that means "no email" or "truncate").
function Format-Truncate {
    Param (
        [AllowNull()] [String] $Text,
        [int] $Max
    )

    if ([string]::IsNullOrEmpty($Text)) { return '—' }
    if ($Text.Length -le $Max) { return $Text }
    if ($Max -le 1) { return '…' }

    # Keep more of the tail than the head so the domain (after the '@')
    # stays visible for emails; the domain is the disambiguating part
    # when multiple slots share a local-part. For $Max = 32 this gives
    # 15 leading + '…' + 16 trailing = 32 cells.
    $headLen = [math]::Max(1, [int][math]::Floor(($Max - 1) / 2))
    $tailLen = $Max - 1 - $headLen
    return $Text.Substring(0, $headLen) + '…' + $Text.Substring($Text.Length - $tailLen, $tailLen)
}

# Render the Account column cell for a single row. '—' when the slot has
# no labeled email or when the email is a redundant duplicate of the
# slot name (case-insensitive); otherwise the middle-truncated email.
function Format-AccountCell {
    Param (
        [AllowNull()] [String] $SlotName,
        [AllowNull()] [String] $Email
    )

    if ([string]::IsNullOrEmpty($Email)) { return '—' }
    if ($SlotName -and $SlotName.ToLowerInvariant() -eq $Email.ToLowerInvariant()) { return '—' }
    return Format-Truncate -Text $Email -Max $Script:AccountColumnMaxWidth
}

# Render a slot identity for inline prose (the `switch` action's status
# messages). Renders as `'<slot>'` for unlabeled / dedup-form slots and
# `'<slot>' (<email>)` for labeled slots whose email differs from the
# slot name. Single source of truth so the rotation banner and the
# success line carry the same shape, and so future callers can render
# slot identities consistently without rebuilding the dedup logic.
function Format-SlotIdentity {
    Param (
        [AllowNull()] [String] $Name,
        [AllowNull()] [String] $Email
    )

    if ([string]::IsNullOrEmpty($Email)) { return "'$Name'" }
    if ($Name -and $Name.ToLowerInvariant() -eq $Email.ToLowerInvariant()) { return "'$Name'" }
    return "'$Name' ($Email)"
}

# Merge a utilization value and its reset timestamp into a single cell
# for the summary table. Layout rules:
#   null utilization, any reset     -> '   —'                (no data at all)
#   numeric utilization, null reset -> ' 34%'                (cold bucket, no active window)
#   numeric utilization, reset      -> ' 34% (2h 14m)'     (normal row)
# Width is variable because reset deltas range from 'now' (3 chars) to
# '(103h)' (6 chars) to '(2h 14m)' (8 chars); the table's column
# width is computed from the widest cell per invocation.
function Format-BucketCell {
    Param (
        $Utilization,
        $ResetsAt
    )

    if ($null -eq $Utilization) { return '   —' }
    $pct = Format-UtilCell $Utilization
    if ($null -eq $ResetsAt -or $ResetsAt -eq '') { return $pct }
    return "$pct $(Format-ResetDelta $ResetsAt)"
}

# Classify a slot's usage response into a plan-usability status. Returns
# one of:
#   ok                 - both buckets below the warn threshold
#   near limit         - any bucket at or above UtilWarnPct but all below UtilLimitPct
#   limited 5h         - 5h bucket at or above UtilLimitPct (prompts refused until 5h reset)
#   limited 7d         - 7d bucket at or above UtilLimitPct
#   limited            - both buckets at or above UtilLimitPct
#   ok (no plan data)  - HTTP ok but response had neither bucket
# HTTP-failure states (expired / unauthorized / error / no-oauth) are
# surfaced via the caller's own mapping; this helper only runs when the
# caller has already determined HTTP was 'ok'.
function Get-PlanStatus {
    Param ($Data)

    $fiveUtil  = $null
    $sevenUtil = $null
    if ($Data) {
        if ($Data.five_hour -and $null -ne $Data.five_hour.utilization) {
            $fiveUtil = [double]$Data.five_hour.utilization
        }
        if ($Data.seven_day -and $null -ne $Data.seven_day.utilization) {
            $sevenUtil = [double]$Data.seven_day.utilization
        }
    }

    if ($null -eq $fiveUtil -and $null -eq $sevenUtil) {
        return 'ok (no plan data)'
    }

    $fiveLimit  = ($null -ne $fiveUtil  -and $fiveUtil  -ge $Script:UtilLimitPct)
    $sevenLimit = ($null -ne $sevenUtil -and $sevenUtil -ge $Script:UtilLimitPct)
    if ($fiveLimit -and $sevenLimit) { return 'limited' }
    if ($fiveLimit)                  { return 'limited 5h' }
    if ($sevenLimit)                 { return 'limited 7d' }

    $fiveNear  = ($null -ne $fiveUtil  -and $fiveUtil  -ge $Script:UtilWarnPct)
    $sevenNear = ($null -ne $sevenUtil -and $sevenUtil -ge $Script:UtilWarnPct)
    if ($fiveNear -or $sevenNear) { return 'near limit' }

    return 'ok'
}

# Return the Write-Host color for a given rendered status label, mixing
# HTTP-health and plan-usability outcomes. Centralized so the summary
# table and the verbose view stay in lockstep.
function Get-StatusColor {
    Param (
        [String] $Label,
        [bool]   $IsActive
    )

    $okColor = if ($IsActive) { 'Green' } else { 'Gray' }
    switch -Regex ($Label) {
        '^limited'      { return 'Red' }
        '^near limit'   { return 'Yellow' }
        '^ok \(no plan' { return $okColor }
        '^ok$'          { return $okColor }
        '^no-oauth'     { return 'DarkGray' }
        '^expired'      { return 'Yellow' }
        '^unauthorized' { return 'Red' }
        '^error'        { return 'Red' }
        '^rate-limited' { return 'Yellow' }
        # 'warming up' is the transient -Watch -Warmup queued state
        # (slot not yet processed). Yellow matches its "attention
        # required" cousins (near limit, rate-limited, expired) so
        # the user immediately knows the row is in flight, not in
        # steady state.
        '^warming up'    { return 'Yellow' }
        # 'priming' is the per-slot in-flight state during the warmup
        # pass: Invoke-SlotPrime's /v1/messages POST is running for
        # this row right now. Once the call completes, the row
        # transitions directly to a real HTTP status ('ok' /
        # 'rate-limited' / 'no-oauth' / 'expired' / 'unauthorized' /
        # 'error'), which are already mapped above.
        '^priming$'      { return 'Yellow' }
        default          { return 'Gray' }
    }
}

# One-sentence English rationale for a plan-usability status, used in
# the verbose `sca usage <slot>` view. Returns $null when no rationale
# applies (the status label is self-explanatory, e.g. 'ok').
function Get-StatusRationale {
    Param ([String] $Label)

    switch ($Label) {
        'limited 5h'        { return 'no prompts until 5h window resets' }
        'limited 7d'        { return 'no prompts until 7d window resets' }
        'limited'           { return 'no prompts until both 5h and 7d windows reset' }
        'near limit'        { return "at or above $($Script:UtilWarnPct)% on at least one bucket" }
        'ok (no plan data)' { return 'HTTP ok but response carried no bucket data' }
        default             { return $null }
    }
}

# Map a pool-wide USAGE percentage (0..100) to the Write-Host color used
# by the aggregate bars. Extracted as a pure helper rather than inlined
# so it can be unit-tested without mocking Write-Host (whose parameter
# capture across Pester scope boundaries is fragile).
function Get-AggregateBarColor {
    Param ([int] $UsedPct)

    if ($UsedPct -ge $Script:AggregateRedPct)    { return 'Red'    }
    if ($UsedPct -ge $Script:AggregateYellowPct) { return 'Yellow' }
    return 'Green'
}

# Compute the pool-mean utilization for a single bucket key across the
# HTTP-ok rows of a usage-snapshot Results list. Pure function. Used by
# both Format-AggregateBars (renders the bar above the table) and
# Format-WatchTitle's -Aggregate branch (renders the OSC 0 title in
# -Watch -Auto mode); colocating the math here keeps the title number
# and the on-screen bar percentage structurally in lockstep instead of
# coupled by copy-paste.
#
# Inputs:
#   * $Results   - raw Results array from Get-UsageSnapshot (mixed
#                  Status values). Internal filter keeps callers from
#                  having to pre-filter; both call sites pass the raw
#                  list.
#   * $BucketKey - 'five_hour' or 'seven_day'.
#
# Return:
#   * Integer in [0, 100], rounded with [math]::Round, when at least one
#     HTTP-ok row exists. Math: sum of per-row utilization (each clamped
#     to [0,100], null/missing counted as 0) divided by cap = N*100,
#     scaled to percent. Equivalently the mean utilization across all
#     HTTP-ok rows.
#   * $null when zero HTTP-ok rows. Callers decide what to render for
#     the empty case (Format-AggregateBars emits nothing; Format-WatchTitle
#     collapses to bare suffix).
function Get-PoolMeanUtilization {
    Param (
        [object[]] $Results,
        [string]   $BucketKey
    )

    if (-not $Results) { return $null }

    $eligible = @($Results | Where-Object { $_.Status -eq 'ok' })
    if ($eligible.Count -eq 0) { return $null }

    $n   = $eligible.Count
    $cap = $n * 100

    $usedSum = 0.0
    foreach ($r in $eligible) {
        if ($r.Data -and $r.Data.$BucketKey -and $null -ne $r.Data.$BucketKey.utilization) {
            $u = [double]$r.Data.$BucketKey.utilization
            if ($u -lt 0)   { $u = 0 }
            if ($u -gt 100) { $u = 100 }
            $usedSum += $u
        }
        # null / missing utilization -> 0 used.
    }

    # usedSum is in [0, cap] by construction (each $u clamped to [0,100],
    # summed N times with cap = N*100), so no outer clamp needed here.
    return [int][math]::Round(($usedSum / $cap) * 100)
}

# Render aggregate progress bars showing pool-wide USAGE above the
# usage table. Two bars: 'Session' (five_hour) and 'Week' (seven_day).
# For each bucket the function sums per-slot utilization across HTTP-ok
# rows, computes pool-used % as used / cap where cap = N * 100
# (equivalently the mean utilization across eligible rows), and draws a
# fit-to-table-width bar. Filled portion = used; empty portion = remaining
# headroom -- standard progress-bar convention, matching the per-slot
# Session/Week table cells beneath.
#
# Width math: bar width = TotalLineWidth - 17, floored at 8. The 17 is
# 2 (indent) + 8 (label pad) + 1 ('[') + 1 (']') + 1 (space) + 4
# ("NNN%"). Floor keeps narrow 1-slot tables visually meaningful.
#
# Slot inclusion rules:
#   * Status='ok' only (HTTP-failure rows have no usable data).
#   * Buckets with null/missing utilization counted as 0% used.
#
# Color thresholds via $Script:AggregateRedPct / $Script:AggregateYellowPct.
#
# Output: 4 Write-Host lines per call (Session bar, blank, Week bar,
# blank); the leading blank that precedes them comes from the caller's
# post-header padding in Format-UsageTable. When no qualifying rows
# exist, emits nothing; the table below renders cleanly without
# orphan padding.
#
# Uses Write-Host (information stream / 6) rather than Write-Progress
# (stream 4) for three reasons: (1) the suite's `6>&1 | Out-String`
# capture pattern would miss stream-4 output; (2) Write-Progress is
# host-managed and transient (it would not sit inline above the table);
# (3) it does not compose with Clear-Host watch redraws.
function Format-AggregateBars {
    Param (
        [object[]] $Results,
        [int]      $TotalLineWidth
    )

    if (-not $Results) { return }

    # Skip-render when no HTTP-ok rows exist. Get-PoolMeanUtilization
    # returns $null in that case; checking once up front (rather than
    # per-bucket) keeps the per-bucket loop branch-free.
    $eligible = @($Results | Where-Object { $_.Status -eq 'ok' })
    if ($eligible.Count -eq 0) { return }

    # Width derivation explained above. Floor 8 so 1-slot tables with
    # short status text still render a visible bar instead of an
    # empty `[]` next to the right label.
    $barWidth = [math]::Max(8, $TotalLineWidth - 17)

    $buckets = @(
        @{ Key = 'five_hour'; Label = 'Session' },
        @{ Key = 'seven_day'; Label = 'Week'    }
    )

    # Each iteration emits one bar line followed by one blank. With the
    # caller's pre-bars blank line (from Format-UsageTable) the visual
    # cadence is:
    #   <caller blank> / Session bar / <blank> / Week bar / <blank>
    # which gives the requested padding before, between, and after.
    foreach ($b in $buckets) {
        $key   = $b.Key
        $label = $b.Label

        # Shared math via Get-PoolMeanUtilization so the bar percentage
        # and Format-WatchTitle's -Aggregate title number cannot drift.
        # $eligible.Count > 0 guarantees a non-null return.
        $usedPct = Get-PoolMeanUtilization -Results $Results -BucketKey $key

        $filled = [int][math]::Round(($usedPct / 100.0) * $barWidth)
        if ($filled -lt 0)         { $filled = 0 }    # defense-in-depth
        if ($filled -gt $barWidth) { $filled = $barWidth }

        $bar = ('█' * $filled) + ('▓' * ($barWidth - $filled))

        $color = Get-AggregateBarColor -UsedPct $usedPct

        $line = '  {0,-8}[{1}] {2,3}%' -f $label, $bar, $usedPct
        Write-Color $line $color
        Write-Host ''
    }
}

# Render per-slot usage rows as a fixed-width table. Uses Write-Host (the
# information stream) to match the other Invoke-*Action functions so the
# existing `$out = Invoke-*Action 6>&1 | Out-String` test pattern keeps
# working. Fixed-width + manually padded columns (rather than Format-Table)
# so tests can assert on stable column headers without fighting PowerShell's
# responsive-width formatter.
#
# Column shape (5 data columns + leading active-marker):
#   *  Slot    Account                      Session         Week         Status
#
# - `Session` / `Week` cells merge utilization and reset delta into one
#   string ('100% (2h 37m)'); width auto-fits to the widest cell in the batch.
# - `Account` renders the slot's filename-encoded email, middle-truncated
#   at $Script:AccountColumnMaxWidth. Slots with no email (offline save)
#   or whose email equals the slot name (dedup form) render as '—'.
# - `Status` mixes HTTP health (expired / unauthorized / error / no-oauth)
#   with plan-usability derived via Get-PlanStatus; see that helper for
#   the threshold semantics.
#
# -IncludeAggregateBars : when set, render the pool-wide aggregate bar
# block (Format-AggregateBars) between the [Usage] header and the
# column header. Set by Format-UsageFrame for the table view; not set
# by Format-UsageVerbose's non-ok fallback (which reuses this function
# for a single failed-row render).
function Format-UsageTable {
    Param (
        [object[]] $Results,
        [switch]   $IncludeAggregateBars,
        # When > 0, append a right-aligned '▶ switching slot at N%'
        # indicator to the '[Usage] Plan usage' header line. Used by
        # the watch loop's -Auto mode to indicate auto-rotation is
        # engaged. The indicator's right edge anchors to the terminal
        # width minus 1 (preserves a 1-char right margin); when the
        # terminal is too narrow to fit the left header AND a 2-space
        # gap AND the indicator, the indicator is silently dropped
        # (the footer's [Auto] line still carries the state). When
        # -Auto is set, an extra blank line is inserted under the
        # header to balance the visually-busier right-aligned indicator.
        [int]      $AutoThreshold = 0
    )

    if (-not $Results) { return }

    # Precompute per-row cell content so column widths can auto-fit.
    $rows = foreach ($r in $Results) {
        $fiveCell  = '   —'
        $sevenCell = '   —'

        # Render bucket percentages whenever the row carries data, not only
        # on 'ok'. A 'rate-limited' row served from the (possibly stale)
        # cache fallback carries last-known Data; showing those numbers
        # keeps the row from looking like a dead/unused slot during a
        # transient throttle. Rows with no Data (expired / unauthorized /
        # error / no-oauth / no-cache rate-limited) keep the em-dash.
        if ($r.Data) {
            if ($r.Data.five_hour -and $null -ne $r.Data.five_hour.utilization) {
                $fiveCell = Format-BucketCell $r.Data.five_hour.utilization $r.Data.five_hour.resets_at
            }
            if ($r.Data.seven_day -and $null -ne $r.Data.seven_day.utilization) {
                $sevenCell = Format-BucketCell $r.Data.seven_day.utilization $r.Data.seven_day.resets_at
            }
        }

        $email = if ($r.PSObject.Properties['Email']) { $r.Email } else { $null }
        $accountCell = Format-AccountCell -SlotName $r.Name -Email $email

        # Status: plan-usability when HTTP was ok, HTTP-state otherwise.
        # The 'expired' and 'error' arms both route through
        # Format-StatusErrorTail so a long underlying exception cannot
        # wrap the row; the previous 'expired' arm interpolated the raw
        # message with no length cap, which produced multi-line table
        # rows when the token endpoint returned 429 with a long body.
        $statusText = switch ($r.Status) {
            'ok'           { Get-PlanStatus $r.Data }
            'no-oauth'     { 'no-oauth (api key or non-claude.ai slot)' }
            'expired'      { if ($r.Error) { "expired: $(Format-StatusErrorTail $r.Error)" } else { 'expired (run sca switch to refresh)' } }
            'unauthorized' { 'unauthorized (token revoked; run sca switch then /login)' }
            'error'        { "error: $(Format-StatusErrorTail $r.Error)" }
            'rate-limited' { 'rate-limited' }
            # 'warming-up' is the transient initial label rendered when
            # Invoke-WarmAllSlots starts iterating slots on `-Watch
            # -Warmup` startup. Synthetic snapshot rows carry it; the
            # warmup pass mutates each row's Status to 'priming'
            # while its /v1/messages call is in flight, then to the
            # real HTTP outcome ('ok' / 'rate-limited' / 'no-oauth' /
            # 'expired' / 'unauthorized' / 'error') once the call
            # returns. The hyphenated internal value renders space-
            # separated to match the existing label convention
            # ('rate limited' / 'limited 5h' / 'near limit').
            'warming-up'    { 'warming up' }
            'priming'       { 'priming' }
            default         { [string]$r.Status }
        }

        [pscustomobject]@{
            Row     = $r
            Marker  = if ($r.IsActive) { '*' } else { ' ' }
            Name    = $r.Name
            Account = $accountCell
            Five    = $fiveCell
            Seven   = $sevenCell
            Status  = $statusText
        }
    }

    # Minimum widths are the header label lengths so headers never get
    # clipped. Data-driven max keeps narrow tables narrow for 1-2 slots.
    # 'Session' (7) / 'Week' (4) are the new header literals; min widths
    # match. Status header is 6 chars but the column flows; track the
    # widest rendered status so $totalLineWidth below is accurate.
    $nameW = 4; $acctW = 7; $fiveW = 7; $sevenW = 4; $statusW = 6
    foreach ($e in $rows) {
        if ($e.Name.Length    -gt $nameW)   { $nameW   = $e.Name.Length }
        if ($e.Account.Length -gt $acctW)   { $acctW   = $e.Account.Length }
        if ($e.Five.Length    -gt $fiveW)   { $fiveW   = $e.Five.Length }
        if ($e.Seven.Length   -gt $sevenW)  { $sevenW  = $e.Seven.Length }
        if ($e.Status.Length  -gt $statusW) { $statusW = $e.Status.Length }
    }

    $fmt = "  {0} {1,-$nameW}  {2,-$acctW}  {3,-$fiveW}  {4,-$sevenW}  {5}"

    # Total rendered line width; used to fit-to-table the aggregate
    # bars above the header. Mirrors the $fmt pattern: 2 (indent) + 1
    # (marker) + 1 (sep) + nameW + 2 + acctW + 2 + fiveW + 2 + sevenW
    # + 2 + statusW.
    $totalLineWidth = 2 + 1 + 1 + $nameW + 2 + $acctW + 2 + $fiveW + 2 + $sevenW + 2 + $statusW

    # Header: '[Usage] Plan usage' left-anchored, optional right-aligned
    # auto-mode indicator. The indicator is computed against the terminal
    # width ([Console]::WindowWidth) so it floats to the right edge with
    # a 1-column right margin. Width-aware fallback: when the terminal
    # is too narrow to fit both segments with a 2-space minimum gap, the
    # indicator is silently dropped (the footer's [Auto] line still
    # carries the state, so no information is lost). [Console]::WindowWidth
    # can throw in non-interactive hosts (tests, ssh-tty absent); we
    # treat that as "narrow" and drop the indicator.
    #
    # Indicator visual: '<glyph><space><text>' where:
    #   glyph = '▶' (U+25B6, "black right-pointing triangle"), white
    #           (high-contrast lozenge so the auto-mode signal pops
    #            against the dimmer header / footer text).
    #   text  = 'switching slot at N%', DarkGray (matches the footer
    #           '[Watch]' / '[Auto]' line color so the indicator recedes
    #           into ambient-metadata weight).
    # Rendered via three Write-Color calls with -NoNewline so each segment
    # carries its own SGR color while the line is still a single logical
    # row. The trailing un-piped Write-Host '' terminates the row.
    $headerLeft  = '[Usage] Plan usage'
    $autoGlyph   = $null
    $autoText    = $null
    $autoPadding = $null
    if ($AutoThreshold -gt 0) {
        $autoGlyph    = "$([char]0x25B6)"
        $autoText     = " switching slot at $AutoThreshold%"
        $indicatorLen = $autoGlyph.Length + $autoText.Length
        $termWidth    = try { [Console]::WindowWidth } catch { 0 }
        # Reserve 1 col right margin so the indicator isn't flush with
        # the terminal edge. Need: leftLen + 2 (min gap) + indicatorLen
        # + 1 (right margin) <= width.
        if ($termWidth -lt ($headerLeft.Length + 2 + $indicatorLen + 1)) {
            $autoGlyph = $null
            $autoText  = $null
        } else {
            $padCount    = $termWidth - $headerLeft.Length - $indicatorLen - 1
            $autoPadding = ' ' * $padCount
        }
    }
    if ($autoGlyph) {
        # Three-segment colored line: DarkYellow header + padding (no
        # color) + white glyph (high-contrast lozenge) + DarkGray text
        # (matches footer ambient-metadata color). -NoNewline chains
        # them onto one logical row; final Write-Host '' below terminates.
        Write-Color $headerLeft  'DarkYellow' -NoNewline
        Write-Host  $autoPadding -NoNewline
        Write-Color $autoGlyph   'Gray'       -NoNewline
        Write-Color $autoText    'DarkGray'
    } else {
        Write-Color $headerLeft 'DarkYellow'
    }
    Write-Host ''
    # Extra breathing room under the header when -Auto is engaged: the
    # right-side indicator makes the header row visually busier, so an
    # additional blank balances the layout. Without -Auto the original
    # one-blank cadence is preserved (matches existing screenshots / SVG).
    if ($AutoThreshold -gt 0) {
        Write-Host ''
    }
    # Aggregate bars sit between the post-header blank and the column
    # header. Format-AggregateBars emits per bar: 'bar line' + blank,
    # so the caller's blank above acts as the leading padding. When
    # there are no eligible rows the helper returns silently; the
    # leading blank still separates header from column header.
    if ($IncludeAggregateBars) {
        Format-AggregateBars -Results $Results -TotalLineWidth $totalLineWidth
    }
    Write-Host ($fmt -f ' ',  'Slot',         'Account',       'Session',     'Week',          'Status')
    Write-Host ($fmt -f ' ', ('-' * $nameW), ('-' * $acctW),  ('-' * $fiveW), ('-' * $sevenW), '------')

    foreach ($entry in $rows) {
        $color = Get-StatusColor -Label $entry.Status -IsActive ([bool]$entry.Row.IsActive)
        Write-Color ($fmt -f $entry.Marker, $entry.Name, $entry.Account, $entry.Five, $entry.Seven, $entry.Status) $color
    }
}

# Render the saved-slot inventory as a fixed-width 2-data-column table:
# `Slot | Account`, plus the leading active-marker column. Mirrors
# Format-UsageTable's column-width algorithm and row-coloring rules so
# `sca list` and `sca usage` look like sibling views (same header style,
# same active-marker conventions, same Account-cell truncation). Pure
# offline render: no network calls, unlike Format-UsageTable. Used by
# Invoke-ListAction; kept as a sibling rather than a generic helper
# because the column counts and per-cell rules differ enough that an
# abstraction would cost more than it saves with only two callers.
function Format-ListTable {
    Param (
        [object[]] $Slots,
        # When set, skip the `[List] Saved slots` header and the leading
        # blank line. Used by Invoke-SwitchAction so the table renders
        # cleanly under the switch's own success line without a redundant
        # second DarkYellow header.
        [switch]   $SuppressHeader
    )

    if (-not $Slots) { return }

    # Precompute account cells so column widths can auto-fit. The Slot
    # column carries the parsed slot name (Get-SlotFileInfo); the Account
    # column reuses Format-AccountCell so dedup and truncation match the
    # usage table.
    $rows = foreach ($s in $Slots) {
        [pscustomobject]@{
            Slot     = $s
            Marker   = if ($s.IsActive) { '*' } else { ' ' }
            Name     = $s.Name
            Account  = Format-AccountCell -SlotName $s.Name -Email $s.Email
        }
    }

    # Minimum widths are the header label lengths so the headers never
    # get clipped on a 1-2 slot table.
    $nameW = 4; $acctW = 7
    foreach ($e in $rows) {
        if ($e.Name.Length    -gt $nameW) { $nameW = $e.Name.Length }
        if ($e.Account.Length -gt $acctW) { $acctW = $e.Account.Length }
    }

    $fmt = "  {0} {1,-$nameW}  {2}"

    if (-not $SuppressHeader) {
        Write-Color "[List] Saved slots" 'DarkYellow'
        Write-Host ''
    }
    Write-Host ($fmt -f ' ',  'Slot',         'Account')
    Write-Host ($fmt -f ' ', ('-' * $nameW), ('-' * $acctW))

    foreach ($entry in $rows) {
        $color = if ($entry.Slot.IsActive) { 'Green' } else { $null }
        if ($color) {
            Write-Color ($fmt -f $entry.Marker, $entry.Name, $entry.Account) $color
        } else {
            Write-Host ($fmt -f $entry.Marker, $entry.Name, $entry.Account)
        }
    }

    # Trailing blank line so the table has breathing room before the
    # next prompt (or before any advisory the caller emits below). Mirrors
    # Format-UsageFrame's footer behavior; both `sca list` / `sca switch`
    # / `sca usage` now end with a blank line so the views look consistent.
    Write-Host ''
}

# Render the full response for a single slot in verbose form. Used when
# `sca usage <name>` targets one slot; shows absolute local-tz reset times
# (Claude-Code-style) for the two buckets we care about: five_hour
# ("Current session") and seven_day ("Current week (all models)"). Other
# buckets returned by the endpoint are intentionally not rendered here
# because they are not the limits the user is tracking; they remain
# accessible via `sca usage <name> -Json`.
function Format-UsageVerbose {
    Param ([object] $Result)

    $name = $Result.Name
    Write-Color "[Usage] Slot '$name'$(if ($Result.IsActive) { ' (active)' })" 'DarkYellow'

    # Surface the OAuth account email whenever we could resolve it, so the
    # verbose drill-down answers the "which account is this?" question
    # without forcing the user to cross-reference the table.
    if ($Result.PSObject.Properties['Email'] -and $Result.Email) {
        Write-Color "  Account: $($Result.Email)" 'DarkGray'
    }

    if ($Result.Status -ne 'ok') {
        Format-UsageTable -Results @($Result)
        return
    }
    if (-not $Result.Data) {
        Write-Color "  (empty response)" 'DarkGray'
        return
    }

    # Status line between Account and the bucket rows, so the first thing
    # the user reads is "can I use this slot right now?". Same label set
    # as the summary table, plus a short English rationale when the
    # label alone is not self-explanatory (near limit, limited, no plan
    # data).
    $planStatus  = Get-PlanStatus $Result.Data
    $rationale   = Get-StatusRationale $planStatus
    $statusLine  = if ($rationale) { "$planStatus - $rationale" } else { $planStatus }
    $statusColor = Get-StatusColor -Label $planStatus -IsActive ([bool]$Result.IsActive)
    Write-Color ("  Status:  $statusLine") $statusColor

    # Two-bucket render. Each Render-Bucket closure inlines the label so
    # this function does not depend on a lookup table; when buckets change
    # (scope decision to track only these two) the change is local.
    $renderOne = {
        Param ([string] $Label, $Bucket)
        $util  = $null
        $reset = $null
        if ($Bucket) {
            $util  = $Bucket.utilization
            $reset = $Bucket.resets_at
        }
        $pctCell   = Format-UtilCell $util
        $resetCell = if ($reset) { Format-ResetAbsolute $reset } else { '—' }
        # Label pad of 10 matches the bar block's 8-pad plus the
        # verbose view's natural breathing room (longest label 'Session'
        # = 7 chars, leaving 3 trailing spaces before the percent).
        Write-Host ("  {0,-10} {1}  {2}" -f $Label, $pctCell, $resetCell)
    }

    $five  = $Result.Data.five_hour
    $seven = $Result.Data.seven_day

    if (-not $five -and -not $seven) {
        Write-Color "  No plan-usage data (account may not have a subscription, or has not made a live API call yet)." 'DarkGray'
        return
    }

    & $renderOne 'Session' $five
    & $renderOne 'Week'    $seven
}

# --- usage action: data + rendering split ---------------------------------
#
# Invoke-UsageAction was originally a single function that both gathered
# per-slot usage data and wrote the output. Splitting the two makes
# `sca usage -Watch` possible: the watch loop re-gathers a fresh snapshot
# each poll, keeps the previous snapshot visible during HTTP failures,
# and calls the same frame renderer that the one-shot path uses. The
# split also keeps the test matrix clean: unit tests mock the data
# layer and assert on the rendered frame.
#
# Snapshot shape (Get-UsageSnapshot):
#   Results          : array of per-slot result rows
#                      { Name, IsActive, Status, Data, Error, Email,
#                        IsCachedFallback }
#   NoSlots          : $true when there are zero saved slots. Caller
#                      prints the "no slots" hint.
#   HasCacheFallback : $true when at least one row served from the 429
#                      cache fallback. Drives the post-table advisory.
#
# The caller (Invoke-UsageAction) runs Invoke-Reconcile before invoking
# this function, so by the time we enumerate slots, the active-slot file
# is byte-equal to .credentials.json. The synthetic <active> row that
# previous versions appended for the broken-hardlink state is no longer
# needed: the active slot file IS the active credentials.

# Gather the per-slot usage snapshot used by both the one-shot action and
# the live watch loop. Performs all network IO (Get-SlotUsage per slot).
# Never renders; callers decide between table, verbose, JSON, and
# watch-frame presentations.
function Get-UsageSnapshot {
    Param ([String] $Name)

    $slots = @(Get-Slots)

    if ($slots.Count -eq 0) {
        return [pscustomobject]@{
            Results          = @()
            NoSlots          = $true
            HasCacheFallback = $false
            HasRateLimited   = $false
        }
    }

    # -Name filter: select a single slot by name (after Get-SafeName
    # sanitization). Throws 'not found' when no match.
    $selectedSlots = $slots
    if ($Name) {
        $safeName      = Get-SafeName $Name
        $selectedSlots = @($slots | Where-Object { $_.Name -eq $safeName })
        if ($selectedSlots.Count -eq 0) {
            throw "Slot '$safeName' not found."
        }
    }

    $results = foreach ($slot in $selectedSlots) {
        $usage = Get-SlotUsage -SlotPath $slot.Path
        [pscustomobject]@{
            Name     = $slot.Name
            IsActive = $slot.IsActive
            Status   = $usage.Status
            Data     = $usage.Data
            Error    = $usage.Error
            # Email comes from the slot filename via Get-Slots (parsed by
            # Get-SlotFileInfo). No HTTP call here; the only source of
            # truth for a slot's email is its filename, which was written
            # by `sca save` from a fresh profile fetch at that moment.
            Email            = $slot.Email
            IsCachedFallback = $usage.IsCachedFallback
        }
    }

    return [pscustomobject]@{
        Results          = @($results)
        NoSlots          = $false
        HasCacheFallback = ($results | Where-Object { $_.IsCachedFallback }).Count -gt 0
        # HasRateLimited drives the "transient throttle" advisory for the
        # no-cache case, where the row has no Data to show. A row served
        # from the cache fallback is also 'rate-limited' but is covered by
        # the HasCacheFallback advisory branch (which takes precedence).
        HasRateLimited   = ($results | Where-Object { $_.Status -eq 'rate-limited' }).Count -gt 0
    }
}

# Render one usage frame (table OR verbose view, plus optional advisory
# and optional footer). Pure presentation; does not call the network.
# Used by both the one-shot action and the live watch loop; the same
# frame renders identically in either context so tests assert on the
# frame shape without running the loop.
#
# -Name           : when set, selects the single-slot verbose view. Empty
#                   -> summary table.
# -Snapshot       : output of Get-UsageSnapshot for this frame.
# -Footer         : optional string printed below the table / verbose view
#                   for the watch-mode "Last poll" line. Multi-line
#                   strings are split and each line rendered in the
#                   DarkGray information color.
# -AutoThreshold  : when set (1..100), append a right-aligned
#                   '▶ switching slot at N%' indicator to the
#                   `[Usage] Plan usage` header. Used by `sca usage
#                   -Watch -Auto` to indicate auto-rotation is engaged.
#                   Width-aware: if the terminal is too narrow to fit
#                   both the left header and the indicator with a
#                   2-space gap, the indicator is silently dropped
#                   (the footer's `[Auto]` line still
#                   carries the state, so no info is lost).
function Format-UsageFrame {
    Param (
        [String]                $Name,
        [pscustomobject]        $Snapshot,
        [AllowEmptyString()]
        [AllowNull()] [String]  $Footer,
        [int]                   $AutoThreshold = 0
    )

    if (-not $Snapshot -or $Snapshot.NoSlots) {
        Write-Color "[Usage] No slots saved yet. Use: sca save <name>" 'Yellow'
        if ($Footer) { Format-UsageFooter $Footer }
        return
    }

    $results = @($Snapshot.Results)
    if ($Name -and $results.Count -eq 1) {
        Format-UsageVerbose -Result $results[0]
    } else {
        # -IncludeAggregateBars: render the pool-wide Session/Week
        # progress bars above the column header. Format-UsageVerbose's
        # non-ok fallback also calls Format-UsageTable but does NOT pass
        # this switch; bars are a pool-level summary and would be
        # off-topic on a single-slot drill-down.
        # -AutoThreshold is threaded through unchanged; the table is
        # the layer that renders the [Usage] header where the tag goes.
        Format-UsageTable -Results @($results) -IncludeAggregateBars -AutoThreshold $AutoThreshold
    }

    # Cache-fallback / rate-limit advisory. Rendered in the footer block
    # (alongside the [Auto] / [Watch] lines), NOT directly under the table:
    # the advisory leads the footer group so the rate-limit signal sits with
    # the other per-frame status lines instead of crowding the table's last
    # row. The 429 may have come from /api/oauth/usage (existing path) OR
    # from /v1/oauth/token during a token refresh that triggered the cache
    # fallback in Get-SlotUsage's refresh-failure handler; hence the
    # endpoint-agnostic wording.
    $advisory = $null
    if ($Snapshot.HasCacheFallback) {
        $advisory = '[Usage] Rate limited; showing cached data.'
    }
    elseif ($Snapshot.HasRateLimited) {
        # No cached data to fall back on (first poll under a throttle). Make
        # it explicit that 'rate-limited' is a transient API condition, not
        # an unused/dead slot: the slot is active and its numbers return on
        # the next successful poll.
        $advisory = '[Usage] Rate limited; transient, slot active.'
    }

    if ($Footer -or $advisory) {
        Format-UsageFooter -Footer $Footer -Advisory $advisory
    } else {
        Write-Host ''
    }
}

# Render the multi-line footer block under a usage frame. Internal helper
# for Format-UsageFrame; extracted so the watch loop and any future
# footer-consumers share one wrapping policy.
#
# -Footer   : the [Watch] / [Auto] lines (DarkGray). Kept as the first
#             positional parameter so the existing positional call sites
#             (`Format-UsageFooter $Footer`) bind unchanged.
# -Advisory : optional rate-limit advisory (Yellow). Leads the footer
#             block, above the DarkGray footer lines, so the warning stays
#             visually distinct while grouping with the per-frame status.
function Format-UsageFooter {
    Param (
        [AllowEmptyString()] [AllowNull()] [String] $Footer,
        [AllowEmptyString()] [AllowNull()] [String] $Advisory
    )

    # Two blank lines between the table and the footer: the first
    # closes the table block (paired with `Format-UsageTable`'s output),
    # the second adds breathing room so the footer doesn't visually
    # touch the table's last row. This matters most under -Watch where
    # the screen never scrolls and the table-to-footer gap is the
    # user's main horizontal landmark.
    Write-Host ""
    Write-Host ""
    if ($Advisory) {
        Write-Color $Advisory 'Yellow'
    }
    if ($Footer) {
        foreach ($line in ($Footer -split "`r?`n")) {
            Write-Color $line 'DarkGray'
        }
    }
}

# Brand suffix appended to the watch-mode terminal title. Lives as a
# script-scope constant so the wording is editable in one place. The
# title's job is "make this background tab identifiable + show two
# numbers"; the leading data carries the actionable bits, this trails.
$Script:WatchTitleSuffix = 'Switch Claude Account'

# Build the OSC 0 terminal-title string for `sca usage -Watch`. The
# title carries two utilization numbers + brand suffix, optionally
# prefixed with an alarm marker when usage crosses the warn / limit
# thresholds:
#
#   34% | 42% | Switch Claude Account            # both below warn threshold
#   [~] 92% | 80% | Switch Claude Account        # any bucket >= warn, all < limit
#   [!] 100% | 80% | Switch Claude Account       # any bucket >= limit
#   — | 42% | Switch Claude Account              # source row has null five_hour
#   Switch Claude Account                         # no usable source row
#
# Two modes, gated by -Aggregate:
#
# 1. Default (active-slot mode, used by bare `sca usage -Watch`):
#    Source row priority (the snapshot may carry many rows):
#      a. -Name <slot> set    -> the row whose Name matches (explicit
#                                 user filter wins).
#      b. else                -> the row where IsActive = $true.
#      c. else / row not 'ok' -> bare suffix.
#    Alarm thresholds: $Script:UtilWarnPct (90) / $Script:UtilLimitPct
#    (100). Matches Get-PlanStatus so the title prefix and the body's
#    Status column stay in lockstep: '[!]' corresponds to 'limited *',
#    '[~]' to 'near limit'.
#
#    Active-slot-only (vs. pool-mean) is deliberate: a multi-slot pool
#    mean averages a burned slot down to noise (1 of 5 slots at 100%
#    reads as ~20% mean), defeating the alarm-glance value of the title.
#
# 2. -Aggregate (pool-mean mode, wired to -Auto by Invoke-UsageWatch):
#    In -Auto the active slot moves under the user as the script rotates
#    to fresh slots, so the active-slot title becomes a moving target
#    rather than an actionable signal. Pool-mean across all HTTP-ok
#    rows mirrors the aggregate bars rendered above the table; the title
#    number and the on-screen bar percentage are computed by the same
#    helper (Get-PoolMeanUtilization), so they cannot drift.
#    -Name is IGNORED in this mode (aggregation is pool-wide by
#    definition).
#    Alarm thresholds: $Script:AggregateRedPct (90, [!]) /
#    $Script:AggregateYellowPct (50, [~]). These are designed for
#    pool-mean semantics; the per-slot UtilLimitPct / UtilWarnPct would
#    virtually never fire on a pool mean (need nearly all slots at that
#    level), defeating the alarm signal.
#    Bare suffix when no HTTP-ok rows exist (matches Format-AggregateBars
#    skip-render).
#
# Control bytes (\x00-\x1F, \x7F) are stripped from the assembled string
# as defense-in-depth: slot names already pass Get-SafeName so user
# input cannot reach this point with control bytes, but a future caller
# (or a slot from a pre-sanitization era) cannot inject an OSC-envelope
# breakout regardless.
function Format-WatchTitle {
    Param (
        [String]         $Name,
        [pscustomobject] $Snapshot,
        # -Aggregate: switch to pool-mean mode (see docblock above).
        # Wired to -Auto by Invoke-UsageWatch's single call site so the
        # mode tracks the user's existing -Auto opt-in.
        [switch]         $Aggregate
    )

    $suffix = $Script:WatchTitleSuffix

    if (-not $Snapshot -or $Snapshot.NoSlots) { return $suffix }

    $results = @($Snapshot.Results)
    if ($results.Count -eq 0) { return $suffix }

    if ($Aggregate) {
        # Pool-mean mode. Math delegated to Get-PoolMeanUtilization so
        # the title number tracks Format-AggregateBars byte-for-byte.
        # $null return = no HTTP-ok rows in the snapshot -> bare suffix
        # (matches the aggregate bar's skip-render behavior).
        $five  = Get-PoolMeanUtilization -Results $results -BucketKey 'five_hour'
        $seven = Get-PoolMeanUtilization -Results $results -BucketKey 'seven_day'
        if ($null -eq $five -and $null -eq $seven) { return $suffix }

        $warnPct  = $Script:AggregateYellowPct
        $limitPct = $Script:AggregateRedPct
    }
    else {
        # Active-slot mode. Source row: explicit -Name wins; otherwise
        # the active slot. We do NOT fall back to "first row" or "pool
        # mean"; the active slot is the right answer for an alarm-style
        # display, and -Name is the only reason to override it. Strict
        # Name match (defense-in-depth against an upstream caller that
        # did not pre-filter the snapshot).
        $row = if ($Name) {
            $results | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        } else {
            $results | Where-Object { $_.IsActive } | Select-Object -First 1
        }
        if (-not $row -or $row.Status -ne 'ok') { return $suffix }

        $five  = if ($row.Data -and $row.Data.five_hour) { $row.Data.five_hour.utilization } else { $null }
        $seven = if ($row.Data -and $row.Data.seven_day) { $row.Data.seven_day.utilization } else { $null }

        $warnPct  = $Script:UtilWarnPct
        $limitPct = $Script:UtilLimitPct
    }

    # Render one bucket value to either 'NN%' (rounded percent) or '—'
    # for null. Local closure so the prefix branch and the format string
    # share one rendering rule.
    $renderPct = {
        Param ($v)
        if ($null -eq $v) { return '—' }
        return ('{0}%' -f [int][math]::Round([double]$v))
    }

    # Alarm prefix: tiered. '[!]' wins over '[~]' (at-limit is more
    # actionable than only-near-limit). Null buckets contribute nothing
    # to the alarm; they cannot be at or above any threshold by
    # definition. Threshold pair varies by mode (set above).
    $hasLimit = (
        ($null -ne $five  -and [double]$five  -ge $limitPct) -or
        ($null -ne $seven -and [double]$seven -ge $limitPct)
    )
    $prefix = ''
    if ($hasLimit) {
        $prefix = '[!] '
    } else {
        $hasWarn = (
            ($null -ne $five  -and [double]$five  -ge $warnPct) -or
            ($null -ne $seven -and [double]$seven -ge $warnPct)
        )
        if ($hasWarn) { $prefix = '[~] ' }
    }

    $title = '{0}{1} | {2} | {3}' -f $prefix, (& $renderPct $five), (& $renderPct $seven), $suffix

    # Strip control bytes (C0 + DEL). Defense-in-depth against an OSC
    # envelope breakout via a malformed slot name, sidecar email, or
    # future caller path. Tab/CR/LF are unusual in titles too; drop
    # them all.
    return ([regex]::Replace($title, '[\x00-\x1F\x7F]', ''))
}

function Invoke-UsageAction {
    Param (
        [string] $Name,
        [switch] $Json,
        [switch] $Watch,
        [int]    $Interval = $Script:UsageWatchMinInterval,
        # -Auto: when set with -Watch, the watch loop auto-rotates to the
        # next eligible slot when the active slot's max(five_hour,
        # seven_day) utilization reaches -Threshold. Bound to the 'Watch'
        # parameter set at the top of the script, so the binder rejects
        # -Auto without -Watch; this runtime guard catches direct callers
        # (notably the test suite) that bypass the top-level Param.
        [switch] $Auto,
        # -Threshold: percentage at or above which -Auto rotates. Default
        # 95 leaves a small safety margin because /api/oauth/usage
        # reporting lags real consumption; range enforced by
        # [ValidateRange(1,100)] on the top-level Param block.
        [int]    $Threshold = 95,
        # -Warmup: prime every saved slot via a billable /v1/messages
        # request before the first poll. Requires -Watch. Independent
        # of -Auto.
        [switch] $Warmup
    )

    # The top-level Param block enforces -Json/-Watch mutual exclusion via
    # parameter sets; this runtime guard is belt-and-suspenders for direct
    # callers (notably the test suite) that bypass Invoke-Main.
    if ($Json -and $Watch) {
        throw "-Watch and -Json cannot be combined; -Watch is interactive, -Json is for scripting."
    }

    # -Auto / -Threshold require -Watch. The top-level parameter set
    # already enforces this for CLI invocations; the runtime guard
    # catches test-suite direct calls. -Threshold defaults to 100 even
    # when -Auto is absent, so the guard fires only on -Auto.
    if ($Auto -and -not $Watch) {
        throw "-Auto requires -Watch; auto-rotation runs as part of the watch loop."
    }

    # -Warmup requires -Watch. The top-level parameter set already enforces
    # this for CLI invocations; the runtime guard catches direct callers
    # (notably the test suite) that bypass Invoke-Main.
    if ($Warmup -and -not $Watch) {
        throw "-Warmup requires -Watch; warmup runs as part of the watch loop's startup."
    }

    if ($Watch) {
        Invoke-UsageWatch -Name $Name -Interval $Interval -Auto:$Auto -Threshold $Threshold -Warmup:$Warmup
        return
    }

    # Reconcile first so the slot file matches whatever Claude Code may
    # have written into .credentials.json since the last sca call. The
    # subsequent Get-SlotUsage calls then read fresh tokens and the table
    # marker is correct without relying on a synthetic <active> row.
    # Suppress any reconcile advisory in -Json mode so the JSON output
    # stays parseable.
    if ($Json) {
        Invoke-Reconcile 6>$null | Out-Null
    } else {
        Invoke-Reconcile | Out-Null
    }

    $snapshot = Get-UsageSnapshot -Name $Name

    if ($Json) {
        # Per-slot dictionary. Each entry carries the raw response under
        # .data so scripts can pull any field Anthropic returns, including
        # buckets this script does not render in the table or verbose view.
        # The `account` block is included whenever the email was resolved;
        # currently only .email is surfaced (scope decision).
        #
        # plan_status mirrors the summary-table Status column for HTTP-ok
        # rows so scripts can branch on usability without re-deriving the
        # thresholds. Absent for HTTP-failure rows; callers already have
        # `status` (expired / unauthorized / error / no-oauth) there.
        $out = [ordered]@{}
        foreach ($r in $snapshot.Results) {
            $entry = [ordered]@{
                status    = $r.Status
                is_active = [bool]$r.IsActive
            }
            if ($r.Status -eq 'ok') {
                $entry.plan_status = Get-PlanStatus $r.Data
            }
            # is_cached_fallback: true when the row's 'ok' status was
            # served from $Script:SlotUsageCache after a 429 from either
            # the usage endpoint or the token-refresh endpoint (rather
            # than from a fresh live response). Exposed on the JSON
            # contract so scripts can detect stale data without parsing
            # the human-readable advisory text. Only emitted when true
            # to keep the output minimal; absence == fresh.
            if ($r.IsCachedFallback) { $entry.is_cached_fallback = $true }
            if ($r.Email) { $entry.account = [ordered]@{ email = $r.Email } }
            if ($r.Data)  { $entry.data    = $r.Data }
            if ($r.Error) { $entry.error   = $r.Error }
            $out[$r.Name] = $entry
        }
        $out | ConvertTo-Json -Depth 10
        return
    }

    Format-UsageFrame -Name $Name -Snapshot $snapshot
}

# Decide whether the watch loop's -Auto mode should rotate, suggest a
# cooldown, or do nothing this tick. Pure function: no IO, no rendering,
# no state mutation. Inputs are a usage snapshot (Get-UsageSnapshot
# output) and the integer threshold. The Invoke-UsageWatch loop
# interprets the returned decision: 'rotate' triggers Invoke-SlotSwap,
# 'no-eligible' renders the cooldown footer, 'noop' is the steady-state
# case. Active-slot identification reads the snapshot's IsActive flag
# (Get-Slots populates that from state.active_slot via Read-ScaState),
# so the state file does NOT need to be passed in separately.
#
# Decision shape:
#   @{
#     Action            : 'rotate' | 'no-eligible' | 'noop'
#     FromName          : <string>  # active slot name (when known); null otherwise
#     ToName            : <string>  # destination slot name (Action='rotate')
#     SuggestionName    : <string>  # slot whose bucket resets soonest (Action='no-eligible')
#     SuggestionBucket  : 'Session' | 'Week'   # which bucket (Action='no-eligible')
#     SuggestionResetsAt: <ISO-8601 string|DateTime|DateTimeOffset>  # the reset timestamp
#   }
#
# Trigger semantics:
#   * Active slot's max(five_hour.utilization, seven_day.utilization)
#     is compared to $Threshold. Null bucket counts as 0% (matches
#     Format-AggregateBars and the existing 'ok (no plan data)' tier).
#   * Below threshold       -> 'noop'.
#   * At or above threshold -> walk peer slots in alphabetical wrap
#                              order (matches Get-NextSlotName), skip
#                              any with non-ok HTTP status or whose own
#                              max(util) is also at/above threshold.
#                              First eligible candidate -> 'rotate'.
#                              No candidate -> 'no-eligible' with the
#                              soonest future reset across all slots
#                              and both buckets as the cooldown
#                              suggestion.
#
# Edge cases:
#   * Empty snapshot, NoSlots snapshot, or no active row in the snapshot
#     -> 'noop'. The watch loop's footer surfaces these out-of-band.
#   * Active row HTTP-non-ok (expired / unauthorized / error /
#     no-oauth / rate-limited): max(util) is undefined (treated as 0%),
#     so 'noop' fires. The user already sees the HTTP-failure label
#     in the table's Status column; auto-rotation does not act on
#     transport-level failures.
function Get-AutoRotationDecision {
    Param (
        [Parameter(Mandatory)] [pscustomobject] $Snapshot,
        [Parameter(Mandatory)] [int]            $Threshold
    )

    $noop = [pscustomobject]@{
        Action             = 'noop'
        FromName           = $null
        ToName             = $null
        SuggestionName     = $null
        SuggestionBucket   = $null
        SuggestionResetsAt = $null
    }

    if (-not $Snapshot -or $Snapshot.NoSlots) { return $noop }

    $results = @($Snapshot.Results)
    if ($results.Count -eq 0) { return $noop }

    # Identify the active row by the snapshot's IsActive flag. The
    # snapshot is built from Get-Slots which populates IsActive from
    # $StateFile via Read-ScaState, so this matches state.active_slot
    # without re-reading the file.
    $activeRow = $results | Where-Object { $_.IsActive } | Select-Object -First 1
    if (-not $activeRow) { return $noop }

    $activeMax = Get-RowMaxUtilization -Row $activeRow
    if ($activeMax -lt $Threshold) {
        # Steady state: active is below threshold; nothing to do.
        return [pscustomobject]@{
            Action             = 'noop'
            FromName           = $activeRow.Name
            ToName             = $null
            SuggestionName     = $null
            SuggestionBucket   = $null
            SuggestionResetsAt = $null
        }
    }

    # Active is at or above threshold. Walk peer slots in alphabetical
    # wrap order starting AFTER the active slot. This mirrors
    # Get-NextSlotName's ordering so -Auto and `sca switch` (no name)
    # rotate in the same direction.
    $sorted = @($results | Sort-Object -Property Name)
    $activeIdx = -1
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        if ($sorted[$i].Name -eq $activeRow.Name) { $activeIdx = $i; break }
    }

    # Walk N-1 peers in wrap order (skip the active slot itself).
    $eligible = $null
    for ($offset = 1; $offset -lt $sorted.Count; $offset++) {
        $candidate = $sorted[($activeIdx + $offset) % $sorted.Count]
        if ($candidate.Status -ne 'ok')         { continue }
        $candMax = Get-RowMaxUtilization -Row $candidate
        if ($candMax -ge $Threshold)            { continue }
        $eligible = $candidate
        break
    }

    if ($eligible) {
        return [pscustomobject]@{
            Action             = 'rotate'
            FromName           = $activeRow.Name
            ToName             = $eligible.Name
            SuggestionName     = $null
            SuggestionBucket   = $null
            SuggestionResetsAt = $null
        }
    }

    # No eligible peer. Find the soonest FUTURE reset across all slots
    # and both buckets; that is the moment at which auto-rotation can
    # next return something other than 'no-eligible'. Used by the
    # watch loop's "[Auto] No free slot available! Cooling down for
    # <delta>" footer line.
    $soonestSlot   = $null
    $soonestBucket = $null
    $soonestTime   = $null

    $nowUtc = [DateTimeOffset]::UtcNow
    foreach ($r in $results) {
        if (-not $r.Data) { continue }
        foreach ($pair in @(
            @{ Key = 'five_hour'; Label = 'Session' },
            @{ Key = 'seven_day'; Label = 'Week'    }
        )) {
            $bucket = $r.Data.($pair.Key)
            if (-not $bucket -or -not $bucket.resets_at) { continue }
            $t = ConvertTo-DateTimeOffsetOrNull $bucket.resets_at
            if ($null -eq $t)        { continue }
            if ($t -le $nowUtc)      { continue }
            if ($null -eq $soonestTime -or $t -lt $soonestTime) {
                $soonestTime   = $t
                $soonestSlot   = $r.Name
                $soonestBucket = $pair.Label
            }
        }
    }

    return [pscustomobject]@{
        Action             = 'no-eligible'
        FromName           = $activeRow.Name
        ToName             = $null
        SuggestionName     = $soonestSlot
        SuggestionBucket   = $soonestBucket
        SuggestionResetsAt = if ($soonestTime) { $soonestTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
    }
}

# Pull the max(five_hour, seven_day) utilization from a snapshot row.
# Null/missing buckets count as 0% (matches Format-AggregateBars and
# Get-PlanStatus's 'ok (no plan data)' tier; an account that has not
# made a live API call yet is by definition not utilized). Non-ok HTTP
# rows fall through to 0% because $Row.Data is unset in that case.
# Extracted to keep Get-AutoRotationDecision readable; Format-WatchTitle
# and Get-PlanStatus do their own bucket walking with slightly
# different semantics (Format-WatchTitle preserves nulls for display),
# so this helper is auto-rotation-specific by design.
function Get-RowMaxUtilization {
    Param ([Parameter(Mandatory)] [pscustomobject] $Row)

    if ($Row.Status -ne 'ok' -or -not $Row.Data) { return 0.0 }

    $five  = if ($Row.Data.five_hour -and $null -ne $Row.Data.five_hour.utilization) { [double]$Row.Data.five_hour.utilization } else { 0.0 }
    $seven = if ($Row.Data.seven_day -and $null -ne $Row.Data.seven_day.utilization) { [double]$Row.Data.seven_day.utilization } else { 0.0 }
    if ($five -ge $seven) { return $five }
    return $seven
}

# Render a positive future reset duration as a compact "Xh Ym" / "Xm"
# string for the [Auto] "Cooling down for <delta>" footer line. Uses
# Format-ResetDelta's shape with the surrounding parentheses stripped
# (parentheses are a table-cell convention; the footer reads as prose).
#
# Output (matches Format-ResetDelta's value semantics, minus the parens):
#   null / parse fail               -> 'unknown'  (defensive; never throws)
#   non-positive (already past)     -> 'less than a minute'
#   < 1 hour                        -> '42m'
#   >= 1 hour and < 24 hours        -> '2h 14m'
#   >= 24 hours                     -> '42h'
function Format-AutoCooldownDelta {
    Param ($ResetsAt)

    $target = ConvertTo-DateTimeOffsetOrNull $ResetsAt
    if ($null -eq $target) { return 'unknown' }

    $delta = $target - [DateTimeOffset]::UtcNow
    if ($delta.TotalSeconds -le 0) { return 'less than a minute' }

    if ($delta.TotalHours -ge 24) {
        $h = [int][math]::Floor($delta.TotalHours)
        return "${h}h"
    }

    $h = [int]$delta.Hours
    $m = [int]$delta.Minutes
    if ($h -gt 0) { return "${h}h ${m}m" }
    return "${m}m"
}

# Per-poll auto-rotation step for the watch loop's -Auto mode. Wraps:
#
#   1. Get-AutoRotationDecision (pure) to classify the active slot's
#      state against -Threshold.
#   2. Re-check Test-ClaudeRunning before any rotation (covers the
#      "Claude Code launched after -Auto started" race; the pre-loop
#      guard in Invoke-UsageWatch only fires once at startup).
#   3. Find-SlotByName + Invoke-SlotSwap when a peer is eligible.
#   4. Map the outcome to a single-line latched footer string that
#      Invoke-UsageWatch appends to every subsequent frame until the
#      next state change.
#
# Returns the new footer-latch string. Never throws: any exception from
# the swap path is caught and rendered as '[Auto] Rotation failed! …'
# so the watch loop never aborts because of an auto-rotation issue.
#
# -CurrentLatch carries the previous frame's latched string. Used for
# two distinct cases:
#   * Decision 'noop' AND no prior rotation event: preserves the
#     initial '[Auto] Automatic slot switching is enabled.' line (or
#     whatever steady-state caller supplied).
#   * Decision 'noop' AFTER a prior rotation: the 'Rotated …' line
#     stays latched. The user choice (this conversation) was that
#     transition lines stay visible until the next state change, not
#     revert to the steady-state line on every tick.
#
# All [Auto] lines start with a capital letter per the user's locked
# convention.
function Invoke-AutoRotationStep {
    Param (
        [Parameter(Mandatory)] [pscustomobject] $Snapshot,
        [Parameter(Mandatory)] [int]            $Threshold,
        [AllowNull()] [AllowEmptyString()] [string] $CurrentLatch
    )

    $decision = Get-AutoRotationDecision -Snapshot $Snapshot -Threshold $Threshold

    switch ($decision.Action) {
        'noop' {
            # No state change. Preserve whatever latch the caller had.
            # On the very first tick that hits 'noop' the caller's
            # initialiser ('[Auto] Enabled') is preserved; after a
            # prior 'rotate' the 'Rotated A -> B at HH:mm:ss' string
            # stays latched until the next state change.
            return $CurrentLatch
        }

        'rotate' {
            # Per-rotation Test-ClaudeRunning re-check. The pre-loop
            # guard caught the startup case; this catches the "Claude
            # Code launched mid-watch" race. Surface the refusal as
            # a [Auto] line; the credentials swap does NOT happen.
            if (Test-ClaudeRunning) {
                return '[Auto] Rotation refused! Claude Code is running.'
            }

            try {
                $slot = Find-SlotByName -Name $decision.ToName
                if (-not $slot) {
                    # Sidecar disappeared between snapshot and lookup.
                    # Rare; surfaces as a 'Rotation failed' line.
                    return "[Auto] Rotation failed! Slot '$($decision.ToName)' not found (or missing its identity sidecar)."
                }
                Invoke-SlotSwap -Slot $slot 6>$null
                $ts = [DateTime]::Now.ToString('HH:mm:ss')
                return ('[Auto] Rotated from "{0}" to "{1}" at {2}' -f $decision.FromName, $decision.ToName, $ts)
            }
            catch {
                return "[Auto] Rotation failed! $($_.Exception.Message)"
            }
        }

        'no-eligible' {
            # All peers also at or above threshold. Suggest the soonest
            # reset across all slots and buckets so the user has a
            # concrete cooldown ETA.
            if ($decision.SuggestionResetsAt) {
                $delta = Format-AutoCooldownDelta $decision.SuggestionResetsAt
                return ('[Auto] No free slot available! Cooling down for {0}.' -f $delta)
            }
            # No future reset across any slot is rare (would mean every
            # bucket has resets_at=null, i.e. no slot has made a live
            # API call yet). Give the user a short message rather than
            # interpolating a useless 'unknown'.
            return '[Auto] No free slot available! Waiting for the next poll.'
        }

        default {
            # Unknown action label. Defensive; surface as a no-op so
            # the loop keeps running.
            return $CurrentLatch
        }
    }
}

# Minimum poll interval for -Watch. Matches the default so users can only
# adjust the interval upward; the floor is the "polite" setting for the
# unofficial endpoint and we refuse to go faster. Clamping up (rather
# than throwing) keeps the call ergonomic for users who just typed a
# round number.
$Script:UsageWatchMinInterval = 60

# Inter-slot spacing during the warmup loop. After each slot is
# primed, sleep this many milliseconds before moving to the next.
# Cheap insurance against per-IP burst rate-limits on /v1/messages:
# 300 ms between calls keeps two-slot pools well under typical burst
# thresholds while adding only ~300 ms * (N-1) of startup latency.
# Tunable for tests (Pester overrides to zero).
#
# Minimum on-screen visibility for the per-slot transient 'priming'
# row state during warmup. The 'priming' label is painted into the
# frame, then Invoke-SlotPrime runs (HTTP POST to /v1/messages), then
# the terminal-status label replaces it. Without this floor, a fast-
# LAN prime can return in <100 ms, flashing the 'priming' cell
# unreadably. 150 ms is the perceptual lower bound for a label the
# user is meant to read; below that the eye sees a flicker rather
# than a state. Sleep is placed BEFORE Invoke-SlotPrime (not after)
# so the floor adds at most one 150 ms * N latency penalty regardless
# of HTTP timing, and stacks linearly with $WarmupSpacingMs rather
# than racing it. Tunable for tests (Pester overrides to zero).
$Script:WarmupSpacingMs    = 300
$Script:WarmupPrimingMinMs = 150

# Warmup-as-swap-then-prime orchestrator for `sca usage -Watch -Warmup`.
# Round-robins through every saved slot in alphabetical order: per slot,
# Invoke-SlotSwap makes it active (writes .credentials.json AND
# ~/.claude.json's oauthAccount AND state.active_slot) and Invoke-SlotPrime
# sends a minimal billable /v1/messages request so Anthropic opens a
# server-side 5h session window for the slot. Either throwing collapses
# into Status='error' on the row; the loop continues with remaining slots.
#
# Why billable priming instead of an /api/oauth/usage probe: a non-active
# slot's /api/oauth/usage returns empty bucket data (or 429) until a
# server-side 5h session window has been opened, which only a billable
# request can do. v2.5.0's swap-then-probe rationale was wrong; this
# entry retracts that claim. Cost: ~2 tokens per slot per warmup on the
# pinned Haiku model (fractions of a cent).
#
# Verify-after-prime: a successful prime opens the session but returns no
# bucket data, so the row would otherwise read 'ok (no plan data)' (empty
# em-dash cells) until the first poll ~60 s later. After an ok prime we
# immediately call Get-SlotUsage for the slot so the warmup frame shows
# live percentages right away, matching what plain `sca usage` displays.
# A failed prime (rate-limited / unauthorized / expired / no-oauth /
# error) skips the usage read and surfaces the prime's own outcome. Cost:
# one extra /api/oauth/usage GET per successfully primed slot.
#
# Builds the rendered snapshot in place: one row per slot (filtered by
# -Name when set), each starting at Status='warming-up' with Data=$null,
# transitioning through 'priming' to its real outcome (the prime's usage
# read, or the prime's failure status). The end state is the first frame
# of the polling loop; the caller wires it to $snapshot and sets
# $lastPoll = now. Returns $null when no slots match.
#
# The original active slot is captured before the loop via Read-ScaState
# + Find-SlotByName. A finally block restores it via one more Invoke-Slot-
# Swap so a clean exit (or Ctrl-C, which still runs finally) returns the
# user where they started. Restore failure logs a yellow advisory naming
# the slot the user is now active on. No active slot captured (fresh
# install, sidecar-hidden active) is fine: the finally guard skips the
# restore and the user ends on the last primed slot.
#
# $Repaint is invoked as: & $Repaint $snapshot.
# Per-slot latency is bounded at $WarmupPrimingMinMs (floors the
# 'priming' label's on-screen visibility against fast-LAN returns)
# + swap + HTTP + $WarmupSpacingMs (per-IP burst guard between slots).
function Invoke-WarmAllSlots {
    Param (
        [string]                             $Name,
        [Parameter(Mandatory)] [scriptblock] $Repaint
    )

    $slots = @(Get-Slots)
    if ($Name) {
        $safe  = Get-SafeName $Name
        $slots = @($slots | Where-Object { $_.Name -eq $safe })
    }
    if ($slots.Count -lt 1) { return $null }

    # Each row carries IsCachedFallback so the verify-after-prime usage
    # read (below) can propagate a 429 cache fallback into the snapshot-
    # level HasCacheFallback flag, keeping the warmup frame's advisory in
    # lockstep with the polling loop's frames.
    $rows = @($slots | ForEach-Object {
        [pscustomobject]@{
            Name             = $_.Name
            Email            = $_.Email
            Path             = $_.Path
            IsActive         = $_.IsActive
            Sidecar          = $_.Sidecar
            Status           = 'warming-up'
            Data             = $null
            Error            = $null
            IsCachedFallback = $false
        }
    })
    $snapshot = [pscustomobject]@{ Results = $rows; NoSlots = $false; HasCacheFallback = $false; HasRateLimited = $false }
    & $Repaint $snapshot

    $origActive = $null
    $state = Read-ScaState
    if ($state -and $state.active_slot) {
        $origActive = Find-SlotByName -Name $state.active_slot
    }

    # Track the slot the process is actually active on. Seeded to
    # $origActive (the active slot before any swap) and advanced only
    # after a successful Invoke-SlotSwap below, so it always names the
    # live active slot even when a mid-loop swap throws (the throw skips
    # the advance and routes to the catch). The restore-failure advisory
    # in the finally reads it, so a double swap failure names the slot
    # the user is genuinely left on rather than blindly assuming rows[-1].
    $lastSwapped = $origActive

    $last = $rows.Count - 1
    try {
        for ($i = 0; $i -le $last; $i++) {
            $row = $rows[$i]
            $row.Status = 'priming'
            & $Repaint $snapshot

            # Conditional sleep so a test-side zero override is a no-op
            # rather than a degenerate Start-Sleep 0.
            if ($Script:WarmupPrimingMinMs -gt 0) {
                Start-Sleep -Milliseconds $Script:WarmupPrimingMinMs
            }

            # 6>$null suppresses [Switch] / [Sync] advisories so they
            # don't paint outside the DEC 2026 sync envelope. The try/
            # catch catches Invoke-SlotSwap throws AND defends against
            # any Invoke-SlotPrime contract violation (the prime's
            # documented surface is non-throwing, but defense-in-depth
            # against unexpected exceptions keeps the loop alive for
            # the remaining slots). Normal prime failure modes route
            # through $r.Status (rate-limited / expired / unauthorized
            # / error) without throwing; this catch only fires on
            # actual exceptions.
            try {
                Invoke-SlotSwap -Slot $row 6>$null
                # Swap succeeded (it throws on failure): this slot is now
                # the live active slot. Record it for the restore advisory.
                $lastSwapped = $row
                $r = Invoke-SlotPrime -SlotPath $row.Path 6>$null
                if ($r.Status -eq 'ok') {
                    # Prime opened the session but returns no bucket data.
                    # Read /api/oauth/usage now (verify-after-prime) so the
                    # warmup frame shows live percentages immediately,
                    # instead of 'ok (no plan data)' until the first poll
                    # ~60 s later. Get-SlotUsage never throws; it returns
                    # the real outcome (ok / rate-limited / cached / etc.).
                    $u = Get-SlotUsage -SlotPath $row.Path 6>$null
                    $row.Status           = $u.Status
                    $row.Data             = $u.Data
                    $row.Error            = $u.Error
                    $row.IsCachedFallback = [bool]$u.IsCachedFallback
                }
                else {
                    # Prime failed (rate-limited / unauthorized / expired /
                    # no-oauth / error): surface its real outcome; a usage
                    # read would not add signal here.
                    $row.Status = $r.Status
                    $row.Error  = $r.Error
                }
            }
            catch {
                $row.Status = 'error'
                $row.Error  = $_.Exception.Message
            }

            # Keep the snapshot-level advisory flags in lockstep with the
            # rows mutated so far, so the warmup frame's cache-fallback /
            # transient-throttle note matches what the polling loop renders.
            $snapshot.HasCacheFallback = (@($rows | Where-Object { $_.IsCachedFallback }).Count -gt 0)
            $snapshot.HasRateLimited   = (@($rows | Where-Object { $_.Status -eq 'rate-limited' }).Count -gt 0)
            & $Repaint $snapshot

            if ($i -lt $last -and $Script:WarmupSpacingMs -gt 0) {
                Start-Sleep -Milliseconds $Script:WarmupSpacingMs
            }
        }
    }
    finally {
        if ($origActive) {
            try { Invoke-SlotSwap -Slot $origActive 6>$null }
            catch { Write-Color "[Warmup] Restore of original active slot '$($origActive.Name)' failed: $($_.Exception.Message). You are now active on '$($lastSwapped.Name)'." 'Yellow' 6>$null }
        }
    }
    return $snapshot
}

# Live `sca usage -Watch` loop: redraws once per second and re-polls the
# endpoint every -Interval seconds. The redraw cadence is decoupled from
# the poll cadence so the frame self-heals on terminal resize within
# ~1 s instead of waiting up to -Interval seconds for the next poll.
# Interactive only; throws when output is redirected because the
# alt-screen + cursor-control sequences would poison a captured log.
# Exits on Ctrl-C via the runtime's default handler; the `finally`
# block leaves the alternate screen buffer and restores cursor
# visibility. On HTTP failure the previous snapshot stays visible and
# an advisory is appended to the footer so the display never blanks.
#
# Flicker-free rendering. Each frame is wrapped in DEC mode 2026
# (synchronized output: ESC[?2026h … ESC[?2026l) with ESC[2J + cursor-
# home (ESC[H) at the start. Inside the sync envelope the terminal
# buffers the clear-and-redraw and presents one atomic frame, so the
# user never sees the intermediate "blank screen" frame that Clear-Host
# produced. The watch also enters the alternate screen buffer
# (ESC[?1049h) so the pre-watch terminal scrollback is restored on
# exit, mirroring how top / htop / vim behave. Terminals without DEC
# 2026 support (e.g. legacy ConHost) silently ignore the unknown DEC
# private mode and fall back to the previous Clear-Host-style flicker.
# No regression. Renderer functions are reused unchanged; only this
# loop emits the wrapper sequences.
#
# VT control sequences (alt buffer, sync mode, cursor hide/show, clear,
# home) are emitted via `Write-VTSequence` so they bypass the
# `Write-Host` -> `StringDecorated.AnsiRegex` filter that
# `OutputRendering = 'PlainText'` (set by `-NoColor` / `NO_COLOR`)
# applies. The filter strips DEC private modes (`ESC[?...h/l`) including
# the DEC 2026 envelope and the `ESC[?1049h` alt-buffer toggle, which
# would re-introduce the pre-36e5e27 flicker. Body color SGR keeps
# flowing through `Write-Color` -> `Write-Host` so `PlainText` correctly
# strips body color in `-NoColor` mode. See `Write-VTSequence` docblock
# for the verified mechanism.
#
# The loop is deliberately simple: blocking Invoke-RestMethod (via
# Get-UsageSnapshot) inside the poll step, then a plain 1 s sleep
# between frames. A runspace-based async poll would feel snappier
# during the HTTP call but adds substantial complexity that is not
# worth v1's budget.
function Invoke-UsageWatch {
    Param (
        [String] $Name,
        [int]    $Interval = $Script:UsageWatchMinInterval,
        # -Auto: auto-rotate to the next eligible slot when the active
        # slot's max(five_hour, seven_day) utilization reaches -Threshold.
        # See Get-AutoRotationDecision for the rotation logic and the
        # comments inside the watch loop for the per-tick mechanics.
        [switch] $Auto,
        # -Threshold: utilization percentage (1..100) at or above which
        # -Auto fires a rotation. Ignored when -Auto is absent.
        [int]    $Threshold = 95,
        # -Warmup: prime every saved slot via a billable /v1/messages
        # request through Invoke-WarmAllSlots before the first poll.
        # Independent of -Auto: works with bare -Watch and with -Watch
        # -Auto. See the warmup block below the alt-screen entry for
        # the synthetic snapshot + Status-column mechanics.
        [switch] $Warmup
    )

    # Pre-loop Claude Code guard for -Auto and -Warmup. Both write
    # ~/.claude.json's oauthAccount block via Invoke-SlotSwap (-Auto
    # during the in-loop rotation step; -Warmup during the per-slot
    # swap-then-prime round-robin). Claude Code keeps that block in an
    # in-memory cache; racing its flush would clobber our update.
    # Same guard / wording as Invoke-SwitchAction so the user sees a
    # consistent message regardless of entry point. -Auto additionally
    # re-checks Test-ClaudeRunning before every rotation attempt to
    # cover the "Claude Code launched mid-watch" race; -Warmup's window
    # is short enough (one round-robin pass) that the pre-loop check
    # is the only one needed.
    # Checked BEFORE the IsOutputRedirected guard so the user sees the
    # more actionable "close Claude Code" message rather than the
    # interactive-terminal one (which the test harness always hits).
    if (($Auto -or $Warmup) -and (Test-ClaudeRunning)) {
        $flag = if ($Auto) { '-Auto' } else { '-Warmup' }
        throw "Claude Code is running. Close it before 'sca usage $flag' so the credentials swap applies cleanly without racing Claude Code's in-memory ~/.claude.json cache."
    }

    if ([Console]::IsOutputRedirected) {
        throw "-Watch requires an interactive terminal; for scripted output use 'sca usage -Json'."
    }

    if ($Interval -lt $Script:UsageWatchMinInterval) {
        Write-Color "[Usage] -Interval below minimum; clamping to $($Script:UsageWatchMinInterval)s (polite to the unofficial endpoint)." 'Yellow'
        $Interval = $Script:UsageWatchMinInterval
    }

    $origCursor = [Console]::CursorVisible
    # Capture the pre-watch terminal title so the `finally` block can
    # restore it on Ctrl-C. $Host.UI.RawUI.WindowTitle is the only
    # portable read path (no terminal protocol reliably reports the
    # current OSC 0 title back). Some hosts throw when RawUI is not
    # available (test runners, ssh-without-tty); $null then signals
    # "no restore" to the finally block.
    $origTitle  = try { $Host.UI.RawUI.WindowTitle } catch { $null }
    $enteredAlt = $false
    try {
        # Enter alt screen buffer + hide cursor in one write. The alt
        # buffer gives a clean canvas and ensures the user's pre-watch
        # scrollback is restored on exit. Cursor-hide stops the caret
        # from blinking inside the table during the (atomic) repaint.
        Write-VTSequence "`e[?1049h`e[?25l"
        $enteredAlt = $true
        [Console]::CursorVisible = $false

        $snapshot      = $null
        $lastPoll      = [DateTime]::MinValue
        $lastPollError = $null

        # -Auto footer-line latch. Updated at each poll boundary based on
        # Get-AutoRotationDecision's verdict; the latched string is
        # appended (in DarkGray, like the [Watch] lines) to every frame
        # until the next state change. Initial value 'Enabled' shows the
        # mode is engaged before the first rotation event.
        $lastAutoFooter = if ($Auto) { '[Auto] Automatic slot switching is enabled.' } else { $null }

        # -Warmup startup pass. Invoke-WarmAllSlots does the per-slot
        # swap-then-probe round-robin and returns a populated snapshot
        # we hand off to the polling loop as its first frame ($lastPoll
        # = now so the loop's first iteration falls into the redraw
        # branch, not the poll branch). Reconcile first so a cross-
        # account swap landed since the last sca call is captured before
        # any slot bytes are read; matches the polling loop's per-poll
        # contract below.
        if ($Warmup) {
            Invoke-Reconcile 6>$null | Out-Null

            # -Auto's right-aligned "▶ switching slot at N%" header
            # indicator stays off when -Auto is absent.
            $autoHeader = if ($Auto) { $Threshold } else { 0 }
            $snapshot = Invoke-WarmAllSlots -Name $Name -Repaint {
                Param ($snap)
                Write-VTSequence "`e[?2026h`e[2J`e[H"
                Format-UsageFrame -Name $Name -Snapshot $snap -Footer $lastAutoFooter -AutoThreshold $autoHeader
                Write-VTSequence "`e[?2026l"
            }
            if ($null -ne $snapshot) {
                $lastPoll = [DateTime]::Now
                try {
                    Write-VTSequence ("`e]0;{0}`a" -f (Format-WatchTitle -Name $Name -Snapshot $snapshot -Aggregate:$Auto))
                } catch { Write-Verbose "Warmup title set deferred: $_" }
            }
        }

        while ($true) {
            $now = [DateTime]::Now
            $dueForPoll = ($null -eq $snapshot) -or (($now - $lastPoll).TotalSeconds -ge $Interval)

            if ($dueForPoll) {
                try {
                    # Reconcile at every poll boundary so a refresh that
                    # happened since the last poll is captured into the
                    # tracked slot before we read its bytes for the
                    # /api/oauth/usage call. Suppressed stdout; any
                    # advisory the reconcile emits would flash on every
                    # poll and the per-frame ESC[2J would shred it anyway.
                    Invoke-Reconcile 6>$null | Out-Null
                    # 6>$null on Get-UsageSnapshot: Update-SlotTokens
                    # (called via Get-SlotUsage when a token is within 60s
                    # of expiry) emits yellow [Sync] advisories on its two
                    # unhappy paths (propagation-to-.credentials.json
                    # failure, or active slot sidecar-orphaned). Those
                    # Write-Host calls would land in the alt buffer
                    # BEFORE the next frame's ESC[2J wipes it, producing
                    # a sub-frame flash the user cannot read. Suppress
                    # them here; the user still sees the same condition
                    # in non-watch contexts (`sca usage`, `sca list`).
                    # Matches the Invoke-Reconcile 6>$null above and the
                    # Invoke-SlotSwap 6>$null inside Invoke-AutoRotationStep.
                    $snapshot      = Get-UsageSnapshot -Name $Name 6>$null
                    $lastPollError = $null

                    # Update the terminal title only on a successful poll;
                    # on a failed poll the previous title (and body) persist
                    # together until the next tick. OSC 0 ('ESC ] 0 ; <title>
                    # BEL') sets both window and icon title; supported by
                    # Windows Terminal, modern ConHost, VS Code, iTerm2,
                    # kitty, alacritty, WezTerm, foot, gnome-terminal,
                    # mintty. Routed through Write-VTSequence for parity
                    # with DEC sequences (bypasses the
                    # OutputRendering=PlainText filter; see Write-VTSequence
                    # docblock).
                    # -Aggregate is tied to -Auto: in -Auto mode the
                    # active slot moves under the user as the script
                    # rotates, so the active-slot title loses signal;
                    # pool-mean matches the aggregate bars rendered
                    # above the table. Bare -Watch keeps the per-slot
                    # alarm-glance title. See Format-WatchTitle docblock.
                    Write-VTSequence ("`e]0;{0}`a" -f (Format-WatchTitle -Name $Name -Snapshot $snapshot -Aggregate:$Auto))

                    # Auto-rotation decision happens after each successful
                    # poll. The latched footer string is updated based on
                    # the decision so it stays visible until the next
                    # state change (the next 'rotate' / 'no-eligible'
                    # outcome). Failures inside the swap are caught and
                    # surfaced as 'Rotation failed!' / 'Rotation refused!'
                    # lines; the loop never aborts because of an auto-
                    # rotation issue (user can still quit with Ctrl-C
                    # and inspect the table).
                    if ($Auto) {
                        $lastAutoFooter = Invoke-AutoRotationStep -Snapshot $snapshot -Threshold $Threshold -CurrentLatch $lastAutoFooter
                    }
                }
                catch {
                    # Keep the previous snapshot visible. If the very first
                    # poll failed we still need to show SOMETHING below the
                    # header, so render an empty frame and surface the
                    # error in the footer; the user can still quit cleanly.
                    $lastPollError = $_.Exception.Message
                }
                $lastPoll = $now
            }

            # Footer rebuilt every tick. The string is constant between
            # poll boundaries (timestamp updates only on poll), but the
            # rebuild is a cheap concat and keeps the redraw path single-
            # branch. Multi-line only when the previous poll failed.
            # Order: [Auto] state (if -Auto) -> [Watch] Last poll ->
            # [Watch] Last poll failed (if any). The [Auto] line leads
            # the block so the user's eye finds the auto-mode state
            # signal first; transport-level details (poll timestamp,
            # failure tail) follow underneath.
            $footer = ''
            if ($lastAutoFooter) {
                $footer = $lastAutoFooter + "`n"
            }
            $footer += "[Watch] Last poll at $($lastPoll.ToString('HH:mm:ss'))"
            if ($lastPollError) {
                $footer += "`n[Watch] Last poll failed: $lastPollError (keeping previous data; will retry on next tick)"
            }

            # Auto-mode threshold for the header tag. Passed only when
            # -Auto is set; otherwise 0 (Format-UsageTable interprets
            # 0 as "no tag").
            $autoHeaderThreshold = if ($Auto) { $Threshold } else { 0 }

            # Atomic frame: begin sync update, clear screen, cursor home,
            # draw via the existing renderer, end sync update. All output
            # between ESC[?2026h and ESC[?2026l is buffered by the
            # terminal and presented in one swap; no flicker on
            # terminals that support the mode (Win Terminal, VS Code,
            # iTerm2, kitty, alacritty, WezTerm, foot, gnome-terminal,
            # mintty, modern ConHost). Older terminals ignore the
            # unknown DEC mode markers and exhibit the prior
            # Clear-Host-style flicker; no regression.
            Write-VTSequence "`e[?2026h`e[2J`e[H"
            if ($null -ne $snapshot) {
                Format-UsageFrame -Name $Name -Snapshot $snapshot -Footer $footer -AutoThreshold $autoHeaderThreshold
            } else {
                # First poll failed and we have nothing to render yet.
                # $footer already leads with the [Auto] line (when -Auto
                # is set) via the composition above, so a single
                # Format-UsageFooter call places auto-mode state above
                # the 'Waiting...' advisory; no separate standalone
                # print needed.
                Write-Color "[Watch] Waiting for first successful /api/oauth/usage response..." 'Yellow'
                Format-UsageFooter $footer
            }
            Write-VTSequence "`e[?2026l"

            # 1-second inter-frame wait. Decoupling redraw cadence from
            # poll cadence lets the screen self-heal on terminal resize
            # within ~1 s instead of waiting up to -Interval seconds.
            # Ctrl-C terminates the loop via the runtime's default
            # handler; the surrounding `finally` block leaves the alt
            # buffer and restores cursor visibility on exit.
            Start-Sleep -Seconds 1
        }
    }
    finally {
        # Order matters: show cursor + leave alt buffer in one write so
        # the user's pre-watch terminal state is restored atomically.
        # The CursorVisible API restore is belt-and-suspenders for the
        # .NET-side state.
        if ($enteredAlt) {
            # Restore the pre-watch terminal title via OSC 0. Empty
            # payload when capture failed (RawUI unavailable); most
            # terminals reset the tab label to their profile default
            # (Windows Terminal: profile name; VS Code: shell name).
            # Emitted before the alt-buffer leave so the title swap and
            # screen restore land in the same frame.
            $restoreTitle = if ($null -ne $origTitle) { [string]$origTitle } else { '' }
            $restoreTitle = [regex]::Replace($restoreTitle, '[\x00-\x1F\x7F]', '')
            Write-VTSequence ("`e]0;{0}`a" -f $restoreTitle)
            Write-VTSequence "`e[?25h`e[?1049l"
        }
        [Console]::CursorVisible = $origCursor
    }
}

# We are wrapping the top-level dispatcher in Invoke-Main so the script
# file is safe to dot-source from tests. Help uses `return` instead of
# `exit` to avoid killing a host that dot-sourced us; the redundant
# `exit` calls from install/uninstall branches are dropped because the
# script naturally exits at the end of Invoke-Main with status 0.
#
# No-color mode lives entirely in this function via a single
# $PSStyle.OutputRendering = 'PlainText' toggle. PS 7.2+ honors this at
# the chokepoint of every Write-Host -ForegroundColor call (and every
# other ANSI-emitting cmdlet), so no per-call-site refactor is needed.
# Precedence (most -> least specific):
#   1. -NoColor switch (CLI flag)
#   2. $env:NO_COLOR non-empty (https://no-color.org de facto standard)
#   3. default colored
# The previous $PSStyle.OutputRendering value is captured up-front and
# restored in the `finally` block so the toggle is scoped to this
# invocation -- callers that dot-source this script (notably the test
# suite, which calls Invoke-*Action directly and bypasses Invoke-Main)
# are unaffected.
function Invoke-Main {
    # -Version short-circuit. Runs before the help / action dispatch so
    # `sca -Version usage` (or any positional Action) prints the version
    # without touching the network, the credentials directory, or any
    # Invoke-*Action body. Plain Write-Host (information stream 6) matches
    # the rest of the script's output convention so `6>&1 | Out-String`
    # tests capture it the same way as Show-Help.
    if ($Version) {
        Write-Host $Script:ScriptVersion
        return
    }

    if ($Help -or $Action -eq "help" -or $Action -eq "") {
        Show-Help
        return
    }

    # We are ensuring the credentials directory exists before
    # attempting any file operations within it.
    if (-not (Test-Path -LiteralPath $CredDir)) {
        New-Item -ItemType Directory -Path $CredDir -Force | Out-Null
    }

    $previousRendering = $PSStyle.OutputRendering
    try {
        if ($NoColor -or -not [string]::IsNullOrEmpty($env:NO_COLOR)) {
            $PSStyle.OutputRendering = 'PlainText'
        }

        switch ($Action) {
            "install"   { Add-To-Profile }
            "uninstall" { Remove-From-Profile }
            "save"      { Invoke-SaveAction   -Name $Name }
            "switch"    { Invoke-SwitchAction -Name $Name }
            "list"      { Invoke-ListAction }
            "remove"    { Invoke-RemoveAction -Name $Name }
            "usage"     { Invoke-UsageAction  -Name $Name -Json:$Json -Watch:$Watch -Interval $Interval -Auto:$Auto -Threshold $Threshold -Warmup:$Warmup }
        }
    }
    finally {
        $PSStyle.OutputRendering = $previousRendering
    }
}

# We are detecting dot-sourcing by checking the invocation name; the
# dispatcher only runs when the script is invoked normally, not when
# tests dot-source the file to exercise individual functions in
# isolation.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}