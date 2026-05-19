#Requires -Version 7.0

# Local test runner. Auto-installs Pester 5 on first use, runs
# PSScriptAnalyzer (Warning advisory, Error fatal), then invokes the
# Pester suite. By default, code coverage is collected on
# switch_claude_account.ps1 and a summary line is printed; use
# -SkipCoverage for the fastest local iteration loop. Exit code is 1
# if any test failed or coverage falls below -CoverageThreshold
# (default 90), 0 otherwise.

[CmdletBinding()]
Param (
    [switch] $SkipCoverage
)

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

# --- PSScriptAnalyzer (Warning advisory, Error fatal) ---
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\switch_claude_account.ps1')).Path
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    $settings = (Resolve-Path (Join-Path $PSScriptRoot '..\PSScriptAnalyzerSettings.psd1')).Path
    $findings = Invoke-ScriptAnalyzer -Path $scriptPath -Settings $settings
    if ($findings) {
        Write-Host ''
        Write-Host 'PSScriptAnalyzer findings:' -ForegroundColor Yellow
        $findings | Format-Table Severity, RuleName, Line, Message -AutoSize | Out-String | Write-Host
        # Error severity fails the run; Warning stays advisory. The
        # repo's PSScriptAnalyzerSettings.psd1 silences five rules
        # documented there as deliberate design choices, so the
        # remaining Warning surface is small and a new Error-level
        # finding is almost always a genuine bug.
        if ($findings | Where-Object { $_.Severity -eq 'Error' }) {
            Write-Host 'PSScriptAnalyzer: Error-severity findings present; failing run.' -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host 'PSScriptAnalyzer: no findings.' -ForegroundColor Green
    }
} else {
    Write-Host 'PSScriptAnalyzer not installed; skipping (Install-Module PSScriptAnalyzer -Scope CurrentUser).' -ForegroundColor DarkGray
}

# --- Pester suite ---
$config = New-PesterConfiguration
$config.Run.Path         = $PSScriptRoot
$config.Run.PassThru     = $true
$config.Output.Verbosity = 'Detailed'

if (-not $SkipCoverage) {
    # Ensure the output directory exists; Pester does not create it.
    # tests/TestResults/ is already gitignored.
    $coverageDir = Join-Path $PSScriptRoot 'TestResults'
    if (-not (Test-Path -LiteralPath $coverageDir)) {
        New-Item -ItemType Directory -Path $coverageDir -Force | Out-Null
    }

    $config.CodeCoverage.Enabled        = $true
    # CodeCoverage.Path accepts string[]; wrap defensively so older 5.x
    # versions don't trip on a bare string. We measure ONLY the script
    # under test, not the test files themselves.
    $config.CodeCoverage.Path           = @($scriptPath)
    # Pester 5.2+ profiler-based collector: faster than the legacy
    # breakpoint-based path and does not mutate the script during the
    # run via Set-PSBreakpoint.
    $config.CodeCoverage.UseBreakpoints = $false
    $config.CodeCoverage.OutputFormat   = 'JaCoCo'
    $config.CodeCoverage.OutputPath     = Join-Path $coverageDir 'coverage.xml'
}

$result = Invoke-Pester -Configuration $config

# --- Coverage summary (when enabled) ---
if (-not $SkipCoverage -and $result.CodeCoverage) {
    $cov = $result.CodeCoverage
    # Defensive percent computation: CommandsExecutedCount / CommandsAnalyzedCount
    # has been stable across Pester 5.0+. Direct $cov.CoveragePercent is
    # available in newer 5.x but not all releases.
    $pct = if ($cov.CommandsAnalyzedCount -gt 0) {
        100.0 * $cov.CommandsExecutedCount / $cov.CommandsAnalyzedCount
    } else {
        0.0
    }

    Write-Host ''
    # InvariantCulture so the decimal is always '.' regardless of host
    # locale; keeps the line parseable by any consumer.
    $pctText = $pct.ToString('N1', [Globalization.CultureInfo]::InvariantCulture)
    Write-Host ('Code coverage: {0}%' -f $pctText) -ForegroundColor Cyan
    Write-Host '(Gate not yet enabled.)' -ForegroundColor DarkGray
}

# --- Exit code ---
# Preserve today's binary semantics: nonzero iff any test failed.
# Coverage gate is intentionally NOT enforced in step 1.
if ($result.FailedCount -gt 0) {
    exit 1
} else {
    exit 0
}
