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
Specifies the name of the credential slot. Required for save, switch, and remove
actions. Special characters are automatically sanitized to underscores.

.EXAMPLE
# Snapshot the currently logged-in account into a slot called "work".
.\switch_claude_account.ps1 save work

.EXAMPLE
# Restore the "personal" slot as the active Claude Code account.
.\switch_claude_account.ps1 switch personal

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
        "  switch <name>    Restore a named slot as the active login",
        "  list             List saved slots (active slot marked with *)",
        "  remove <name>    Delete a named slot",
        "  install          Add 'sca' + 'switch-claude-account' aliases to your PS profile",
        "  uninstall        Remove the aliases from your PS profile",
        "  help, -h         Show this help",
        "",
        "EXAMPLES",
        "  $cmd save work           # save current login as 'work'",
        "  $cmd switch personal     # activate the 'personal' slot",
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

# We are showing the built-in help documentation if requested
# (explicit -help/-h, 'help' action, or no action at all).
if ($help -or $Action -eq "help" -or $Action -eq "") {
    Show-Help
    exit
}

# We are ensuring the credentials directory exists before
# attempting any file operations within it.
if (-not (Test-Path -Path $CredDir)) {
    New-Item -ItemType Directory -Path $CredDir -Force | Out-Null
}

switch ($Action) {
    "install" {
        Add-To-Profile
        exit
    }

    "uninstall" {
        Remove-From-Profile
        exit
    }

    "save" {
        $safeName = Get-SafeName $Name

        if (-not (Test-Path -Path $CredFile)) {
            throw "$CredFile not found. Log in via Claude Code first."
        }

        Copy-Item -Path $CredFile -Destination (Join-Path $CredDir ".credentials.$safeName.json") -Force
        Write-Host "[Save] Saved as '$safeName'" -ForegroundColor "Green"
    }

    "switch" {
        $safeName = Get-SafeName $Name
        $target   = Join-Path $CredDir ".credentials.$safeName.json"

        if (-not (Test-Path -Path $target)) {
            throw "Slot '$safeName' not found."
        }

        Copy-Item -Path $target -Destination $CredFile -Force
        Write-Host "[Switch] Switched to '$safeName'. Close and restart Claude Code to apply." -ForegroundColor "Cyan"
    }

    "list" {
        # .credentials.json itself matches the filter, so exclude it explicitly.
        $slots = Get-ChildItem -LiteralPath $CredDir -Filter ".credentials.*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne '.credentials.json' }

        if (-not $slots) {
            Write-Host "[List] No slots saved yet. Use: sca save <name>" -ForegroundColor "Yellow"
            break
        }

        # Fingerprint the active credentials file so we can mark the matching
        # slot. Get-FileHash can throw if Claude Code holds the file with a
        # restrictive share mode; degrade gracefully rather than aborting
        # the whole list.
        $activeHash = $null
        if (Test-Path -Path $CredFile) {
            try {
                $activeHash = (Get-FileHash -Path $CredFile -Algorithm SHA256).Hash
            }
            catch {
                Write-Host "[List] Could not read active credentials (file may be locked); active slot cannot be marked." -ForegroundColor "Yellow"
            }
        }

        Write-Host "[List] Saved slots:" -ForegroundColor "Yellow"
        foreach ($slot in $slots) {
            $slotName = $slot.BaseName -replace '^\.credentials\.', ''
            $isActive = $false
            if ($activeHash) {
                try {
                    $isActive = ((Get-FileHash -Path $slot.FullName -Algorithm SHA256).Hash -eq $activeHash)
                }
                catch {
                    $isActive = $false
                }
            }

            if ($isActive) {
                Write-Host " * $slotName (active)" -ForegroundColor "Green"
            } else {
                Write-Host "   $slotName"
            }
        }
    }

    "remove" {
        $safeName = Get-SafeName $Name
        $target   = Join-Path $CredDir ".credentials.$safeName.json"

        if (-not (Test-Path -Path $target)) {
            throw "Slot '$safeName' not found."
        }

        Remove-Item -Path $target -Force
        Write-Host "[Remove] Removed '$safeName'" -ForegroundColor "Red"
    }
}