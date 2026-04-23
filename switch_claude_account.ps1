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
    [ValidateSet("save", "switch", "list", "remove", "install", "uninstall", "help")]
    [String]
    $Action,

    [Parameter(Mandatory = $false)]
    [String]
    $Name = "",

    [switch]
    $help
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

# We are checking whether a profile line is one of our markers using
# trimmed, case-sensitive equality. Substring -match would misclassify a
# user comment that happens to contain the marker text.
function Test-IsMarkerLine {
    Param (
        [String] $Line,
        [String] $Marker
    )

    if ($null -eq $Line) { return $false }
    return ($Line.Trim() -ceq $Marker)
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
    $clean = $inputName -replace '[\\/:*?"<>|\x00-\x1F ]', '_'

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

# We are enumerating saved credential slots and fingerprinting each one
# against the active .credentials.json so callers (list, rotation) can
# share a single source of truth. Slots are returned sorted alphabetically
# by name for deterministic rotation order and consistent list output.
# The active hash is computed once; file-hash calls are wrapped in
# try/catch because Claude Code / VS Code may hold the file open with a
# restrictive share mode, and we prefer degraded output over aborting.
# Returns an object with:
#   Slots        : array of { Name, Path, IsActive }
#   ActiveLocked : $true if .credentials.json exists but could not be hashed
function Get-Slots {
    $files = @(
        Get-ChildItem -LiteralPath $CredDir -Filter ".credentials.*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.credentials.json' } |
            Sort-Object -Property Name
    )

    $activeHash   = $null
    $activeLocked = $false
    if (Test-Path -Path $CredFile) {
        try {
            $activeHash = (Get-FileHash -Path $CredFile -Algorithm SHA256).Hash
        }
        catch {
            $activeLocked = $true
        }
    }

    $slots = foreach ($file in $files) {
        $slotName = $file.BaseName -replace '^\.credentials\.', ''
        $isActive = $false
        if ($activeHash) {
            try {
                $isActive = ((Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash -eq $activeHash)
            }
            catch {
                $isActive = $false
            }
        }

        [pscustomobject]@{
            Name     = $slotName
            Path     = $file.FullName
            IsActive = $isActive
        }
    }

    return [pscustomobject]@{
        Slots        = @($slots)
        ActiveLocked = $activeLocked
    }
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
# user's PowerShell profile by detecting the marker comments. When only
# one of the two markers is present, we refuse to mutate the profile and
# throw so the user can inspect the damage manually. -Quiet suppresses
# only the benign "no block found" message; the orphan-marker throw is
# never silenced.
function Remove-From-Profile {
    param([switch]$Quiet)
    if (-not (Test-Path -LiteralPath $ProfilePath)) { return }

    $encoding = Get-ProfileEncoding $ProfilePath
    $lines    = @(Get-Content -LiteralPath $ProfilePath -Encoding $encoding)

    $hasStart = $false
    $hasEnd   = $false
    foreach ($line in $lines) {
        if (Test-IsMarkerLine $line $MarkerStart) { $hasStart = $true }
        if (Test-IsMarkerLine $line $MarkerEnd)   { $hasEnd   = $true }
    }

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

    $inBlock  = $false
    $newLines = foreach ($line in $lines) {
        if (Test-IsMarkerLine $line $MarkerStart) { $inBlock = $true;  continue }
        if (Test-IsMarkerLine $line $MarkerEnd)   { $inBlock = $false; continue }
        if (-not $inBlock) { $line }
    }

    # -NoNewline so Remove leaves no trailing newline of its own. Add-To-Profile
    # prepends a separator when the file is non-empty and Add-Content adds one
    # trailing newline, which keeps install -> install byte-idempotent.
    Set-Content -LiteralPath $ProfilePath -Value ($newLines -join "`r`n") -Encoding $encoding -Force -NoNewline

    if (-not $Quiet) {
        Write-Host "[Uninstall] Uninstalled. Close and reopen PowerShell to remove the alias." -ForegroundColor "Red"
    }
}

# We are extracting each action body into its own function so the logic
# is directly invokable from tests without spawning a subprocess and
# without re-parsing the $Action dispatcher. The dispatcher below becomes
# a thin switch that forwards to these functions.

function Invoke-SaveAction {
    Param ([String] $Name)

    $safeName = Get-SafeName $Name

    if (-not (Test-Path -Path $CredFile)) {
        throw "$CredFile not found. Log in via Claude Code first."
    }

    Copy-Item -Path $CredFile -Destination (Join-Path $CredDir ".credentials.$safeName.json") -Force
    Write-Host "[Save] Saved as '$safeName'" -ForegroundColor "Green"
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

    $target = Join-Path $CredDir ".credentials.$safeName.json"

    if (-not (Test-Path -Path $target)) {
        throw "Slot '$safeName' not found."
    }

    Copy-Item -Path $target -Destination $CredFile -Force
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

    Write-Host "[List] Saved slots:" -ForegroundColor "Yellow"
    foreach ($slot in $slots) {
        if ($slot.IsActive) {
            Write-Host " * $($slot.Name) (active)" -ForegroundColor "Green"
        } else {
            Write-Host "   $($slot.Name)"
        }
    }
}

function Invoke-RemoveAction {
    Param ([String] $Name)

    $safeName = Get-SafeName $Name
    $target   = Join-Path $CredDir ".credentials.$safeName.json"

    if (-not (Test-Path -Path $target)) {
        throw "Slot '$safeName' not found."
    }

    Remove-Item -Path $target -Force
    Write-Host "[Remove] Removed '$safeName'" -ForegroundColor "Red"
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
    if (-not (Test-Path -Path $CredDir)) {
        New-Item -ItemType Directory -Path $CredDir -Force | Out-Null
    }

    switch ($Action) {
        "install"   { Add-To-Profile }
        "uninstall" { Remove-From-Profile }
        "save"      { Invoke-SaveAction   -Name $Name }
        "switch"    { Invoke-SwitchAction -Name $Name }
        "list"      { Invoke-ListAction }
        "remove"    { Invoke-RemoveAction -Name $Name }
    }
}

# We are detecting dot-sourcing by checking the invocation name; the
# dispatcher only runs when the script is invoked normally, not when
# tests dot-source the file to exercise individual functions in
# isolation.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main
}