#Requires -Version 5.0

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
.\switch_claude_account.ps1 -Action save -Name work

.EXAMPLE
.\switch_claude_account.ps1 -Action switch -Name personal

.EXAMPLE
.\switch_claude_account.ps1 -Action list

.EXAMPLE
.\switch_claude_account.ps1 -Action install
#>

Param (
    [Parameter(Mandatory = $false)]
    [String]
    $Action,

    [Parameter(Mandatory = $false)]
    [String]
    $Name = "",

    [switch]
    $help
)

if ($help -or -not $Action) {
    Get-Help -Detailed $PSCommandPath
    exit
}

# We are resolving the script path to reference this file when
# installing the alias into the user's PowerShell profile.
$ScriptPath  = (Resolve-Path $PSCommandPath).Path
$CredDir     = Join-Path $env:USERPROFILE ".claude"
$CredFile    = Join-Path $CredDir ".credentials.json"
$ProfilePath = Join-Path $env:USERPROFILE "Documents\PowerShell\profile.ps1"

# We are sanitizing names to ensure compatibility with the
# Windows filesystem by replacing invalid characters with underscores.
function Get-SafeName {
    Param ([String] $inputName)

    if ([string]::IsNullOrEmpty($inputName)) { throw "Name required." }

    $clean = $inputName -replace '[\\/:*?"<>|\x00-\x1F]', '_'

    if ($clean -ne $inputName) {
        Write-Host "Sanitized to: '$clean'" -ForegroundColor "Yellow"
    }

    return $clean
}

# We are adding the switch_claude_account_caller function and aliases
# sca (short) and switch-claude-account (long) to the user's PowerShell
# profile for convenient access.
function Add-To-Profile {
    if (-not (Test-Path -Path $ProfilePath)) {
        New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
    }

    # Remove any existing block before re-adding to ensure the
    # wrapper function is always up to date.
    Remove-From-Profile -Quiet

    $funcDef  = "function switch_claude_account_caller { & '$ScriptPath' @args }"

    $aliasShort = "Set-Alias -Name sca -Value switch_claude_account_caller -Option AllScope"
    $aliasLong  = "Set-Alias -Name switch-claude-account -Value switch_claude_account_caller -Option AllScope"

    $MarkerStart = "# === Claude Account Switcher ==="
    $MarkerEnd   = "# === End Claude Account Switcher ==="

    Add-Content $ProfilePath "`r`n$MarkerStart"
    Add-Content $ProfilePath $funcDef
    Add-Content $ProfilePath $aliasShort
    Add-Content $ProfilePath $aliasLong
    Add-Content $ProfilePath "$MarkerEnd`r`n"

    Write-Host "[Install] Installed! Close and reopen PowerShell, then use: sca save <name>" -ForegroundColor "Green"
    Write-Host "   Quick ref: sca | sca -h | sca list | sca save <name> | sca switch <name> | sca remove <name>"
}

# We are removing the switch_claude_account_caller block from the
# user's PowerShell profile by detecting the marker comments.
function Remove-From-Profile {
    param([switch]$Quiet)
    if (-not (Test-Path -Path $ProfilePath)) { return }

    $MarkerStart = "# === Claude Account Switcher ==="
    $MarkerEnd   = "# === End Claude Account Switcher ==="

    $inBlock  = $false
    $lines    = Get-Content $ProfilePath
    $newLines = foreach ($line in $lines) {
        if ($line -match [regex]::Escape($MarkerStart)) { $inBlock = $true; continue }
        if ($line -match [regex]::Escape($MarkerEnd))   { $inBlock = $false; continue }
        if (-not $inBlock) { $line }
    }

    Set-Content $ProfilePath ($newLines -join "`r`n") -Force

    if (-not $Quiet) {
        Write-Host "[Uninstall] Uninstalled. Close and reopen PowerShell to remove the alias." -ForegroundColor "Red"
    }
}

# We are showing the built-in help documentation if requested.
if ($Action -eq "help") {
    Get-Help -Detailed $PSCommandPath
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
        $slots = Get-ChildItem -Path $CredDir -Filter ".credentials.*.json" -ErrorAction SilentlyContinue

        if ($slots) {
            Write-Host "[List] Saved slots:" -ForegroundColor "Yellow"
            $slots | ForEach-Object { Write-Host "   $($_.BaseName -replace '^\.credentials\.', '')" }
        }
        else {
            Write-Host "[List] No slots saved yet. Use: sca save <name>" -ForegroundColor "Yellow"
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