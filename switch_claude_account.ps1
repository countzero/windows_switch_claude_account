#Requires -Version 7.0

<#
.SYNOPSIS
Switch between multiple Claude Code accounts on Windows.

.DESCRIPTION
This script manages named credential slots for Claude Code. It saves, switches,
lists, and removes account slots by copying credentials files within the .claude
directory. Each slot is stored as a separate .credentials.<name>.json file.

.PARAMETER Action
Specifies the action to perform. Supported values are: save, switch, list, remove,
install, uninstall, help.

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

Param (
    [Parameter(Mandatory = $false)]
    [ValidateSet("save", "switch", "list", "remove", "usage", "install", "uninstall", "help")]
    [String]
    $Action,

    [Parameter(Mandatory = $false)]
    [String]
    $Name = "",

    [switch]
    $help,

    # -json: emit the `usage` action's output as a machine-parseable JSON
    # object keyed by slot name. Ignored by other actions.
    [switch]
    $json,

    # -watch: render a live, self-refreshing `usage` view that polls
    # /api/oauth/usage every -interval seconds and redraws every second
    # (so reset deltas and the countdown footer tick visibly). Interactive
    # only — exits on Ctrl-C (runtime default). Mutually exclusive with
    # -json. Ignored by other actions.
    [switch]
    $watch,

    # -interval: seconds between HTTP polls when -watch is set. Floor is
    # 60 to keep the unofficial endpoint politely polled; values below 60
    # get clamped up with a one-line notice. Defaults to 60.
    [int]
    $interval = 60
)

# We are resolving the script path to reference this file when
# installing the alias into the user's PowerShell profile.
$ScriptPath  = (Resolve-Path $PSCommandPath).Path
$CredDir     = Join-Path $env:USERPROFILE ".claude"
$CredFile    = Join-Path $CredDir ".credentials.json"
$ProfilePath = $PROFILE.CurrentUserAllHosts

# Marker constants delimiting the block we manage in the user's profile.
# Kept at script scope so both Add-To-Profile and Remove-From-Profile share
# a single source of truth.
$MarkerStart = "# === Claude Account Switcher ==="
$MarkerEnd   = "# === End Claude Account Switcher ==="

# --- Unofficial /api/oauth/usage constants ---
#
# These values power the `usage` action, which replicates the live 5-hour
# and 7-day rate-limit read that Claude Code's own `/usage` slash command
# performs. They were extracted from claude.exe 2.1.119 (a Bun-compiled
# binary that embeds the JS source) by string-scanning the file.
#
# This endpoint is UNDOCUMENTED and unsupported by Anthropic. Expect it
# to break when Anthropic bumps the beta flag, rotates the OAuth client
# id, or reshapes the response body. To re-extract after an upstream
# change, from a PowerShell 7 prompt:
#
#   $bin   = (Get-Command claude -ErrorAction Stop).Source
#   $bytes = [IO.File]::ReadAllBytes($bin)
#   $text  = [Text.Encoding]::ASCII.GetString($bytes)
#   # Usage endpoint path:    $text | Select-String '/api/oauth/usage'
#   # Profile endpoint path:  $text | Select-String '/api/oauth/profile' (function Ql)
#   # Base API URL + TOKEN_URL + CLIENT_ID: Select-String 'TOKEN_URL:"'
#   # Beta header value:      Select-String 'lj="oauth-'
#   # UA version convention:  Select-String 'claude-code/\$\{'
#
# The client id below is the Claude.ai subscription flow's client id
# (matches the `user:sessions:claude_code` scope slot files carry); the
# other client id in the binary (22422756-...) is for the Console API-key
# flow and does not accept our refresh tokens.
$Script:UsageEndpoint     = "https://api.anthropic.com/api/oauth/usage"
$Script:ProfileEndpoint   = "https://api.anthropic.com/api/oauth/profile"
$Script:TokenEndpoint     = "https://platform.claude.com/v1/oauth/token"
$Script:OAuthClientId     = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
$Script:AnthropicBeta     = "oauth-2025-04-20"
$Script:UsageUserAgent    = "claude-code/2.1.119"
$Script:UsageTimeoutSec   = 5
$Script:ProfileTimeoutSec = 10

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
# `-json` output always carry the full email.
$Script:AccountColumnMaxWidth  = 32

# Synthetic slot names used when .credentials.json content matches none
# of the saved slot files. These are user-visible; the verbose drill-down
# (`sca usage <name>`) accepts them as-is. Kept as script-scope constants
# so both Invoke-UsageAction (producer) and the dispatcher (consumer,
# when matching -Name) share a single source of truth.
$Script:ActiveSlotNameUnsaved = '<active> (unsaved)'
$Script:ActiveSlotNameMatched = '<active>'

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
        "Claude Account Switcher - manage multiple Claude Code logins on Windows.",
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
        "EXAMPLES",
        "  $cmd save slot-1                 # save current login as 'slot-1'",
        "  $cmd switch slot-2               # activate the 'slot-2' slot",
        "  $cmd switch                      # rotate to the next saved slot",
        "  $cmd list                        # show all slots",
        "  $cmd remove slot-1               # delete a slot",
        "  $cmd usage                       # show Session + Week usage for every slot",
        "  $cmd usage -watch                # live refresh; 60s polls; Ctrl-C to quit",
        "  $cmd usage -watch -interval 300  # slower refresh (floor is 60s)",
        "  $cmd usage -json                 # emit usage as JSON for scripting",
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
        ""
    )

    $lines | ForEach-Object { Write-Host $_ }
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
    # email as `.credentials.<slot>(<email>).json` — parens in the slot
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
        Write-Host "Sanitized to: '$clean'" -ForegroundColor "Yellow"
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
# unlabeled form is returned — the slot name already conveys the account
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
# As a side effect, this function performs a one-time sweep to delete any
# leftover .credentials.*.profile.json sidecar files from an earlier
# version of the tool that used on-disk profile caching. The email is now
# encoded directly in the slot filename (see Get-SlotFileInfo) so those
# sidecars are dead weight; removing them prevents stale emails from
# lingering in the directory. Swallowed errors: if the cleanup can't
# remove a file (lock / permissions) we leave it and move on — it is
# cosmetic, not functional.
#
# Returns an object with:
#   Slots        : array of { Name, Email, Path, IsActive }
#   ActiveLocked : $true if .credentials.json exists but could not be hashed
function Get-Slots {
    # One-time sidecar cleanup. Cheap (fires only when sidecars exist).
    $orphans = Get-ChildItem -LiteralPath $CredDir -Filter '.credentials.*.profile.json' -ErrorAction SilentlyContinue
    foreach ($o in $orphans) {
        Remove-Item -LiteralPath $o.FullName -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath (Join-Path $CredDir '.credentials.profile.json')) {
        Remove-Item -LiteralPath (Join-Path $CredDir '.credentials.profile.json') -Force -ErrorAction SilentlyContinue
    }

    $files = @(
        Get-ChildItem -LiteralPath $CredDir -Filter '.credentials.*.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.credentials.json' } |
            Sort-Object -Property Name
    )

    $activeHash   = $null
    $activeLocked = $false
    if (Test-Path -LiteralPath $CredFile) {
        try {
            $activeHash = (Get-FileHash -LiteralPath $CredFile -Algorithm SHA256).Hash
        }
        catch {
            $activeLocked = $true
        }
    }

    $slots = foreach ($file in $files) {
        $parsed = Get-SlotFileInfo -FileName $file.Name
        if (-not $parsed) { continue }

        $isActive = $false
        if ($activeHash) {
            try {
                $isActive = ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -eq $activeHash)
            }
            catch {
                $isActive = $false
            }
        }

        [pscustomobject]@{
            Name     = $parsed.Name
            Email    = $parsed.Email
            Path     = $file.FullName
            IsActive = $isActive
        }
    }

    return [pscustomobject]@{
        Slots        = @($slots)
        ActiveLocked = $activeLocked
    }
}

# Find a slot file by its parsed slot-name, regardless of whether the
# file on disk has the labeled `(email)` suffix or not. Returns the
# matching slot object (same shape as entries in Get-Slots.Slots) or
# $null when no slot matches. Used by Invoke-SwitchAction /
# Invoke-RemoveAction / Invoke-UsageAction so callers can reference a
# slot by user-visible name only.
function Find-SlotByName {
    Param ([String] $Name)

    $info = Get-Slots
    return $info.Slots | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

# We are determining which slot should become active when `switch` is
# called without an explicit name. Behavior:
#   * No slots saved       -> throw (nothing to rotate to).
#   * One slot, active     -> print warning and return $null (caller exits).
#   * Active slot found    -> return { To; HasActiveMatch=$true; Locked=$false }
#                              for the next slot (alphabetical, wraps).
#   * No active match      -> return { To=first; HasActiveMatch=$false;
#                              Locked=<bool> } so the caller can emit a
#                              context-appropriate advisory (locked active
#                              file vs. missing / unrecognized active file).
#
# `To` is a `{ Name; Email }` object (Email may be $null for unlabeled
# slots) so callers can render the filename-encoded email inline without
# re-looking-up the slot. The previous `From` field was dropped when
# Invoke-SwitchAction's rotation banner was retired in favour of the
# slot-table-beneath layout — no caller renders it any more. `HasActiveMatch`
# stayed because the caller still differentiates the happy path from the
# no-active-match advisory branch.
function Get-NextSlotName {
    $info  = Get-Slots
    $slots = @($info.Slots)

    if ($slots.Count -eq 0) {
        throw "No slots saved. Use: sca save <name>"
    }

    $activeIdx = -1
    for ($i = 0; $i -lt $slots.Count; $i++) {
        if ($slots[$i].IsActive) { $activeIdx = $i; break }
    }

    if ($slots.Count -eq 1 -and $activeIdx -eq 0) {
        Write-Host "[Switch] Only one slot ($(Format-SlotIdentity -Name $slots[0].Name -Email $slots[0].Email)) and it is already active. Nothing to do." -ForegroundColor "Yellow"
        return $null
    }

    $toSlot = if ($activeIdx -lt 0) { $slots[0] } else { $slots[($activeIdx + 1) % $slots.Count] }

    return [pscustomobject]@{
        To             = [pscustomobject]@{ Name = $toSlot.Name; Email = $toSlot.Email }
        HasActiveMatch = ($activeIdx -ge 0)
        Locked         = ($activeIdx -lt 0 -and $info.ActiveLocked)
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

    Write-Host "[Install] Installed! Close and reopen PowerShell, then use: sca save <name>" -ForegroundColor "Green"
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
            Write-Host "[Uninstall] No Claude Account Switcher block found; profile unchanged." -ForegroundColor "Yellow"
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
        Write-Host "[Uninstall] Uninstalled. Close and reopen PowerShell to remove the alias." -ForegroundColor "Red"
    }
}

# We verify that hardlinks can be created inside the credentials directory
# before attempting any operation that depends on them.  This catches common
# blockers (FAT32, network share, non-NTFS volume) with a clear error so the
# user knows the environment does not support this feature.
function Test-HardlinkSupport {
    $sourceFile = Join-Path $CredDir '.scahardlink.source'
    $linkFile   = Join-Path $CredDir '.scahardlink.target'

    try {
        # Clean up from a previous failed run.
        Remove-Item -LiteralPath $sourceFile, $linkFile -Force -ErrorAction SilentlyContinue

        [System.IO.File]::WriteAllBytes($sourceFile, @())
        New-Item -ItemType HardLink -Path $linkFile -Target $sourceFile | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $sourceFile, $linkFile -Force -ErrorAction SilentlyContinue
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

    Test-HardlinkSupport

    # Find any pre-existing slot files for this slot name (labeled or
    # unlabeled). We'll delete them before writing the new one so the
    # save is idempotent even when the stored account has changed (and
    # therefore the labeled form changes).
    $existing = @(Get-Slots).Slots | Where-Object { $_.Name -eq $safeName }

    # Write to the unlabeled filename first; rename to the labeled form
    # only after we successfully fetch the OAuth profile. This keeps
    # `sca save` working fully offline — if the profile fetch fails we
    # still end up with a usable slot, just without the email suffix.
    $unlabeledPath = Join-Path $CredDir (Get-SlotFileName -Name $safeName -Email $null)

    foreach ($e in $existing) {
        if ($e.Path -ne $unlabeledPath -and (Test-Path -LiteralPath $e.Path)) {
            Remove-Item -LiteralPath $e.Path -Force
        }
    }
    if (Test-Path -LiteralPath $unlabeledPath) {
        Remove-Item -LiteralPath $unlabeledPath -Force
    }

    Copy-Item -LiteralPath $CredFile -Destination $unlabeledPath
    Remove-Item -LiteralPath $CredFile -Force
    New-Item -ItemType HardLink -Path $CredFile -Target $unlabeledPath | Out-Null

    # Eager profile fetch. Success -> rename to labeled form. Failure
    # (offline, 401, timeout, profile missing email) -> leave as
    # unlabeled and emit a non-fatal yellow notice; the user can re-run
    # `sca save <name>` when online to upgrade.
    $finalEmail = $null
    $profile    = Get-SlotProfile -SlotPath $unlabeledPath
    if ($profile.Status -eq 'ok' -and $profile.Email) {
        $labeledName = Get-SlotFileName -Name $safeName -Email $profile.Email
        $labeledPath = Join-Path $CredDir $labeledName
        if ($labeledPath -ne $unlabeledPath) {
            if (Test-Path -LiteralPath $labeledPath) {
                Remove-Item -LiteralPath $labeledPath -Force
            }
            # Rename preserves the inode on NTFS, so the hardlink from
            # .credentials.json follows the file automatically. If the
            # rename fails (e.g. email contains an NTFS-invalid character
            # like '<' or ':'), fall back to the unlabeled form and emit
            # an advisory so the save still succeeds — user can re-run
            # later if Anthropic ever returns a sanitizable email.
            try {
                Rename-Item -LiteralPath $unlabeledPath -NewName $labeledName -ErrorAction Stop
                $finalEmail = $profile.Email
            }
            catch {
                Write-Host "[Save] Could not rename slot to labeled form (keeping unlabeled): $($_.Exception.Message)" -ForegroundColor "Yellow"
            }
        } else {
            # Labeled == unlabeled (slot name equals email, dedup form):
            # no rename needed, but the email is still known.
            $finalEmail = $profile.Email
        }
    } else {
        # Distinct user-facing message for the 'rate-limited' status —
        # otherwise users hitting Anthropic's 429 would see an opaque
        # "(slot saved unlabeled): rate-limited" line and might assume
        # the save itself was rate-limited (it wasn't; only the email
        # lookup was). The slot is fully usable; only the labeled
        # filename suffix is missing and can be fixed by re-running
        # `sca save <name>` once the rate limit clears. All other
        # non-ok statuses (offline, unauthorized, error, no-oauth) keep
        # the original generic wording with the underlying reason as
        # the tail; long messages are kept terse via Format-StatusErrorTail.
        if ($profile.Status -eq 'rate-limited') {
            Write-Host "[Save] Could not resolve account email (Anthropic API rate limited; slot saved unlabeled — re-run 'sca save $safeName' later to label it)." -ForegroundColor "Yellow"
        } else {
            $reason = if ($profile.Error) { Format-StatusErrorTail $profile.Error } else { $profile.Status }
            Write-Host "[Save] Could not resolve account email (slot saved unlabeled): $reason" -ForegroundColor "Yellow"
        }
    }

    $displayEmail = if ($finalEmail) { " ($finalEmail)" } else { '' }
    Write-Host "[Save] Saved as '$safeName'$displayEmail" -ForegroundColor "Green"
}

function Invoke-SwitchAction {
    Param ([String] $Name)

    # When invoked without a name, rotate to the next saved slot
    # (alphabetical, wrap-around). Get-NextSlotName returns $null for
    # the single-slot-already-active no-op and prints its own yellow
    # advisory; we return in that case so neither the success line nor
    # the table render (nothing has changed — the user already saw the
    # advisory).
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $rotation = Get-NextSlotName
        if (-not $rotation) { return }

        $safeName = $rotation.To.Name
        $toIdent  = Format-SlotIdentity -Name $rotation.To.Name -Email $rotation.To.Email

        # Yellow advisory branches: surface unusual states before the
        # green success line so the user notices them. Both states still
        # proceed with the rotation (we just couldn't identify what we
        # were rotating away from). The happy path (HasActiveMatch=true)
        # emits no advisory — the slot table beneath the success line
        # makes the transition self-evident via the `*` marker.
        if ($rotation.Locked) {
            Write-Host "[Switch] Active credentials file is locked; cannot identify current slot. Rotating to $toIdent." -ForegroundColor "Yellow"
        } elseif (-not $rotation.HasActiveMatch) {
            Write-Host "[Switch] No currently active slot detected. Rotating to $toIdent." -ForegroundColor "Yellow"
        }
    } else {
        $safeName = Get-SafeName $Name
    }

    $slot = Find-SlotByName -Name $safeName
    if (-not $slot) {
        throw "Slot '$safeName' not found."
    }

    Test-HardlinkSupport
    if (Test-Path -LiteralPath $CredFile) {
        Remove-Item -LiteralPath $CredFile -Force
    }
    New-Item -ItemType HardLink -Path $CredFile -Target $slot.Path | Out-Null

    # DarkYellow header line — matches the `[List] Saved slots` /
    # `[Usage] Plan usage` convention so all three actions
    # present a consistent table-header look. No trailing period: this
    # is a header, not a complete sentence (matches `[List] Saved slots`
    # and `[Usage] Plan usage` style). DarkYellow is reserved
    # for section titles; plain Yellow is reserved for advisories /
    # warnings (the locked-active, no-active-match, and single-slot
    # no-op branches above keep their Yellow on purpose).
    $toIdent = Format-SlotIdentity -Name $slot.Name -Email $slot.Email
    Write-Host "[Switch] Switched to $toIdent" -ForegroundColor "DarkYellow"

    # Render the saved-slot table beneath the success line so the user
    # sees the new active slot in context (the `*` marker now points at
    # the just-activated row). Re-enumerate via Get-Slots so IsActive
    # reflects the post-switch state. -SuppressHeader keeps the visual
    # weight low — the `[Switch]` line above is enough of a section
    # header. The hardlink-broken / ActiveLocked advisories that
    # Invoke-ListAction emits cannot fire here: we just established the
    # hardlink, and we just hashed .credentials.json successfully via
    # Test-HardlinkSupport + the New-Item call.
    Write-Host ''
    $postSwitchInfo = Get-Slots
    Format-ListTable -Slots @($postSwitchInfo.Slots) -SuppressHeader

    # Cyan `[Info]` apply hint, last line beneath the table. Split out
    # of the success line so the success line stays scannable as a
    # header. Suppressed for the single-slot no-op (which returns early
    # above and never reaches here) because nothing actually changed
    # and there is nothing to apply. Format-ListTable already emitted
    # a trailing blank line, so the Info line sits one row below the
    # last table row.
    Write-Host "[Info] Close and restart Claude Code to apply." -ForegroundColor "Cyan"
    Write-Host ''
}

function Invoke-ListAction {
    $info  = Get-Slots
    $slots = @($info.Slots)

    if ($slots.Count -eq 0) {
        Write-Host "[List] No slots saved yet. Use: sca save <name>" -ForegroundColor "Yellow"
        return
    }

    # Render the saved-slot table first; advisories follow below so the
    # data is the first thing the user reads (matches Format-UsageFrame's
    # ordering convention).
    Format-ListTable -Slots $slots

    # Get-Slots swallowed a hash failure on .credentials.json; surface
    # it here so the user knows why no slot is marked active.
    if ($info.ActiveLocked) {
        Write-Host "[List] Could not read active credentials (file may be locked); active slot cannot be marked." -ForegroundColor "Yellow"
    }

    # Self-check: .credentials.json should be a hardlink to the active slot
    # after the first switch/save.  If it is not, auto-sync is broken —
    # likely because Claude Code replaced the file via atomic rename during a
    # token refresh.  Surface this so the user can repair with `sca switch`.
    if (Test-Path -LiteralPath $CredFile) {
        $isHardlinked = (Get-Item -LiteralPath $CredFile).LinkType -eq 'HardLink'
        if (-not $isHardlinked) {
            $matchingSlot = $slots | Where-Object { $_.IsActive } | Select-Object -First 1
            if ($matchingSlot) {
                Write-Host "[List] Warning: .credentials.json is not hardlinked to '$($matchingSlot.Name)'. Auto-sync is broken. Run 'sca switch $($matchingSlot.Name)' to repair." -ForegroundColor "Yellow"
            } else {
                Write-Host "[List] Warning: .credentials.json is not hardlinked to any slot. Run 'sca save <name>' or 'sca switch <name>' to establish tracking." -ForegroundColor "Yellow"
            }
        }
    }
}

function Invoke-RemoveAction {
    Param ([String] $Name)

    $safeName = Get-SafeName $Name

    # Look up by parsed slot-name so both labeled and unlabeled filename
    # shapes resolve from a single user-visible name argument.
    $slot = Find-SlotByName -Name $safeName
    if (-not $slot) {
        throw "Slot '$safeName' not found."
    }

    Remove-Item -LiteralPath $slot.Path -Force
    Write-Host "[Remove] Removed '$safeName'" -ForegroundColor "Red"
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
# and any non-429 status — the caller's catch block falls through to its
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
# claude.exe 2.1.119). The slot file is rewritten IN-PLACE (truncate +
# write same inode) rather than replaced so any hardlink to .credentials.json
# survives the refresh. Returns the new access token on success; throws
# with a descriptive message on failure.
function Update-SlotTokens {
    Param ([String] $SlotPath)

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
        'Content-Type'   = 'application/json'
        'anthropic-beta' = $Script:AnthropicBeta
        'User-Agent'     = $Script:UsageUserAgent
    }

    $resp = Invoke-RestMethod -Method Post `
                              -Uri $Script:TokenEndpoint `
                              -Headers $headers `
                              -Body $body `
                              -TimeoutSec $Script:UsageTimeoutSec `
                              -ErrorAction Stop

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

    $newJson = $raw | ConvertTo-Json -Depth 10 -Compress

    # Set-Content truncates-and-writes the existing inode, which preserves
    # any hardlink to .credentials.json. A Move-Item-based atomic-write
    # would break the hardlink because it creates a new inode. utf8NoBOM
    # matches the encoding Claude Code uses for its own credentials file.
    Set-Content -LiteralPath $SlotPath -Value $newJson -NoNewline -Encoding utf8NoBOM

    return $newAccess
}

# Call /api/oauth/usage for one slot. Auto-refreshes a token that is
# expired or within 60s of expiry. Returns:
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

    # Refresh if expired OR within a 60s grace window — covers clock skew
    # and the case where the token technically has 30s left but would
    # expire mid-call.
    $threshold = [DateTime]::UtcNow.AddSeconds(60)
    if ($info.ExpiresAt -and $info.ExpiresAt -lt $threshold) {
        try {
            $accessToken = Update-SlotTokens -SlotPath $SlotPath
        }
        catch {
            # 429 from the token endpoint shares the rate-limit policy
            # with the usage endpoint below: serve fresh cached usage
            # data when available, otherwise surface a clean
            # 'rate-limited' status. No retry — the token endpoint shares
            # an upstream limiter with the usage endpoint, so a 5s sleep
            # would just extend the user's wait without changing the
            # outcome (and the watch loop will retry on its 60s tick).
            if (Test-Is429 $_.Exception) {
                if ($Script:SlotUsageCache.ContainsKey($SlotPath)) {
                    $entry = $Script:SlotUsageCache[$SlotPath]
                    if (([DateTime]::UtcNow - $entry.Timestamp).TotalMinutes -lt $Script:UsageCacheTTL) {
                        return [pscustomobject]@{ Status = 'ok'; Data = $entry.Data; IsCachedFallback = $true }
                    }
                }
                return [pscustomobject]@{ Status = 'rate-limited' }
            }
            # Non-429 refresh failure (timeout, 4xx other than 429, 5xx,
            # malformed JSON, …): the token IS expired and we couldn't
            # refresh it, so 'expired' remains the accurate label.
            return [pscustomobject]@{ Status = 'expired'; Error = $_.Exception.Message }
        }
    }

    $headers = @{
        'Authorization'  = "Bearer $accessToken"
        'anthropic-beta' = $Script:AnthropicBeta
        'Content-Type'   = 'application/json'
        'User-Agent'     = $Script:UsageUserAgent
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
        # limited periods — usage data only changes every few hours at most.
        # Three explicit branches (vs. the previous if/else where a stale
        # cache fell through to the bottom 'error' return at the end of
        # the catch — that hid behind Format-UsageTable's truncation but
        # mislabeled the status):
        #   1. Fresh cache  -> return cached as 'ok' with IsCachedFallback.
        #   2. Stale cache  -> 'rate-limited' (no retry; the cache being
        #                      stale means we've been seeing 429s for a
        #                      while and a 5s sleep won't change that).
        #   3. No cache yet -> one retry after a short delay; the original
        #                      back-to-back-poll-collision case.
        if ($status -eq 429) {
            if ($Script:SlotUsageCache.ContainsKey($SlotPath)) {
                $entry = $Script:SlotUsageCache[$SlotPath]
                if (([DateTime]::UtcNow - $entry.Timestamp).TotalMinutes -lt $Script:UsageCacheTTL) {
                    return [pscustomobject]@{ Status = 'ok'; Data = $entry.Data; IsCachedFallback = $true }
                }
                # Stale cache: drop straight to 'rate-limited' rather
                # than retry — see comment above.
                return [pscustomobject]@{ Status = 'rate-limited' }
            }
            # No cached data — retry once after a short delay so back-to-back
            # slot polls don't all hit the rate limit simultaneously.
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
                # Second attempt also failed — return clean rate-limited status.
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
# reads parse the filename via Get-SlotFileInfo — no HTTP. This keeps the
# email self-consistent with the stored OAuth tokens: the only way to
# update the email on a slot is to re-run `sca save`, which also re-runs
# this call against the freshly-saved tokens.
#
# The HTTP call mirrors Claude Code's Ql() shape exactly: Authorization +
# Content-Type only, no anthropic-beta / User-Agent. Deviating there for
# "consistency" would add drift risk without benefit, since Ql() is the
# known-good call shape.
function Get-SlotProfile {
    Param (
        [String] $SlotPath
    )

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

    # Share the expiry-threshold and refresh logic with Get-SlotUsage so
    # both endpoints behave identically under token rotation.
    $threshold = [DateTime]::UtcNow.AddSeconds(60)
    if ($info.ExpiresAt -and $info.ExpiresAt -lt $threshold) {
        try {
            $accessToken = Update-SlotTokens -SlotPath $SlotPath
        }
        catch {
            # Mirror Get-SlotUsage's 429 handling: if the token endpoint
            # is rate-limited, surface a clean 'rate-limited' status
            # rather than 'expired: <long 429 message>'. There is no
            # profile cache to fall back on (Get-SlotProfile is no-cache
            # by design — see this function's docstring), so the
            # rate-limited status is the only signal we can give.
            if (Test-Is429 $_.Exception) {
                return [pscustomobject]@{ Status = 'rate-limited' }
            }
            return [pscustomobject]@{ Status = 'expired'; Error = $_.Exception.Message }
        }
    }

    $headers = @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type'  = 'application/json'
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

# Render an ISO-8601 reset timestamp as a compact relative delta for the
# summary table column. Verified shape from live /api/oauth/usage:
#   "resets_at": "2026-04-24T19:50:00.027299+02:00"  (ISO with tz offset)
#                 OR null (no active window yet; pairs with 0% utilization)
# Output (variant C: hours+minutes under 24h, integer hours above):
#   null / empty / parse fail        -> '—' (defensive: never throws)
#   timestamp in the past            -> 'now'
#   < 1 hour                         -> 'in 42m'
#   >= 1 hour and < 24 hours         -> 'in 2h 14m'   (minute precision matters in the session window)
#   >= 24 hours                      -> 'in 42h'      (integer total hours; minutes are noise at weekly scale)
function Format-ResetDelta {
    Param ($ResetsAt)

    if ($null -eq $ResetsAt -or $ResetsAt -eq '') { return '—' }

    $target = $null
    try {
        # Accept both ISO-8601 strings (live API) and DateTimeOffset/DateTime
        # (tests may pass pre-parsed values).
        if ($ResetsAt -is [DateTimeOffset]) {
            $target = $ResetsAt
        } elseif ($ResetsAt -is [DateTime]) {
            $target = [DateTimeOffset]$ResetsAt
        } else {
            $target = [DateTimeOffset]::Parse([string]$ResetsAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        }
    }
    catch {
        return '—'
    }

    $delta = $target - [DateTimeOffset]::UtcNow
    if ($delta.TotalSeconds -le 0) { return 'now' }

    if ($delta.TotalHours -ge 24) {
        # Total hours, floor — at this scale minutes would only add noise.
        $h = [int][math]::Floor($delta.TotalHours)
        return "in ${h}h"
    }

    $h = [int]$delta.Hours
    $m = [int]$delta.Minutes
    if ($h -gt 0) { return "in ${h}h ${m}m" }
    return "in ${m}m"
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

    if ($null -eq $ResetsAt -or $ResetsAt -eq '') { return '—' }

    $target = $null
    try {
        if ($ResetsAt -is [DateTimeOffset]) {
            $target = $ResetsAt
        } elseif ($ResetsAt -is [DateTime]) {
            $target = [DateTimeOffset]$ResetsAt
        } else {
            $target = [DateTimeOffset]::Parse([string]$ResetsAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
        }
    }
    catch {
        return '—'
    }

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
    # stays visible for emails — the domain is the disambiguating part
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
#   numeric utilization, reset      -> ' 34% in 2h 14m'      (normal row)
# Width is variable because reset deltas range from 'now' (3 chars) to
# 'in 103h' (7 chars) to 'in 2h 14m' (9 chars); the table's column
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
         default         { return 'Gray' }
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
#   * Synth <active> matched (Name == $Script:ActiveSlotNameMatched)
#     EXCLUDED — would double-count its hash-paired saved slot.
#   * Synth <active> (unsaved) INCLUDED — separate quota pool.
#   * Buckets with null/missing utilization counted as 0% used.
#
# Color thresholds via $Script:AggregateRedPct / $Script:AggregateYellowPct.
#
# Output: 5 Write-Host lines (blank, Session, blank, Week, blank). When
# no qualifying rows exist, emits nothing — the table below renders
# cleanly without orphan padding.
#
# Uses Write-Host (information stream / 6) rather than Write-Progress
# (stream 4) for three reasons: (1) the suite's `6>&1 | Out-String`
# capture pattern would miss stream-4 output; (2) Write-Progress is
# host-managed and transient — it would not sit inline above the table;
# (3) it does not compose with Clear-Host watch redraws.
function Format-AggregateBars {
    Param (
        [object[]] $Results,
        [int]      $TotalLineWidth
    )

    if (-not $Results) { return }

    $eligible = @($Results | Where-Object {
        $_.Status -eq 'ok' -and $_.Name -ne $Script:ActiveSlotNameMatched
    })
    if ($eligible.Count -eq 0) { return }

    $n   = $eligible.Count
    $cap = $n * 100

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

        $usedSum = 0.0
        foreach ($r in $eligible) {
            if ($r.Data -and $r.Data.$key -and $null -ne $r.Data.$key.utilization) {
                $u = [double]$r.Data.$key.utilization
                if ($u -lt 0)   { $u = 0 }
                if ($u -gt 100) { $u = 100 }
                $usedSum += $u
            }
            # null / missing utilization -> 0 used.
        }

        # usedSum is in [0, cap] by construction (each $u clamped to [0,100],
        # summed N times with cap = N*100), so no outer clamp needed here.
        $usedPct = [int][math]::Round(($usedSum / $cap) * 100)

        $filled = [int][math]::Round(($usedPct / 100.0) * $barWidth)
        if ($filled -lt 0)         { $filled = 0 }    # defense-in-depth
        if ($filled -gt $barWidth) { $filled = $barWidth }

        $bar = ('█' * $filled) + ('░' * ($barWidth - $filled))

        $color = Get-AggregateBarColor -UsedPct $usedPct

        $line = '  {0,-8}[{1}] {2,3}%' -f $label, $bar, $usedPct
        Write-Host $line -ForegroundColor $color
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
#   string ('100% in 2h 37m'); width auto-fits to the widest cell in the batch.
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
        [switch]   $IncludeAggregateBars
    )

    if (-not $Results) { return }

    # Precompute per-row cell content so column widths can auto-fit.
    $rows = foreach ($r in $Results) {
        $fiveCell  = '   —'
        $sevenCell = '   —'

        if ($r.Status -eq 'ok' -and $r.Data) {
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
        # wrap the row — the previous 'expired' arm interpolated the raw
        # message with no length cap, which produced multi-line table
        # rows when the token endpoint returned 429 with a long body.
        $statusText = switch ($r.Status) {
            'ok'           { Get-PlanStatus $r.Data }
            'no-oauth'     { 'no-oauth (api key or non-claude.ai slot)' }
            'expired'      { if ($r.Error) { "expired: $(Format-StatusErrorTail $r.Error)" } else { 'expired (run sca switch to refresh)' } }
            'unauthorized' { 'unauthorized (token revoked; run sca switch then /login)' }
            'error'        { "error: $(Format-StatusErrorTail $r.Error)" }
            'rate-limited' { 'rate-limited' }
            default        { [string]$r.Status }
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

    # Total rendered line width — used to fit-to-table the aggregate
    # bars above the header. Mirrors the $fmt pattern: 2 (indent) + 1
    # (marker) + 1 (sep) + nameW + 2 + acctW + 2 + fiveW + 2 + sevenW
    # + 2 + statusW.
    $totalLineWidth = 2 + 1 + 1 + $nameW + 2 + $acctW + 2 + $fiveW + 2 + $sevenW + 2 + $statusW

    Write-Host "[Usage] Plan usage" -ForegroundColor "DarkYellow"
    Write-Host ''
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
        Write-Host ($fmt -f $entry.Marker, $entry.Name, $entry.Account, $entry.Five, $entry.Seven, $entry.Status) -ForegroundColor $color
    }
}

# Render the saved-slot inventory as a fixed-width 2-data-column table:
# `Slot | Account`, plus the leading active-marker column. Mirrors
# Format-UsageTable's column-width algorithm and row-coloring rules so
# `sca list` and `sca usage` look like sibling views (same header style,
# same active-marker conventions, same Account-cell truncation). Pure
# offline render — no network calls, unlike Format-UsageTable. Used by
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
        Write-Host "[List] Saved slots" -ForegroundColor "DarkYellow"
        Write-Host ''
    }
    Write-Host ($fmt -f ' ',  'Slot',         'Account')
    Write-Host ($fmt -f ' ', ('-' * $nameW), ('-' * $acctW))

    foreach ($entry in $rows) {
        $color = if ($entry.Slot.IsActive) { 'Green' } else { $null }
        if ($color) {
            Write-Host ($fmt -f $entry.Marker, $entry.Name, $entry.Account) -ForegroundColor $color
        } else {
            Write-Host ($fmt -f $entry.Marker, $entry.Name, $entry.Account)
        }
    }

    # Trailing blank line so the table has breathing room before the
    # next prompt (or before any advisory the caller emits below). Mirrors
    # Format-UsageFrame's footer behavior — both `sca list` / `sca switch`
    # / `sca usage` now end with a blank line so the views look consistent.
    Write-Host ''
}

# Render the full response for a single slot in verbose form. Used when
# `sca usage <name>` targets one slot; shows absolute local-tz reset times
# (Claude-Code-style) for the two buckets we care about: five_hour
# ("Current session") and seven_day ("Current week (all models)"). Other
# buckets returned by the endpoint are intentionally not rendered here
# because they are not the limits the user is tracking; they remain
# accessible via `sca usage <name> -json`.
function Format-UsageVerbose {
    Param ([object] $Result)

    $name = $Result.Name
    Write-Host "[Usage] Slot '$name'$(if ($Result.IsActive) { ' (active)' })" -ForegroundColor "DarkYellow"

    # Surface the OAuth account email whenever we could resolve it, so the
    # verbose drill-down answers the "which account is this?" question
    # without forcing the user to cross-reference the table.
    if ($Result.PSObject.Properties['Email'] -and $Result.Email) {
        Write-Host "  Account: $($Result.Email)" -ForegroundColor "DarkGray"
    }

    if ($Result.Status -ne 'ok') {
        Format-UsageTable -Results @($Result)
        return
    }
    if (-not $Result.Data) {
        Write-Host "  (empty response)" -ForegroundColor "DarkGray"
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
    Write-Host ("  Status:  $statusLine") -ForegroundColor $statusColor

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
        Write-Host "  No plan-usage data (account may not have a subscription, or has not made a live API call yet)." -ForegroundColor "DarkGray"
        return
    }

    & $renderOne 'Session' $five
    & $renderOne 'Week'    $seven
}

# --- usage action: data + rendering split ---------------------------------
#
# Invoke-UsageAction was originally a single function that both gathered
# per-slot usage data and wrote the output. Splitting the two makes
# `sca usage -watch` possible: the watch loop re-gathers a fresh snapshot
# each poll, keeps the previous snapshot visible during HTTP failures,
# and calls the same frame renderer that the one-shot path uses. The
# split also keeps the test matrix clean — unit tests mock the data
# layer and assert on the rendered frame.
#
# Snapshot shape (Get-UsageSnapshot):
#   Results          : array of per-slot result rows
#                      { Name, IsActive, Status, Data, Error, Email }
#   HardlinkBroken   : $true when .credentials.json is a regular file
#                      (not a hardlink) — drives the synth <active> row
#                      and the post-table advisory.
#   MatchedSlotName  : saved-slot whose content matches .credentials.json,
#                      or $null. Used only to steer the advisory wording.
#   NoSlots          : $true when there are zero saved slots AND no synth
#                      row to render. Caller prints the "no slots" hint.
#   HasSynthRow      : $true when a synth <active> row was appended to
#                      Results. Convenience flag so the renderer does
#                      not re-derive it.

# Gather the per-slot usage snapshot used by both the one-shot action and
# the live watch loop. Performs all network IO (Get-SlotUsage per slot,
# plus one extra Get-SlotProfile for the synth <active> row when the
# hardlink is broken). Never renders; callers decide between table,
# verbose, JSON, and watch-frame presentations.
function Get-UsageSnapshot {
    Param ([String] $Name)

    $info  = Get-Slots
    $slots = @($info.Slots)

    # Decide whether to synthesize a row for .credentials.json itself.
    # The active-slot detection in Get-Slots is by content-hash; but what
    # Claude Code actually reads is whichever file inode .credentials.json
    # refers to. When .credentials.json is a standalone regular file (not
    # a hardlink to any saved slot), any refresh Claude Code performed
    # won't flow into the saved slots, and our content-hash match may
    # coincide with a saved slot only because of a prior identical snapshot.
    # In that case we add a synthetic <active> row so the user sees the
    # usage that Claude Code itself would see.
    $credExists     = Test-Path -LiteralPath $CredFile
    $credIsHardlink = $false
    if ($credExists) {
        try {
            $credIsHardlink = (Get-Item -LiteralPath $CredFile).LinkType -eq 'HardLink'
        }
        catch {
            # File open / locked during Get-Item: treat as non-hardlink for
            # the purpose of this check; the usage call itself will surface
            # any real read failure as an error row.
            $credIsHardlink = $false
        }
    }

    $needSynthActive = $credExists -and -not $credIsHardlink
    $synthName       = $null
    $matchedSlotName = $null
    if ($needSynthActive) {
        $matchedSlotName = ($slots | Where-Object { $_.IsActive } | Select-Object -First 1 -ExpandProperty Name)
        $synthName       = if ($matchedSlotName) { $Script:ActiveSlotNameMatched } else { $Script:ActiveSlotNameUnsaved }
        # A synthetic <active> row carries the `*` marker; suppress the
        # content-hash match on saved slots so the `*` appears exactly
        # once. The saved slot's row still lists; just without the marker.
        foreach ($s in $slots) { $s.IsActive = $false }
    }

    if ($slots.Count -eq 0 -and -not $needSynthActive) {
        return [pscustomobject]@{
            Results         = @()
            HardlinkBroken  = $false
            MatchedSlotName = $null
            NoSlots         = $true
            HasSynthRow     = $false
        }
    }

    # -Name filter: accept saved-slot names AND the two synth labels (they
    # contain characters Get-SafeName would reject, so we special-case
    # them before sanitizing). When a synth label is requested but
    # .credentials.json is absent or normally-linked, fall through to the
    # saved-slot match path which will throw 'not found' as usual.
    $selectedSlots    = $slots
    $includeSynthetic = $needSynthActive
    if ($Name) {
        if ($Name -eq $Script:ActiveSlotNameUnsaved -or $Name -eq $Script:ActiveSlotNameMatched -or $Name -eq '<active>') {
            if (-not $needSynthActive) {
                throw "No synthetic active slot present (.credentials.json is hardlinked or missing). Use a saved slot name."
            }
            $selectedSlots    = @()
            $includeSynthetic = $true
        } else {
            $safeName         = Get-SafeName $Name
            $selectedSlots    = @($slots | Where-Object { $_.Name -eq $safeName })
            $includeSynthetic = $false
            if ($selectedSlots.Count -eq 0) {
                throw "Slot '$safeName' not found."
            }
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
            # Get-SlotFileInfo). No HTTP call here — the only source of
            # truth for a slot's email is its filename, which was written
            # by `sca save` from a fresh profile fetch at that moment.
            Email            = $slot.Email
            IsCachedFallback = $usage.IsCachedFallback
        }
    }

    if ($includeSynthetic) {
        $activeUsage = Get-SlotUsage -SlotPath $CredFile
        # For the synth <active> row we do not have a filename-encoded
        # email (the active file is always `.credentials.json`), so we
        # keep the live profile call only for this row. At most one
        # extra HTTP call per snapshot, and only when a synth row is
        # rendered (hardlink broken / fresh login state).
        $activeProfile = Get-SlotProfile -SlotPath $CredFile
        $synthRow = [pscustomobject]@{
            Name     = $synthName
            IsActive = $true
            Status   = $activeUsage.Status
            Data     = $activeUsage.Data
            Error            = $activeUsage.Error
            Email            = if ($activeProfile.Status -eq 'ok') { $activeProfile.Email } else { $null }
            IsCachedFallback = $activeUsage.IsCachedFallback
        }
        # Append so the synth row appears after the saved slots, matching
        # the `sca list` ordering convention.
        $results = @($results) + $synthRow
    }

    return [pscustomobject]@{
        Results         = @($results)
        HardlinkBroken  = $needSynthActive
        MatchedSlotName = $matchedSlotName
        NoSlots          = $false
        HasSynthRow      = $includeSynthetic
        HasCacheFallback = ($results | Where-Object { $_.IsCachedFallback }).Count -gt 0
    }
}

# Render one usage frame (table OR verbose view, plus optional advisory
# and optional footer). Pure presentation — does not call the network.
# Used by both the one-shot action and the live watch loop; the same
# frame renders identically in either context so tests assert on the
# frame shape without running the loop.
#
# -Name        : when set, selects the single-slot verbose view. Empty
#                -> summary table.
# -Snapshot    : output of Get-UsageSnapshot for this frame.
# -Footer      : optional string printed below the table / verbose view
#                and below the hardlink advisory, for the watch-mode
#                "Last updated / next poll / keybindings" line. Multi-
#                line strings are split and each line rendered in the
#                DarkGray information color.
# -SuppressAdvisory : when true, skip the hardlink-broken advisory (the
#                verbose single-slot drill-down already-targeted; the
#                warning is noise there).
function Format-UsageFrame {
    Param (
        [String]                $Name,
        [pscustomobject]        $Snapshot,
        [AllowEmptyString()]
        [AllowNull()] [String]  $Footer,
        [switch]                $SuppressAdvisory
    )

    if (-not $Snapshot -or $Snapshot.NoSlots) {
        Write-Host "[Usage] No slots saved yet. Use: sca save <name>" -ForegroundColor "Yellow"
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
        # this switch — bars are a pool-level summary and would be
        # off-topic on a single-slot drill-down.
        Format-UsageTable -Results @($results) -IncludeAggregateBars
    }

    # Cache-fallback advisory: inform the user that data is stale because
    # an Anthropic API returned 429 and we fell back to cached responses.
    # The 429 may have come from /api/oauth/usage (existing path) OR from
    # /v1/oauth/token during a token refresh that triggered the cache
    # fallback in Get-SlotUsage's refresh-failure handler — hence the
    # endpoint-agnostic wording.
    if ($Snapshot.HasCacheFallback) {
        Write-Host "  [Usage] Warning: Anthropic API rate limited — displaying cached data." -ForegroundColor "Yellow"
    }

    # Hardlink-broken advisory: only on the summary table; the verbose
    # drill-down is already a targeted view and does not need it.
    if ($Snapshot.HardlinkBroken -and -not $Name -and -not $SuppressAdvisory) {
        if ($Snapshot.MatchedSlotName) {
            Write-Host "[Usage] Warning: .credentials.json is not hardlinked to '$($Snapshot.MatchedSlotName)' (auto-sync broken). Run 'sca switch $($Snapshot.MatchedSlotName)' to repair." -ForegroundColor "Yellow"
        } else {
            Write-Host "[Usage] Warning: .credentials.json is not hardlinked to any saved slot. Run 'sca save <name>' to capture the active session, or 'sca switch <name>' to overwrite it with a saved slot." -ForegroundColor "Yellow"
        }
    }

    if ($Footer) { Format-UsageFooter $Footer } else { Write-Host '' }
}

# Render the multi-line footer block under a usage frame. Internal helper
# for Format-UsageFrame; extracted so the watch loop and any future
# footer-consumers share one wrapping policy.
function Format-UsageFooter {
    Param ([String] $Footer)

    Write-Host ""
    foreach ($line in ($Footer -split "`r?`n")) {
        Write-Host $line -ForegroundColor "DarkGray"
    }
}

function Invoke-UsageAction {
    Param (
        [String] $Name,
        [switch] $json,
        [switch] $watch,
        [int]    $interval = $Script:UsageWatchMinInterval
    )

    if ($json -and $watch) {
        throw "-watch and -json cannot be combined; -watch is interactive, -json is for scripting."
    }

    if ($watch) {
        Invoke-UsageWatch -Name $Name -Interval $interval
        return
    }

    $snapshot = Get-UsageSnapshot -Name $Name

    if ($json) {
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

# Minimum poll interval for -watch. Matches the default so users can only
# adjust the interval upward; the floor is the "polite" setting for the
# unofficial endpoint and we refuse to go faster. Clamping up (rather
# than throwing) keeps the call ergonomic for users who just typed a
# round number.
$Script:UsageWatchMinInterval = 60

# Live `sca usage -watch` loop: redraws once per second and re-polls the
# endpoint every -Interval seconds. Interactive only — throws when output
# is redirected because the alt-screen + cursor-control sequences would
# poison a captured log. Exits on Ctrl-C via the runtime's default
# handler; the `finally` block leaves the alternate screen buffer and
# restores cursor visibility. On HTTP failure the previous snapshot
# stays visible and an advisory is appended to the footer so the display
# never blanks.
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
# private mode and fall back to the previous Clear-Host-style flicker
# — no regression. Renderer functions are reused unchanged; only this
# loop emits the wrapper sequences.
#
# The loop is deliberately simple: blocking Invoke-RestMethod (via
# Get-UsageSnapshot) inside the poll step, then a plain 1 s sleep
# between frames. A runspace-based async poll would feel snappier
# during the HTTP call but adds substantial complexity that is not
# worth v1's budget.
function Invoke-UsageWatch {
    Param (
        [String] $Name,
        [int]    $Interval = $Script:UsageWatchMinInterval
    )

    if ([Console]::IsOutputRedirected) {
        throw "-watch requires an interactive terminal; for scripted output use 'sca usage -json'."
    }

    if ($Interval -lt $Script:UsageWatchMinInterval) {
        Write-Host "[Usage] -interval below minimum; clamping to $($Script:UsageWatchMinInterval)s (polite to the unofficial endpoint)." -ForegroundColor "Yellow"
        $Interval = $Script:UsageWatchMinInterval
    }

    $origCursor = [Console]::CursorVisible
    $enteredAlt = $false
    try {
        # Enter alt screen buffer + hide cursor in one write. The alt
        # buffer gives a clean canvas and ensures the user's pre-watch
        # scrollback is restored on exit. Cursor-hide stops the caret
        # from blinking inside the table during the (atomic) repaint.
        [Console]::Out.Write("`e[?1049h`e[?25l")
        $enteredAlt = $true
        [Console]::CursorVisible = $false

        $snapshot      = $null
        $lastPoll      = [DateTime]::MinValue
        $lastPollError = $null

        while ($true) {
            $now = [DateTime]::Now
            $dueForPoll = ($null -eq $snapshot) -or (($now - $lastPoll).TotalSeconds -ge $Interval)

            if ($dueForPoll) {
                try {
                    $snapshot      = Get-UsageSnapshot -Name $Name
                    $lastPollError = $null
                }
                catch {
                    # Keep the previous snapshot visible. If the very first
                    # poll failed we still need to show SOMETHING below the
                    # header, so render an empty frame and surface the
                    # error in the footer — the user can still quit cleanly.
                    $lastPollError = $_.Exception.Message
                }
                $lastPoll = $now
            }

            $secsToNext = [math]::Max(0, [int][math]::Ceiling($Interval - ($now - $lastPoll).TotalSeconds))
            $footerLines = @(
                "[Watch] Last poll: $($lastPoll.ToString('HH:mm:ss'))  |  next in ${secsToNext}s"
            )
            if ($lastPollError) {
                $footerLines += "[Watch] Last poll failed: $lastPollError (keeping previous data; will retry on next tick)"
            }
            $footer = $footerLines -join "`n"

            # Atomic frame: begin sync update, clear screen, cursor home,
            # draw via the existing renderer, end sync update. All output
            # between ESC[?2026h and ESC[?2026l is buffered by the
            # terminal and presented in one swap — no flicker on
            # terminals that support the mode (Win Terminal, VS Code,
            # iTerm2, kitty, alacritty, WezTerm, foot, gnome-terminal,
            # mintty, modern ConHost). Older terminals ignore the
            # unknown DEC mode markers and exhibit the prior
            # Clear-Host-style flicker — no regression.
            [Console]::Out.Write("`e[?2026h`e[2J`e[H")
            if ($null -ne $snapshot) {
                # -SuppressAdvisory: during watch mode the hardlink warning
                # is still useful but fires once per second of redraw; that
                # is loud. Show it only on every poll boundary (when we
                # just refreshed) so the user gets the message without
                # the header flashing it constantly.
                $suppress = -not $dueForPoll
                Format-UsageFrame -Name $Name -Snapshot $snapshot -Footer $footer -SuppressAdvisory:$suppress
            } else {
                # First poll failed and we have nothing to render yet.
                Write-Host "[Watch] Waiting for first successful /api/oauth/usage response..." -ForegroundColor "Yellow"
                Format-UsageFooter $footer
            }
            [Console]::Out.Write("`e[?2026l")

            # 1-second inter-frame wait. Ctrl-C terminates the loop via
            # the runtime's default handler; the surrounding `finally`
            # block leaves the alt buffer and restores cursor visibility
            # on exit.
            Start-Sleep -Seconds 1
        }
    }
    finally {
        # Order matters: show cursor + leave alt buffer in one write so
        # the user's pre-watch terminal state is restored atomically.
        # The CursorVisible API restore is belt-and-suspenders for the
        # .NET-side state.
        if ($enteredAlt) {
            [Console]::Out.Write("`e[?25h`e[?1049l")
        }
        [Console]::CursorVisible = $origCursor
    }
}

# We are wrapping the top-level dispatcher in Invoke-Main so the script
# file is safe to dot-source from tests. Help uses `return` instead of
# `exit` to avoid killing a host that dot-sourced us; the redundant
# `exit` calls from install/uninstall branches are dropped because the
# script naturally exits at the end of Invoke-Main with status 0.
function Invoke-Main {
    if ($help -or $Action -eq "help" -or $Action -eq "") {
        Show-Help
        return
    }

    # We are ensuring the credentials directory exists before
    # attempting any file operations within it.
    if (-not (Test-Path -LiteralPath $CredDir)) {
        New-Item -ItemType Directory -Path $CredDir -Force | Out-Null
    }

    switch ($Action) {
        "install"   { Add-To-Profile }
        "uninstall" { Remove-From-Profile }
        "save"      { Invoke-SaveAction   -Name $Name }
        "switch"    { Invoke-SwitchAction -Name $Name }
        "list"      { Invoke-ListAction }
        "remove"    { Invoke-RemoveAction -Name $Name }
        "usage"     { Invoke-UsageAction  -Name $Name -json:$json -watch:$watch -interval $interval }
    }
}

# We are detecting dot-sourcing by checking the invocation name; the
# dispatcher only runs when the script is invoked normally, not when
# tests dot-source the file to exercise individual functions in
# isolation.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}