# PSScriptAnalyzer suppressions for switch_claude_account.ps1.
#
# - PSAvoidUsingWriteHost: Write-Host is the deliberate chokepoint for
#   Write-Color's no-color mechanism ($PSStyle.OutputRendering='PlainText'
#   only strips SGR from Write-Host) and the test capture target
#   (Invoke-*Action 6>&1). See switch_claude_account.ps1:895, :2637.
# - PSReviewUnusedParameter: false positive on script-level Param() block
#   (lines 48-127) and on the MatchEvaluator delegate signature (line 664).
# - PSUseShouldProcessForStateChangingFunctions: private internal helpers
#   guarded at the action layer (Test-ClaudeRunning) and via an explicit
#   atomic-pair invariant; ShouldProcess plumbing would cascade through
#   the test suite for no semantic gain.
# - PSUseSingularNouns: Get-Slots, Update-SlotTokens, Format-AggregateBars
#   are genuinely plural (enumerator / token-pair / two-bar render).
# - PSUseBOMForUnicodeEncodedFile: script requires PS 7.2+, which reads
#   BOM-less UTF-8 unambiguously; adding a BOM risks tooling regressions.
@{
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSReviewUnusedParameter'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
        'PSUseBOMForUnicodeEncodedFile'
    )
}
