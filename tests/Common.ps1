# Per-test sandbox setup, dot-sourced from each *.Tests.ps1 file's BeforeEach.
#
# This file is intentionally NOT a function library. Wrapping the body in a
# function would break PowerShell scoping: `. $script:ScriptPath` inside a
# function dot-sources into the function's local scope, so the script's
# top-level $CredDir / $CredFile / $ProfilePath bindings — and the functions
# defined under switch_claude_account.ps1 — would not be visible to the
# enclosing It block. Dot-sourcing this snippet from a BeforeEach script
# block instead places every assignment and function into the BeforeEach's
# test scope, which is exactly what Pester 5 expects.
#
# Each test file additionally captures $env:USERPROFILE and $global:PROFILE
# in its own BeforeAll and restores them in its own AfterAll. Those captures
# must run exactly once per file, so they live there rather than here.

$script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\switch_claude_account.ps1')).Path

# Fresh sandbox per test: isolated user profile + fake PS profile path.
# $TestDrive is persistent within a Describe/Context in Pester 5, so we
# explicitly wipe the sandbox to prevent test-to-test leakage.
$script:SandboxHome = Join-Path $TestDrive 'home'
if (Test-Path -LiteralPath $script:SandboxHome) {
    Remove-Item -LiteralPath $script:SandboxHome -Recurse -Force
}
New-Item -ItemType Directory -Path $script:SandboxHome -Force | Out-Null
$env:USERPROFILE = $script:SandboxHome

$script:FakeProfilePath = Join-Path $TestDrive 'profile.ps1'
if (Test-Path -LiteralPath $script:FakeProfilePath) {
    Remove-Item -LiteralPath $script:FakeProfilePath -Force
}
$global:PROFILE = [pscustomobject]@{ CurrentUserAllHosts = $script:FakeProfilePath }

# Dot-sourcing rebinds script-scope $CredDir / $CredFile / $ProfilePath
# against the sandboxed environment. The dot-source guard stops Invoke-Main
# from running, so tests drive individual functions.
. $script:ScriptPath

# Default /api/oauth/profile mock: fails so rows have no email and the
# two-line display short-circuits. Tests that exercise email display
# override this with their own ParameterFilter mock. The filter makes
# sure we do not accidentally swallow usage/token-endpoint calls.
Mock Invoke-RestMethod -ParameterFilter {
    $Uri -eq 'https://api.anthropic.com/api/oauth/profile'
} -MockWith {
    throw [System.Exception]::new('profile endpoint unmocked in this test')
}
