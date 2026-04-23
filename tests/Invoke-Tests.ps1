#Requires -Version 7.0

# Local test runner. Auto-installs Pester 5 on first use, runs
# PSScriptAnalyzer as an advisory pass (prints findings, never fails),
# then invokes the Pester suite. Exit code follows Invoke-Pester.

$ErrorActionPreference = 'Stop'

# --- Pester 5 (auto-install if missing) ---
$pester = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $pester) {
    Write-Host 'Pester 5 not found; installing to CurrentUser scope...' -ForegroundColor Cyan
    Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
}

Import-Module Pester -MinimumVersion 5.5.0

# --- PSScriptAnalyzer (advisory: print findings, never fail) ---
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\switch_claude_account.ps1')).Path
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $findings = Invoke-ScriptAnalyzer -Path $scriptPath
    if ($findings) {
        Write-Host ''
        Write-Host 'PSScriptAnalyzer findings (advisory, non-fatal):' -ForegroundColor Yellow
        $findings | Format-Table Severity, RuleName, Line, Message -AutoSize | Out-String | Write-Host
    } else {
        Write-Host 'PSScriptAnalyzer: no findings.' -ForegroundColor Green
    }
} else {
    Write-Host 'PSScriptAnalyzer not installed; skipping (Install-Module PSScriptAnalyzer -Scope CurrentUser).' -ForegroundColor DarkGray
}

# --- Pester suite ---
Invoke-Pester -Path $PSScriptRoot -Output Detailed
