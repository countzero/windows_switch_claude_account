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

    # -Json: emit the `usage` action's output as a machine-parseable JSON
    # object keyed by slot name. Ignored by other actions.
    [switch]
    $Json,

    # -NoRefresh: skip the OAuth refresh that `usage` normally performs on
    # expired tokens. Marks those slots as 'expired' instead of hitting the
    # token endpoint. Ignored by other actions.
    [switch]
    $NoRefresh
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
        "  usage [name]     Show 5h / weekly plan usage per slot (network; unofficial Anthropic API)",
        "  install          Add 'sca' + 'switch-claude-account' aliases to your PS profile",
        "  uninstall        Remove the aliases from your PS profile",
        "  help, -h         Show this help",
        "",
        "EXAMPLES",
        "  $cmd save work           # save current login as 'work'",
        "  $cmd switch personal     # activate the 'personal' slot",
        "  $cmd switch              # rotate to the next saved slot",
        "  $cmd list                # show all slots",
        "  $cmd remove old-acct     # delete a slot",
        "  $cmd usage               # show 5h + weekly usage for every slot",
        "  $cmd usage -NoRefresh    # do not auto-refresh expired OAuth tokens",
        "  $cmd usage -Json         # emit usage as JSON for scripting",
        "",
        "FILES",
        "  Active login : $CredFile",
        "  Saved slots  : $CredDir\.credentials.<name>.json",
        "  PS profile   : $ProfilePath",
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
#   * Active slot found    -> return { From, To } for the next slot (wraps).
#   * No active match      -> return { From=$null, To=first, Locked=? } so
#                              the caller can emit a context-appropriate
#                              warning (locked active file vs. missing /
#                              unrecognized active file).
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
        Write-Host "[Switch] Only one slot ('$($slots[0].Name)') and it is already active. Nothing to do." -ForegroundColor "Yellow"
        return $null
    }

    if ($activeIdx -lt 0) {
        return [pscustomobject]@{
            From   = $null
            To     = $slots[0].Name
            Locked = $info.ActiveLocked
        }
    }

    $nextIdx = ($activeIdx + 1) % $slots.Count
    return [pscustomobject]@{
        From   = $slots[$activeIdx].Name
        To     = $slots[$nextIdx].Name
        Locked = $false
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
    $finalPath = $unlabeledPath
    $profile   = Get-SlotProfile -SlotPath $unlabeledPath
    if ($profile.Status -eq 'ok' -and $profile.Email) {
        $labeledName = Get-SlotFileName -Name $safeName -Email $profile.Email
        $labeledPath = Join-Path $CredDir $labeledName
        if ($labeledPath -ne $unlabeledPath) {
            if (Test-Path -LiteralPath $labeledPath) {
                Remove-Item -LiteralPath $labeledPath -Force
            }
            # Rename preserves the inode on NTFS, so the hardlink from
            # .credentials.json follows the file automatically.
            Rename-Item -LiteralPath $unlabeledPath -NewName $labeledName
            $finalPath = $labeledPath
        }
    } else {
        $reason = if ($profile.Error) { $profile.Error } else { $profile.Status }
        Write-Host "[Save] Could not resolve account email (slot saved unlabeled): $reason" -ForegroundColor "Yellow"
    }

    $displayEmail = if ($profile.Status -eq 'ok' -and $profile.Email) { " ($($profile.Email))" } else { '' }
    Write-Host "[Save] Saved as '$safeName'$displayEmail" -ForegroundColor "Green"
}

function Invoke-SwitchAction {
    Param ([String] $Name)

    # When invoked without a name, rotate to the next saved slot
    # (alphabetical, wrap-around). Get-NextSlotName returns $null for
    # the single-slot-already-active no-op and prints its own warning,
    # so we simply return in that case rather than emit a duplicate msg.
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $rotation = Get-NextSlotName
        if (-not $rotation) { return }

        $safeName = $rotation.To
        if ($rotation.From) {
            Write-Host "[Switch] Rotating from '$($rotation.From)' to '$safeName'" -ForegroundColor "Cyan"
        } elseif ($rotation.Locked) {
            Write-Host "[Switch] Active credentials file is locked; cannot identify current slot. Rotating to '$safeName'." -ForegroundColor "Yellow"
        } else {
            Write-Host "[Switch] No currently active slot detected. Rotating to '$safeName'." -ForegroundColor "Yellow"
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
    Write-Host "[Switch] Switched to '$safeName'. Close and restart Claude Code to apply." -ForegroundColor "Cyan"
}

function Invoke-ListAction {
    $info  = Get-Slots
    $slots = @($info.Slots)

    if ($slots.Count -eq 0) {
        Write-Host "[List] No slots saved yet. Use: sca save <name>" -ForegroundColor "Yellow"
        return
    }

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

    Write-Host "[List] Saved slots:" -ForegroundColor "Yellow"
    foreach ($slot in $slots) {
        if ($slot.IsActive) {
            Write-Host " * $($slot.Name) (active)" -ForegroundColor "Green"
        } else {
            Write-Host "   $($slot.Name)"
        }

        # Email comes straight from the parsed filename (Get-SlotFileInfo
        # in Get-Slots). Render as an indented second line only when it
        # adds information — i.e. when the labeled form of the filename
        # carries an email distinct from the slot name. Slots named as
        # their own email, and unlabeled slots (email not yet resolved
        # at save time), both render as a single line.
        if ($slot.Email -and $slot.Email.ToLowerInvariant() -ne $slot.Name.ToLowerInvariant()) {
            Write-Host "      └─ $($slot.Email)" -ForegroundColor "DarkGray"
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
# expired or within 60s of expiry, unless -NoRefresh is passed. Returns:
#   @{ Status = 'ok';           Data = <parsed response> }
#   @{ Status = 'no-oauth' }                                # slot has no claudeAiOauth
#   @{ Status = 'expired'; Error? = <msg> }                 # token expired + refresh skipped/failed
#   @{ Status = 'unauthorized' }                            # 401/403 from usage endpoint
#   @{ Status = 'error';   Error = <msg> }                  # network / shape / other
# Never throws to callers; surfaces every failure mode as a Status value
# so Invoke-UsageAction can render mixed-health tables without aborting.
function Get-SlotUsage {
    Param (
        [String] $SlotPath,
        [switch] $NoRefresh
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
        if ($NoRefresh) {
            return [pscustomobject]@{ Status = 'expired' }
        }
        try {
            $accessToken = Update-SlotTokens -SlotPath $SlotPath
        }
        catch {
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
        return [pscustomobject]@{ Status = 'error'; Error = $_.Exception.Message }
    }
}

# Resolve the OAuth account email for a slot. Returns one of:
#   @{ Status = 'ok';           Email = <string> }
#   @{ Status = 'no-oauth' }                        # slot has no claudeAiOauth
#   @{ Status = 'expired' }                         # token expired + refresh skipped/failed
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
        [String] $SlotPath,
        [switch] $NoRefresh
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
        if ($NoRefresh) {
            return [pscustomobject]@{ Status = 'expired' }
        }
        try {
            $accessToken = Update-SlotTokens -SlotPath $SlotPath
        }
        catch {
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

# Render per-slot usage rows as a fixed-width table. Uses Write-Host (the
# information stream) to match the other Invoke-*Action functions so the
# existing `$out = Invoke-*Action 6>&1 | Out-String` test pattern keeps
# working. Fixed-width + manually padded columns (rather than Format-Table)
# so tests can assert on stable column headers without fighting PowerShell's
# responsive-width formatter. Parses the real /api/oauth/usage response
# shape: buckets at the root of data (no rate_limits wrapper), `utilization`
# field (already 0..100), `resets_at` as ISO-8601 string or null.
function Format-UsageTable {
    Param ([object[]] $Results)

    if (-not $Results) { return }

    $nameW = 4
    foreach ($r in $Results) {
        if ($r.Name.Length -gt $nameW) { $nameW = $r.Name.Length }
    }
    # Placeholders {2} and {4} receive precomputed 4-char cells from
    # Format-UtilCell so ' 34%' and '   —' align in the column.
    $fmt = "  {0} {1,-$nameW}  {2}  {3,-11}  {4}  {5,-11}  {6}"

    Write-Host "[Usage] Plan usage per slot (live from /api/oauth/usage):" -ForegroundColor "Yellow"
    Write-Host ($fmt -f ' ',  'Slot',           ' 5h ',  '5h reset',    ' 7d ',  '7d reset',    'Status')
    Write-Host ($fmt -f ' ', ('-' * $nameW),    '----',  '-----------', '----',  '-----------', '------')

    foreach ($r in $Results) {
        $marker = if ($r.IsActive) { '*' } else { ' ' }

        $fiveUsed  = '   —'; $fiveReset  = '—'
        $sevenUsed = '   —'; $sevenReset = '—'
        $hasBuckets = $false

        if ($r.Status -eq 'ok' -and $r.Data) {
            # Real schema: data.five_hour / data.seven_day at the root. Field
            # name is 'utilization', not 'used_percentage'.
            if ($r.Data.five_hour -and $null -ne $r.Data.five_hour.utilization) {
                $fiveUsed   = Format-UtilCell $r.Data.five_hour.utilization
                $fiveReset  = Format-ResetDelta $r.Data.five_hour.resets_at
                $hasBuckets = $true
            }
            if ($r.Data.seven_day -and $null -ne $r.Data.seven_day.utilization) {
                $sevenUsed  = Format-UtilCell $r.Data.seven_day.utilization
                $sevenReset = Format-ResetDelta $r.Data.seven_day.resets_at
                $hasBuckets = $true
            }
        }

        $statusText = switch ($r.Status) {
            'ok'           { if ($hasBuckets) { 'ok' } else { 'ok (no plan data)' } }
            'no-oauth'     { 'no-oauth (api key or non-claude.ai slot)' }
            'expired'      { if ($r.Error) { "expired: $($r.Error)" } else { 'expired (run sca switch to refresh)' } }
            'unauthorized' { 'unauthorized (token revoked; run sca switch then /login)' }
            'error'        {
                $msg = ($r.Error -replace "\s+", ' ').Trim()
                if ($msg.Length -gt 60) { $msg = $msg.Substring(0, 60) + '...' }
                "error: $msg"
            }
            default        { [string]$r.Status }
        }

        $color = switch ($r.Status) {
            'ok'           { if ($r.IsActive) { 'Green' } else { 'Gray' } }
            'no-oauth'     { 'DarkGray' }
            'expired'      { 'Yellow' }
            'unauthorized' { 'Red' }
            'error'        { 'Red' }
            default        { 'Gray' }
        }

        Write-Host ($fmt -f $marker, $r.Name, $fiveUsed, $fiveReset, $sevenUsed, $sevenReset, $statusText) -ForegroundColor $color

        # Second-line email annotation: only when an email was resolved
        # AND it adds information (differs from the slot name, case-
        # insensitive). Synth rows almost always get the line because
        # their Name is the literal '<active>' / '<active> (unsaved)'.
        if ($r.PSObject.Properties['Email'] -and $r.Email) {
            $slotLc  = $r.Name.ToLowerInvariant()
            $emailLc = $r.Email.ToLowerInvariant()
            if ($slotLc -ne $emailLc) {
                Write-Host ("      └─ $($r.Email)") -ForegroundColor "DarkGray"
            }
        }
    }
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
    Write-Host "[Usage] Slot '$name'$(if ($Result.IsActive) { ' (active)' })" -ForegroundColor "Yellow"

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
        Write-Host ("  {0,-22} {1}  {2}" -f $Label, $pctCell, $resetCell)
    }

    $five  = $Result.Data.five_hour
    $seven = $Result.Data.seven_day

    if (-not $five -and -not $seven) {
        Write-Host "  No plan-usage data (account may not have a subscription, or has not made a live API call yet)." -ForegroundColor "DarkGray"
        return
    }

    & $renderOne 'Session (5h)'        $five
    & $renderOne 'Weekly (all models)' $seven
}

function Invoke-UsageAction {
    Param (
        [String] $Name,
        [switch] $Json,
        [switch] $NoRefresh
    )

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
    # usage that Claude Code itself would see, and emit the same warning
    # `sca list` produces.
    $credExists    = Test-Path -LiteralPath $CredFile
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
        # Find a saved slot whose content matches .credentials.json so we
        # can steer the warning message and choose between the <active>
        # vs. <active> (unsaved) labels.
        $matchedSlotName = ($slots | Where-Object { $_.IsActive } | Select-Object -First 1 -ExpandProperty Name)
        $synthName = if ($matchedSlotName) { $Script:ActiveSlotNameMatched } else { $Script:ActiveSlotNameUnsaved }

        # A synthetic <active> row carries the `*` marker; suppress the
        # content-hash match on saved slots so the `*` appears exactly
        # once. The saved slot's row still lists in the table; just without
        # the active marker.
        foreach ($s in $slots) { $s.IsActive = $false }
    }

    if ($slots.Count -eq 0 -and -not $needSynthActive) {
        Write-Host "[Usage] No slots saved yet. Use: sca save <name>" -ForegroundColor "Yellow"
        return
    }

    # -Name filter: accept saved-slot names AND the two synth labels (they
    # contain characters Get-SafeName would reject, so we special-case
    # them before sanitizing). When a synth label is requested but
    # .credentials.json is absent or normally-linked, fall through to the
    # saved-slot match path which will throw 'not found' as usual.
    $selectedSlots     = $slots
    $includeSynthetic  = $needSynthActive
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
        $usage = Get-SlotUsage -SlotPath $slot.Path -NoRefresh:$NoRefresh
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
            Email    = $slot.Email
        }
    }

    if ($includeSynthetic) {
        $activeUsage = Get-SlotUsage -SlotPath $CredFile -NoRefresh:$NoRefresh
        # For the synth <active> row we do not have a filename-encoded
        # email (the active file is always `.credentials.json`), so we
        # keep the live profile call only for this row. At most one
        # extra HTTP call per `sca usage` invocation, and only when a
        # synth row is rendered (hardlink broken / fresh login state).
        $activeProfile = Get-SlotProfile -SlotPath $CredFile -NoRefresh:$NoRefresh
        $synthRow = [pscustomobject]@{
            Name     = $synthName
            IsActive = $true
            Status   = $activeUsage.Status
            Data     = $activeUsage.Data
            Error    = $activeUsage.Error
            Email    = if ($activeProfile.Status -eq 'ok') { $activeProfile.Email } else { $null }
        }
        # Append so the synth row appears after the saved slots in the
        # summary table, matching the `sca list` ordering convention.
        $results = @($results) + $synthRow
    }

    if ($Json) {
        # Per-slot dictionary. Each entry carries the raw response under
        # .data so scripts can pull any field Anthropic returns, including
        # buckets this script does not render in the table or verbose view.
        # The `account` block is included whenever the email was resolved;
        # currently only .email is surfaced (scope decision).
        $out = [ordered]@{}
        foreach ($r in $results) {
            $entry = [ordered]@{
                status    = $r.Status
                is_active = [bool]$r.IsActive
            }
            if ($r.Email) { $entry.account = [ordered]@{ email = $r.Email } }
            if ($r.Data)  { $entry.data    = $r.Data }
            if ($r.Error) { $entry.error   = $r.Error }
            $out[$r.Name] = $entry
        }
        $out | ConvertTo-Json -Depth 10
        return
    }

    if ($Name -and $results.Count -eq 1) {
        Format-UsageVerbose -Result $results[0]
    } else {
        Format-UsageTable -Results @($results)
    }

    # Emit the same "hardlink broken" advisory `sca list` does, but only
    # for the no-name (summary) table. The verbose single-slot view is
    # already a targeted drill-down and does not need the warning.
    if ($needSynthActive -and -not $Name) {
        if ($matchedSlotName) {
            Write-Host "[Usage] Warning: .credentials.json is not hardlinked to '$matchedSlotName' (auto-sync broken). Run 'sca switch $matchedSlotName' to repair." -ForegroundColor "Yellow"
        } else {
            Write-Host "[Usage] Warning: .credentials.json is not hardlinked to any saved slot. Run 'sca save <name>' to capture the active session, or 'sca switch <name>' to overwrite it with a saved slot." -ForegroundColor "Yellow"
        }
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
        "usage"     { Invoke-UsageAction  -Name $Name -Json:$Json -NoRefresh:$NoRefresh }
    }
}

# We are detecting dot-sourcing by checking the invocation name; the
# dispatcher only runs when the script is invoked normally, not when
# tests dot-source the file to exercise individual functions in
# isolation.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}