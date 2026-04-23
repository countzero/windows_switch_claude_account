param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("save","switch","list","remove","install","uninstall","help")]
    [string]$Action,
    
    [Parameter(Mandatory=$false)]
    [string]$Name = ""
)

# 🔧 Core Paths
$ScriptPath  = (Resolve-Path $PSCommandPath).Path
$CredFile    = Join-Path $env:USERPROFILE ".claude\.credentials.json"
$BackupDir   = Join-Path $env:USERPROFILE ".claude-swap-backup"
$ProfilePath = $PROFILE

# 🛡️ Sanitize name for Windows filesystem safety
function Get-SafeName($inputName) {
    if ([string]::IsNullOrEmpty($inputName)) { throw "❌ Name required." }
    $clean = $inputName -replace '[\\/:*?"<>|\x00-\x1F]', '_'
    if ($clean -ne $inputName) { Write-Host "⚠️ Sanitized to: '$clean'" -ForegroundColor Yellow }
    return $clean
}

# 📦 Profile Management
$MarkerStart = "# === Claude Account Switcher ==="
$MarkerEnd   = "# === End Claude Account Switcher ==="

function Add-To-Profile {
    if (-not (Test-Path $ProfilePath)) { New-Item -ItemType File -Path $ProfilePath -Force | Out-Null }
    
    $funcDef = "function claude-acct { param([string]`$a, [string]`$n) & '$ScriptPath' `$a `$n }"
    $aliasDef = "Set-Alias -Name cs -Value claude-acct -Option AllScope"
    
    if (-not ((Get-Content $ProfilePath -Raw) -match [regex]::Escape($MarkerStart))) {
        Add-Content $ProfilePath "`r`n$MarkerStart"
        Add-Content $ProfilePath $funcDef
        Add-Content $ProfilePath $aliasDef
        Add-Content $ProfilePath "$MarkerEnd`r`n"
        Write-Host "✅ Installed! Close & reopen PowerShell, then use: cs save <name>" -ForegroundColor Green
        Write-Host "   Quick ref: cs list | cs save <name> | cs switch <name> | cs remove <name>"
    } else {
        Write-Host "⚠️ Already installed in your profile." -ForegroundColor Yellow
    }
}

function Remove-From-Profile {
    if (-not (Test-Path $ProfilePath)) { return }
    $inBlock = $false
    $lines = Get-Content $ProfilePath
    $newLines = foreach ($line in $lines) {
        if ($line -match [regex]::Escape($MarkerStart)) { $inBlock = $true; continue }
        if ($line -match [regex]::Escape($MarkerEnd))   { $inBlock = $false; continue }
        if (-not $inBlock) { $line }
    }
    Set-Content $ProfilePath ($newLines -join "`r`n") -Force
    Write-Host "🗑️ Uninstalled. Close & reopen PowerShell to remove the alias." -ForegroundColor Red
}

# 🔄 Main Logic
if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }

switch ($Action) {
    "help"      { Write-Host "Usage: cs <save|switch|list|remove|install|uninstall> [Name]"; exit }
    "install"   { Add-To-Profile; exit }
    "uninstall" { Remove-From-Profile; exit }
    
    "save" {
        $safeName = Get-SafeName $Name
        if (-not (Test-Path $CredFile)) { throw "❌ $CredFile not found. Log in via Claude Code first." }
        Copy-Item $CredFile (Join-Path $BackupDir "$safeName.json") -Force
        Write-Host "✅ Saved as '$safeName'" -ForegroundColor Green
    }
    "switch" {
        $safeName = Get-SafeName $Name
        $target = Join-Path $BackupDir "$safeName.json"
        if (-not (Test-Path $target)) { throw "❌ Slot '$safeName' not found." }
        Copy-Item $target $CredFile -Force
        Write-Host "🔄 Switched to '$safeName'. Close & restart Claude Code to apply." -ForegroundColor Cyan
    }
    "list" {
        $slots = Get-ChildItem $BackupDir -Filter "*.json" -ErrorAction SilentlyContinue
        if ($slots) {
            Write-Host "📁 Saved slots:" -ForegroundColor Yellow
            $slots | ForEach-Object { Write-Host "   • $($_.BaseName)" }
        } else {
            Write-Host "No slots saved yet. Use: cs save <name>" -ForegroundColor Yellow
        }
    }
    "remove" {
        $safeName = Get-SafeName $Name
        $target = Join-Path $BackupDir "$safeName.json"
        if (-not (Test-Path $target)) { throw "❌ Slot '$safeName' not found." }
        Remove-Item $target -Force
        Write-Host "🗑️ Removed '$safeName'" -ForegroundColor Red
    }
}