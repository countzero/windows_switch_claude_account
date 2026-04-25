#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester 5 tests for the `usage` action and its supporting helpers in
# switch_claude_account.ps1: Invoke-UsageAction, Format-ResetDelta,
# Format-ResetAbsolute, Get-SlotProfile, plus the email-rendering display
# path. Per-test sandbox setup lives in tests/Common.ps1.

BeforeAll {
    $script:OriginalUserProfile = $env:USERPROFILE
    $script:OriginalProfile     = $global:PROFILE
}

Describe 'switch_claude_account' {

    BeforeEach {
        . (Join-Path $PSScriptRoot 'Common.ps1')
    }

    Context 'Invoke-UsageAction' {
        # Pester 5 only makes functions defined in BeforeAll visible to
        # every It in the Context; function definitions inside BeforeEach
        # live only for that one BeforeEach invocation. New-Slot is a
        # fixture builder the tests share, so it lives in BeforeAll. The
        # time-dependent $script:FutureMs / $script:PastMs cannot live
        # in BeforeAll because they would capture once and drift as the
        # suite runs; they are re-computed in BeforeEach instead.
        BeforeAll {
            function New-Slot {
                Param (
                    [string] $Name,
                    [string] $AccessToken = 'sk-ant-oat-fresh',
                    [string] $RefreshToken = 'sk-ant-ort-fresh',
                    $ExpiresAt  # defaults to $script:FutureMs
                )
                if ($null -eq $ExpiresAt) { $ExpiresAt = $script:FutureMs }
                $payload = @{
                    claudeAiOauth = @{
                        accessToken      = $AccessToken
                        refreshToken     = $RefreshToken
                        expiresAt        = $ExpiresAt
                        scopes           = @('user:inference','user:profile')
                        subscriptionType = 'team'
                        rateLimitTier    = 'default_claude_max_5x'
                    }
                } | ConvertTo-Json -Depth 10 -Compress
                $path = Join-Path $script:CredDirPath ".credentials.$Name.json"
                Set-Content -LiteralPath $path -Value $payload -NoNewline -Encoding utf8NoBOM
                return $path
            }

            # Build an ISO-8601 string N time-units from now, matching the
            # shape the live /api/oauth/usage emits. In BeforeAll (not
            # BeforeEach) so every It in this Context sees the function.
            function Format-IsoReset {
                Param ([TimeSpan] $Offset)
                return [DateTimeOffset]::UtcNow.Add($Offset).ToString(
                    'o', [Globalization.CultureInfo]::InvariantCulture)
            }
        }

        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'

            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()
            $script:PastMs   = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
        }

        It 'prints no-slots message when no slots exist' {
            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'No slots saved'
        }

        It 'happy path: real /api/oauth/usage shape (buckets at root, utilization, ISO resets_at) renders table' {
            $slotPath = New-Slot -Name 'work'
            # Establish the hardlink the way Invoke-SaveAction would. Without
            # this, .credentials.json would be missing and the synth <active>
            # row would not fire — fine — but explicitly linking here
            # documents the "happy path" configuration.
            Remove-Item -LiteralPath $script:CredFilePath -Force -ErrorAction SilentlyContinue
            New-Item -ItemType HardLink -Path $script:CredFilePath -Target $slotPath | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{
                        utilization = 31.0
                        resets_at   = (Format-IsoReset ([TimeSpan]::FromMinutes(134)))  # ~2h 14m
                    }
                    seven_day = [pscustomobject]@{
                        utilization = 17.0
                        resets_at   = (Format-IsoReset ([TimeSpan]::FromHours(42)))     # ~1d 18h -> "in 42h"
                    }
                    seven_day_sonnet = [pscustomobject]@{
                        utilization = 0.0
                        resets_at   = $null
                    }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match 'work'
            # Integer percent, right-justified into 4-char cell.
            $out | Should -Match '\b31%'
            $out | Should -Match '\b17%'
            # Variant C: hours+minutes under 24h; elapsed test time may shave
            # a minute off, so accept 13-14m.
            $out | Should -Match 'in 2h 1[34]m'
            # Variant C: integer total hours at/above 24h; elapsed test time
            # may drop 42h to 41h.
            $out | Should -Match 'in 4[12]h(?!\d)'
            # 'ok' status (buckets were present, so not "no plan data").
            $out | Should -Match '(?m)\s+ok\s*$'
            # Unofficial-endpoint footer must not leak into output.
            $out | Should -Not -Match 'unofficial endpoint'
            # Hardlinked active credentials: no synth row, no warning.
            $out | Should -Not -Match '<active>'
            $out | Should -Not -Match 'not hardlinked'
            # And no row other than 'work' (one saved slot → exactly one data row).
            ($out -split "`n" | Where-Object { $_ -match '(?:^|\s)(work|<active>)\b' }).Count | Should -Be 1
        }

        It 'true empty response ({}) renders "ok (no plan data)"' {
            New-Slot -Name 'free' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{}
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'free'
            $out | Should -Match 'ok \(no plan data\)'
        }

        It 'null resets_at paired with 0% renders just the percent (merged cell)' {
            New-Slot -Name 'cold' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 0.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 9.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(103))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # 0% five_hour with null reset: cell is just ' 0%' (no 'in ...'
            # suffix). With columns merged, the em-dash reset sentinel is
            # no longer emitted when utilization is known; a cold bucket
            # is naturally represented by its raw percent without a tail.
            $out | Should -Match '\b0%'
            # The 5h cell has no 'in ' tail; the 7d cell does (103h).
            $out | Should -Not -Match '0%\s+in\s'
            $out | Should -Match '9%\s+in 10[23]h'
        }

        It '401 response: status is unauthorized' {
            New-Slot -Name 'revoked' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 401 }
                $inner = [System.Exception]::new('Unauthorized')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'unauthorized'
        }

        It 'network timeout: status is error; overall call still returns 0-exit' {
            New-Slot -Name 'offline' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Net.WebException]::new('The operation has timed out.')
            }

            { Invoke-UsageAction 6>$null } | Should -Not -Throw
            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'error:'
            $out | Should -Match 'timed out'
        }

        It 'slot with no claudeAiOauth section: status is no-oauth; no HTTP call made' {
            $path = Join-Path $script:CredDirPath '.credentials.apikey.json'
            Set-Content -LiteralPath $path -Value '{"apiKey":"sk-ant-api..."}' -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -MockWith { throw 'should not be called' }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match 'apikey'
            $out | Should -Match 'no-oauth'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        }

        It 'expired token: refresh succeeds, slot file rewritten in place, usage retrieved' {
            $slotPath = New-Slot -Name 'stale' -AccessToken 'sk-ant-oat-OLD' -ExpiresAt $script:PastMs

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                if ($Headers['Authorization'] -ne 'Bearer sk-ant-oat-NEW') {
                    throw "refresh did not propagate to usage call: got '$($Headers['Authorization'])'"
                }
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(3))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $after = Get-Content -LiteralPath $slotPath -Raw | ConvertFrom-Json
            $after.claudeAiOauth.accessToken  | Should -Be 'sk-ant-oat-NEW'
            $after.claudeAiOauth.refreshToken | Should -Be 'sk-ant-ort-NEW'
            [DateTimeOffset]::FromUnixTimeMilliseconds($after.claudeAiOauth.expiresAt).UtcDateTime |
                Should -BeGreaterThan ([DateTime]::UtcNow)
            $out | Should -Match '\b5%'

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'expired token + refresh fails (400): status is expired; slot unchanged' {
            $slotPath = New-Slot -Name 'stale' -ExpiresAt $script:PastMs
            $before   = [System.IO.File]::ReadAllBytes($slotPath)

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                throw [System.Exception]::new('refresh_token invalid')
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw 'should not be called if refresh failed'
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match 'expired'
            $after = [System.IO.File]::ReadAllBytes($slotPath)
            $after.Length | Should -Be $before.Length
            for ($i = 0; $i -lt $before.Length; $i++) { $after[$i] | Should -Be $before[$i] }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        # --- refresh-endpoint 429 handling ---
        #
        # Regression for the bug originally reported via screenshot: a 429
        # from /v1/oauth/token surfaced as `expired: Response status code
        # does not indicate success: 429 (Too Many Requests).` — long
        # enough to wrap the table row, and mislabeled relative to the
        # 'rate-limited' handling that already existed for the usage
        # endpoint. After the fix the same 429 routes through Test-Is429
        # and renders cleanly, with cache fallback when available.

        It 'refresh 429 with no cache: status is rate-limited (not expired); no long error tail' {
            $slotPath = New-Slot -Name 'slot-1' -ExpiresAt $script:PastMs
            $before   = [System.IO.File]::ReadAllBytes($slotPath)

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('Response status code does not indicate success: 429 (Too Many Requests).')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw 'should not be called when refresh 429s'
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Status renders as the short 'rate-limited' label, never as
            # the long 'expired: …429 (Too Many Requests)' string.
            $out | Should -Match 'rate-limited'
            $out | Should -Not -Match 'Too Many Requests'
            # The slot name's own data row carries 'rate-limited', not 'expired'.
            $out | Should -Match '(?m)^\s+slot-1\b.*\brate-limited\s*$'
            $out | Should -Not -Match '(?m)^\s+slot-1\b.*\bexpired\b'

            # Slot file untouched (refresh failed, nothing to write).
            $after = [System.IO.File]::ReadAllBytes($slotPath)
            $after.Length | Should -Be $before.Length
            for ($i = 0; $i -lt $before.Length; $i++) { $after[$i] | Should -Be $before[$i] }

            # Usage endpoint was never called — refresh failure short-circuits.
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'refresh 429 with fresh cache: serves cached usage data + emits cache-fallback advisory' {
            $slotPath = New-Slot -Name 'slot-1' -ExpiresAt $script:PastMs

            # Pre-populate the in-memory cache with a recent successful
            # response. `$Script:SlotUsageCache` is reinitialized to @{}
            # in each BeforeEach (Common.ps1 dot-sources the script),
            # so we start from a clean slate here.
            $cachedReset = (Format-IsoReset ([TimeSpan]::FromHours(2)))
            $Script:SlotUsageCache[$slotPath] = @{
                Data      = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 42.0; resets_at = $cachedReset }
                    seven_day = [pscustomobject]@{ utilization = 73.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(50))) }
                }
                Timestamp = [DateTime]::UtcNow
            }

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('429 Too Many Requests')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw 'should not be called when refresh 429s'
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Cached values render via the regular 'ok' Status path.
            $out | Should -Match '\b42%'
            $out | Should -Match '\b73%'
            # New endpoint-agnostic advisory text fires for the cache fallback.
            $out | Should -Match 'Anthropic API rate limited.+displaying cached data'
            # Old advisory wording must not leak through.
            $out | Should -Not -Match '/api/oauth/usage rate limited'
        }

        It 'refresh failure with non-429 long message: expired tail is truncated' {
            New-Slot -Name 'slot-long' -ExpiresAt $script:PastMs | Out-Null

            $longMessage = 'X' * 200
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                throw [System.Exception]::new($longMessage)
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Still classified as 'expired' (no Response.StatusCode = 429).
            $out | Should -Match '(?m)^\s+slot-long\b.*\bexpired:'
            # Truncation marker present (the helper appends '...').
            $out | Should -Match 'expired: X+\.\.\.'
            # The full 200-char tail must NOT appear verbatim — defense-in-depth
            # against the original wrapping bug for non-429 long messages.
            $out | Should -Not -Match ('X' * 100)
        }

        It '-json emits is_cached_fallback when cache served the row' {
            $slotPath = New-Slot -Name 'slot-1' -ExpiresAt $script:PastMs

            $Script:SlotUsageCache[$slotPath] = @{
                Data      = [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 1.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                }
                Timestamp = [DateTime]::UtcNow
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 429 }
                $inner = [System.Exception]::new('429')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            $parsed = Invoke-UsageAction -json | ConvertFrom-Json
            $parsed.'slot-1'.status              | Should -Be 'ok'
            $parsed.'slot-1'.is_cached_fallback  | Should -Be $true
            $parsed.'slot-1'.data.five_hour.utilization | Should -Be 1
        }

        It '-json omits is_cached_fallback for fresh live responses' {
            New-Slot -Name 'fresh' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                }
            }

            $parsed = Invoke-UsageAction -json | ConvertFrom-Json
            $parsed.fresh.status | Should -Be 'ok'
            # Property either absent or explicitly false — never true.
            $hasField = ($parsed.fresh | Get-Member -Name 'is_cached_fallback' -MemberType NoteProperty)
            if ($hasField) { $parsed.fresh.is_cached_fallback | Should -Not -Be $true }
        }

        It '-json emits a per-slot dictionary that round-trips via ConvertFrom-Json' {
            New-Slot -Name 'alpha' | Out-Null
            New-Slot -Name 'bravo' -AccessToken 'sk-ant-oat-bravo' -RefreshToken 'sk-ant-ort-bravo' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*fresh*' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 10.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*bravo*' } -MockWith {
                throw [System.Exception]::new('network down')
            }

            $raw    = Invoke-UsageAction -json
            $parsed = $raw | ConvertFrom-Json

            ($parsed | Get-Member -MemberType NoteProperty | ForEach-Object Name) | Sort-Object |
                Should -Be @('alpha','bravo')
            $parsed.alpha.status | Should -Be 'ok'
            # Real schema: utilization at data.five_hour (no rate_limits wrapper).
            $parsed.alpha.data.five_hour.utilization | Should -Be 10
            $parsed.bravo.status | Should -Be 'error'
            $parsed.bravo.error  | Should -Match 'network down'
        }

        # --- plan-usability status (100% = limited, >=90% = near limit) ---

        # The Status column mixes HTTP-health (expired / unauthorized /
        # error / no-oauth) with plan-usability derived from the
        # utilization fields. A slot at 100% of its 5h window is rate-
        # limited and cannot serve prompts until the window resets;
        # rendering that as 'ok' would mislead the user (the bug these
        # tests guard against).
        It 'plan status is "limited 5h" when five_hour utilization is at 100%' {
            New-Slot -Name 'capped' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 28.0;  resets_at = (Format-IsoReset ([TimeSpan]::FromHours(34))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match 'capped'
            $out | Should -Match '100%'
            # Status column reflects plan state, not HTTP state.
            $out | Should -Match '(?m)\blimited 5h\s*$'
            # And should NOT read as 'ok' anywhere on the data row.
            $out | Should -Not -Match '(?m)^\s+capped\b.*\bok\s*$'
        }

        It 'plan status is "limited 7d" when seven_day utilization is at 100%' {
            New-Slot -Name 'weeklycap' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 12.0;  resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 101.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(12))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match '(?m)\blimited 7d\s*$'
        }

        It 'plan status is "limited" when both buckets are at or above 100%' {
            New-Slot -Name 'double' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                    seven_day = [pscustomobject]@{ utilization = 100.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(10))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            # Exact word boundary so 'limited' does not also match 'limited 5h'.
            $out | Should -Match '(?m)\blimited\s*$'
            $out | Should -Not -Match 'limited 5h'
            $out | Should -Not -Match 'limited 7d'
        }

        It 'plan status is "near limit" when any bucket is at or above the warn threshold but under 100%' {
            New-Slot -Name 'warnrow' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 92.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                    seven_day = [pscustomobject]@{ utilization = 11.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(50))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            $out | Should -Match 'near limit'
            $out | Should -Not -Match 'limited'
        }

        It 'plan status is plain "ok" when both buckets are below the warn threshold' {
            New-Slot -Name 'healthy' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 89.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                    seven_day = [pscustomobject]@{ utilization =  3.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(70))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String
            # 89 < 90 warn threshold -> still 'ok'. Word-anchored so 'ok'
            # is not confused with 'ok (no plan data)'.
            $out | Should -Match '(?m)\bok\s*$'
            $out | Should -Not -Match 'near limit'
            $out | Should -Not -Match 'limited'
        }

        It '-json emits plan_status alongside status for HTTP-ok rows' {
            New-Slot -Name 'capped' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 28.0;  resets_at = (Format-IsoReset ([TimeSpan]::FromHours(34))) }
                }
            }

            $raw    = Invoke-UsageAction -json
            $parsed = $raw | ConvertFrom-Json

            $parsed.capped.status      | Should -Be 'ok'
            $parsed.capped.plan_status | Should -Be 'limited 5h'
        }

        It '-json omits plan_status for HTTP-failure rows' {
            New-Slot -Name 'dead' | Out-Null
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                throw [System.Exception]::new('network down')
            }

            $raw    = Invoke-UsageAction -json
            $parsed = $raw | ConvertFrom-Json

            $parsed.dead.status      | Should -Be 'error'
            # plan_status is only attached for status='ok' rows so scripts
            # don't have to disambiguate between "HTTP ok + near limit"
            # and "HTTP failed". When absent, the NoteProperty is missing.
            $parsed.dead.PSObject.Properties.Name | Should -Not -Contain 'plan_status'
        }

        It 'verbose view inserts a Status line between Account and the bucket rows for a limited slot' {
            New-Slot -Name 'alpha' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 100.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 28.0;  resets_at = (Format-IsoReset ([TimeSpan]::FromHours(34))) }
                }
            }

            $out = Invoke-UsageAction -Name 'alpha' 6>&1 | Out-String

            # Status line uses the same label as the summary table plus a
            # short English rationale so the verbose screen can stand
            # alone.
            $out | Should -Match '(?m)^\s+Status:\s+limited 5h - no prompts until 5h window resets'

            # Bucket rows still render below the Status line. Renamed
            # from 'Session (5h)' / 'Weekly (all models)' to 'Session' /
            # 'Week' to match the table column headers and the
            # aggregate-bar labels above the table.
            $out | Should -Match 'Session\s+100%\s+Resets '
            $out | Should -Match 'Week\s+28%\s+Resets '
        }

        It 'refresh preserves any hardlink to .credentials.json (active-slot refresh)' {
            $slotPath = New-Slot -Name 'activeStale' -AccessToken 'sk-ant-oat-OLD' -ExpiresAt $script:PastMs

            Remove-Item -LiteralPath $script:CredFilePath -Force -ErrorAction SilentlyContinue
            New-Item -ItemType HardLink -Path $script:CredFilePath -Target $slotPath | Out-Null
            (Get-Item -LiteralPath $script:CredFilePath).LinkType | Should -Be 'HardLink'

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{}
            }

            Invoke-UsageAction 6>$null

            (Get-Item -LiteralPath $script:CredFilePath).LinkType | Should -Be 'HardLink'
            (Get-Item -LiteralPath $slotPath).LinkType            | Should -Be 'HardLink'

            $credJson = Get-Content -LiteralPath $script:CredFilePath -Raw | ConvertFrom-Json
            $credJson.claudeAiOauth.accessToken | Should -Be 'sk-ant-oat-NEW'
        }

        It 'named-slot usage: verbose view shows only Session and Week buckets' {
            New-Slot -Name 'alpha' | Out-Null
            New-Slot -Name 'bravo' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    # Buckets we render:
                    five_hour        = [pscustomobject]@{ utilization = 25.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                    seven_day        = [pscustomobject]@{ utilization = 17.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(48))) }
                    # Buckets we MUST NOT render (scope decision: limits only = session + weekly):
                    seven_day_opus   = [pscustomobject]@{ utilization = 8.0;  resets_at = (Format-IsoReset ([TimeSpan]::FromDays(6))) }
                    seven_day_sonnet = [pscustomobject]@{ utilization = 0.0;  resets_at = $null }
                    extra_usage      = [pscustomobject]@{ is_enabled = $false; monthly_limit = $null; used_credits = $null; utilization = $null; currency = $null }
                }
            }

            $out = Invoke-UsageAction -Name 'alpha' 6>&1 | Out-String

            # Targeted slot only.
            $out | Should -Match "Slot 'alpha'"
            $out | Should -Not -Match "Slot 'bravo'"

            # The two rendered buckets — labels match the table column
            # headers and the aggregate-bar labels.
            $out | Should -Match '(?m)^\s+Session\s+\d'
            $out | Should -Match '(?m)^\s+Week\s+\d'
            $out | Should -Match 'Resets '

            # Explicitly absent: labels for buckets we deliberately stopped
            # rendering. Protects against accidental regression if a future
            # refactor reintroduces a generic bucket loop.
            $out | Should -Not -Match 'Weekly \(Opus only\)'
            $out | Should -Not -Match 'Weekly \(Sonnet only\)'
            $out | Should -Not -Match 'Extra usage'
            # Raw API keys also absent (we use labels, not keys).
            $out | Should -Not -Match '(?m)^\s+five_hour\b'
            $out | Should -Not -Match '(?m)^\s+seven_day\b'

            # Unofficial-endpoint footer removed.
            $out | Should -Not -Match 'unofficial endpoint'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'named-slot usage throws on missing slot' {
            New-Slot -Name 'alpha' | Out-Null
            { Invoke-UsageAction -Name 'missing' 6>$null } | Should -Throw -ExpectedMessage "*Slot 'missing' not found*"
        }

        # --- synth <active> row + hardlink warning ---

        # Claude Code replaces .credentials.json via atomic rename during an
        # OAuth refresh; that breaks the hardlink chain the switcher sets up.
        # The `usage` action detects this state and renders a synthetic
        # <active> row for whatever .credentials.json currently points at,
        # so users can see the account Claude Code is actually using even
        # when no saved slot matches it. Paired with a list-style warning.
        It 'synth <active> (unsaved) row appears when .credentials.json matches no saved slot' {
            # Two saved slots with one set of tokens + a completely
            # different .credentials.json with a third token. Content hash
            # of the active file matches neither slot.
            New-Slot -Name 'work' -AccessToken 'sk-ant-oat-work' | Out-Null
            New-Slot -Name 'home' -AccessToken 'sk-ant-oat-home' | Out-Null
            $activePayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-ACTIVE-UNKNOWN'
                    refreshToken     = 'sk-ant-ort-ACTIVE-UNKNOWN'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                    rateLimitTier    = 'default_claude_max_5x'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $activePayload -NoNewline -Encoding utf8NoBOM

            # Return three different responses keyed by the Authorization
            # header so we can detect whether the synth row used the
            # active-file token (it must) rather than a saved slot's token.
            Mock Invoke-RestMethod -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*ACTIVE-UNKNOWN*'
            } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 53.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 19.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(40))) }
                }
            }
            Mock Invoke-RestMethod -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -notlike '*ACTIVE-UNKNOWN*'
            } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(3))) }
                    seven_day = [pscustomobject]@{ utilization = 7.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(120))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Saved slots still render (both rows), without the `*` marker
            # (content hash does not match .credentials.json, so their
            # natural IsActive is already false; nothing suppressed).
            $out | Should -Match '(?m)^\s+work\s'
            $out | Should -Match '(?m)^\s+home\s'

            # Synth row is present, marked active, with the (unsaved) suffix
            # because .credentials.json content doesn't hash-match any slot.
            $out | Should -Match '(?m)^\s+\*\s+<active> \(unsaved\)\s'
            # Its usage numbers come from the active-file token (53/19),
            # not the saved-slot tokens (5/7).
            $out | Should -Match '<active> \(unsaved\).*\b53%'
            $out | Should -Match '<active> \(unsaved\).*\b19%'

            # Hardlink-broken warning on the unsaved path.
            $out | Should -Match 'Warning: .credentials.json is not hardlinked'
            $out | Should -Match "sca save <name>"

            # Three endpoint calls: one per saved slot, one for .credentials.json.
            Should -Invoke Invoke-RestMethod -Times 3 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'synth <active> row (no suffix) appears when .credentials.json is a copy of a saved slot' {
            # Same tokens in the active file as in 'work'; both hash-match
            # but the active file is a regular file, not a hardlink.
            $slotPath = New-Slot -Name 'work' -AccessToken 'sk-ant-oat-WORK-TOKEN'
            $workJson = Get-Content -LiteralPath $slotPath -Raw
            Set-Content -LiteralPath $script:CredFilePath -Value $workJson -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 10.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                    seven_day = [pscustomobject]@{ utilization = 12.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(72))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Synth row uses the no-suffix label because content matches
            # an existing saved slot.
            $out | Should -Match '(?m)^\s+\*\s+<active>\s'
            # The saved-slot row for 'work' is still present but does NOT
            # carry the `*` marker — `*` is on the synth row only.
            $out | Should -Match '(?m)^\s+work\s'
            $out | Should -Not -Match '(?m)^\s+\*\s+work\s'

            # Warning points at the matched slot and suggests sca switch.
            $out | Should -Match "Warning: .credentials.json is not hardlinked to 'work'"
            $out | Should -Match "sca switch work"
        }

        It 'no synth row and no warning when .credentials.json is a hardlink to a saved slot' {
            $slotPath = New-Slot -Name 'work'
            Remove-Item -LiteralPath $script:CredFilePath -Force -ErrorAction SilentlyContinue
            New-Item -ItemType HardLink -Path $script:CredFilePath -Target $slotPath | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 0.0; resets_at = $null }
                    seven_day = [pscustomobject]@{ utilization = 0.0; resets_at = $null }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Not -Match '<active>'
            $out | Should -Not -Match 'Warning: .credentials.json'
            # Exactly one endpoint call: for the saved slot (the synth-row
            # extra call must NOT happen on the hardlinked path).
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' }
        }

        It 'synth row renders even when there are no saved slots at all' {
            # Fresh install edge case: .credentials.json exists (user ran
            # `claude /login` once) but nothing has been `sca save`'d yet.
            $activePayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-loner'
                    refreshToken     = 'sk-ant-ort-loner'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'pro'
                    rateLimitTier    = $null
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $activePayload -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 2.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(4))) }
                    seven_day = [pscustomobject]@{ utilization = 1.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(150))) }
                }
            }

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Must NOT print the zero-slots early-return message.
            $out | Should -Not -Match 'No slots saved yet'
            # Synth row present with (unsaved) suffix.
            $out | Should -Match '<active> \(unsaved\)'
            $out | Should -Match '\b2%'
            $out | Should -Match 'Warning: .credentials.json is not hardlinked'
        }

        It '`sca usage <active>` drills into the synth row verbose view' {
            # Set up the unsaved-active state.
            $activePayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-ACTIVE'
                    refreshToken     = 'sk-ant-ort-ACTIVE'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                    rateLimitTier    = 'default_claude_max_5x'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $activePayload -NoNewline -Encoding utf8NoBOM
            New-Slot -Name 'other' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*ACTIVE*'
            } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 53.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 19.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(40))) }
                }
            }
            Mock Invoke-RestMethod -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -notlike '*ACTIVE*'
            } -MockWith {
                throw 'saved-slot token should not be queried when drilling into synth row'
            }

            $out = Invoke-UsageAction -Name '<active> (unsaved)' 6>&1 | Out-String

            # Verbose view header carries the synth name.
            $out | Should -Match "Slot '<active> \(unsaved\)'"
            # Two-bucket render only.
            $out | Should -Match 'Session\s+53%\s+Resets '
            $out | Should -Match 'Week\s+19%\s+Resets '
            # Drill-down must not emit the warning (only the summary table does).
            $out | Should -Not -Match 'Warning: .credentials.json'

            # Only the active-file token was queried.
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -eq 'https://api.anthropic.com/api/oauth/usage' -and $Headers['Authorization'] -like '*ACTIVE*'
            }
        }

        It '`sca usage <active>` also accepts the bare <active> alias' {
            $activePayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-ACTIVE2'
                    refreshToken     = 'sk-ant-ort-ACTIVE2'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $activePayload -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 40.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(2))) }
                    seven_day = [pscustomobject]@{ utilization = 60.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(72))) }
                }
            }

            $out = Invoke-UsageAction -Name '<active>' 6>&1 | Out-String

            $out | Should -Match "Slot '<active> \(unsaved\)'"
            $out | Should -Match '\b40%'
            $out | Should -Match '\b60%'
        }

        It '`sca usage <active>` throws when there is nothing to synthesize' {
            # No .credentials.json -> nothing to synthesize. Must refuse.
            New-Slot -Name 'alpha' | Out-Null
            { Invoke-UsageAction -Name '<active>' 6>$null } |
                Should -Throw -ExpectedMessage '*No synthetic active slot*'
        }

        It '-json includes the synth row under its label key' {
            $activePayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-ACTIVE3'
                    refreshToken     = 'sk-ant-ort-ACTIVE3'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $activePayload -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 1.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(3))) }
                    seven_day = [pscustomobject]@{ utilization = 2.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(50))) }
                }
            }

            $raw    = Invoke-UsageAction -json
            $parsed = $raw | ConvertFrom-Json

            # ConvertFrom-Json exposes ordered-dictionary keys as
            # NoteProperty names on the root object. The synth row's key is
            # the literal label string.
            $parsed.PSObject.Properties.Name | Should -Contain '<active> (unsaved)'
            $active = $parsed.'<active> (unsaved)'
            $active.status                        | Should -Be 'ok'
            $active.is_active                     | Should -Be $true
            $active.data.five_hour.utilization    | Should -Be 1
            $active.data.seven_day.utilization    | Should -Be 2
        }

        # --- Get-UsageSnapshot / Format-UsageFrame / -watch guards ---
        #
        # The watch loop itself (sleeps + key reads) is not unit-tested;
        # instead we exercise the three seams it is built on:
        #   1. Get-UsageSnapshot returns the data shape the loop consumes.
        #   2. Format-UsageFrame renders a frame + optional footer.
        #   3. Invoke-UsageAction -watch refuses bad surfaces (redirected
        #      output, combined with -json).

        It 'Get-UsageSnapshot returns Results + HardlinkBroken + NoSlots flags' {
            New-Slot -Name 'alpha' | Out-Null

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 7.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                }
            }

            $snap = Get-UsageSnapshot
            $snap                    | Should -Not -BeNullOrEmpty
            $snap.NoSlots            | Should -Be $false
            $snap.HardlinkBroken     | Should -Be $false
            $snap.HasSynthRow        | Should -Be $false
            @($snap.Results).Count   | Should -Be 1
            @($snap.Results)[0].Name | Should -Be 'alpha'
        }

        It 'Get-UsageSnapshot reports NoSlots when the directory is empty' {
            $snap = Get-UsageSnapshot
            $snap.NoSlots          | Should -Be $true
            @($snap.Results).Count | Should -Be 0
        }

        It 'Get-UsageSnapshot reports HardlinkBroken + synth row when .credentials.json is a regular file' {
            # Unknown tokens in the active file -> synth row, hardlink broken,
            # no matched slot.
            $activePayload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-ACTIVE-NOVEL'
                    refreshToken     = 'sk-ant-ort-ACTIVE-NOVEL'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath $script:CredFilePath -Value $activePayload -NoNewline -Encoding utf8NoBOM

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 4.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) }
                }
            }

            $snap = Get-UsageSnapshot
            $snap.HardlinkBroken   | Should -Be $true
            $snap.HasSynthRow      | Should -Be $true
            $snap.MatchedSlotName  | Should -BeNullOrEmpty
            @($snap.Results).Count | Should -Be 1
            @($snap.Results)[0].Name | Should -Be '<active> (unsaved)'
        }

        It 'Format-UsageFrame prints the footer under the table when -Footer is provided' {
            $snap = [pscustomobject]@{
                Results = @([pscustomobject]@{ Name = 'alpha'; IsActive = $false; Status = 'ok';
                    Data = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 1.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) } }
                    Error = $null; Email = $null })
                HardlinkBroken  = $false
                MatchedSlotName = $null
                NoSlots         = $false
                HasSynthRow     = $false
            }

            $out = Format-UsageFrame -Snapshot $snap -Footer 'HELLO-FROM-FOOTER' 6>&1 | Out-String

            $out | Should -Match 'alpha'
            $out | Should -Match 'HELLO-FROM-FOOTER'
            # Footer sits after the data row.
            ($out.IndexOf('alpha')) | Should -BeLessThan ($out.IndexOf('HELLO-FROM-FOOTER'))
        }

        It 'Format-UsageFrame -SuppressAdvisory hides the hardlink-broken warning' {
            $snap = [pscustomobject]@{
                Results         = @([pscustomobject]@{ Name = '<active> (unsaved)'; IsActive = $true; Status = 'ok';
                    Data = [pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 5.0; resets_at = (Format-IsoReset ([TimeSpan]::FromHours(1))) } }
                    Error = $null; Email = $null })
                HardlinkBroken  = $true
                MatchedSlotName = $null
                NoSlots         = $false
                HasSynthRow     = $true
            }

            $suppressed = Format-UsageFrame -Snapshot $snap -SuppressAdvisory 6>&1 | Out-String
            $shown      = Format-UsageFrame -Snapshot $snap                    6>&1 | Out-String

            $suppressed | Should -Not -Match 'Warning: .credentials.json'
            $shown      | Should -Match     'Warning: .credentials.json'
        }

        It 'Invoke-UsageAction -watch -json throws (mutually exclusive)' {
            { Invoke-UsageAction -watch -json 6>$null } |
                Should -Throw -ExpectedMessage '*-watch and -json cannot be combined*'
        }

        It 'Invoke-UsageAction -watch throws when stdout is redirected (interactive guard)' {
            # Pester cannot truly redirect the outer console, but we can
            # fake [Console]::IsOutputRedirected by defining a local
            # override. Use the script's defensive: we expect the check
            # to run before any loop / HTTP, so the throw should be
            # deterministic. To simulate, we temporarily alias Console's
            # static property via a wrapper: not feasible without PSCustom
            # refactor, so instead we assert the *loop itself does not run*
            # by setting -interval high and confirming the guard fires
            # before any HTTP call. The cleanest check is to rely on the
            # happy-path assertion elsewhere and skip the redirected test
            # when [Console]::IsOutputRedirected is false (the Pester
            # subprocess runs with stdout redirected, so IsOutputRedirected
            # returns $true and the guard fires naturally).
            if (-not [Console]::IsOutputRedirected) {
                Set-ItResult -Skipped -Because 'Console stdout is not redirected in this host; guard cannot be exercised here.'
                return
            }
            { Invoke-UsageAction -watch 6>$null } |
                Should -Throw -ExpectedMessage '*-watch requires an interactive terminal*'
        }
    }

    Context 'Test-Is429' {
        It 'returns true for the test-mock pscustomobject Response shim' {
            $ex = [System.Exception]::new('429 Too Many Requests')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 429 })
            Test-Is429 $ex | Should -BeTrue
        }

        It 'returns true for the real System.Net.HttpStatusCode enum value' {
            # PS7's Invoke-RestMethod surfaces 429 via HttpResponseException
            # whose Response.StatusCode is an [HttpStatusCode] enum. Casting
            # that enum to [int] yields 429 — Test-Is429 must accept it.
            $ex = [System.Exception]::new('rate limited')
            $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = [System.Net.HttpStatusCode]::TooManyRequests })
            Test-Is429 $ex | Should -BeTrue
        }

        It 'returns false for non-429 status codes' {
            foreach ($code in 400, 401, 403, 500, 503) {
                $ex = [System.Exception]::new("status $code")
                $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $code })
                Test-Is429 $ex | Should -BeFalse -Because "code $code is not 429"
            }
        }

        It 'returns false when the exception has no Response member (network errors)' {
            $ex = [System.Net.WebException]::new('The operation has timed out.')
            Test-Is429 $ex | Should -BeFalse
        }

        It 'returns false for null / empty inputs' {
            Test-Is429 $null | Should -BeFalse
            $ex = [System.Exception]::new('plain exception')
            Test-Is429 $ex | Should -BeFalse
        }
    }

    Context 'Format-StatusErrorTail' {
        It 'collapses internal whitespace runs into a single space' {
            Format-StatusErrorTail "line1`r`nline2`tline3" | Should -Be 'line1 line2 line3'
        }

        It 'trims leading and trailing whitespace' {
            Format-StatusErrorTail "   hello world   " | Should -Be 'hello world'
        }

        It 'truncates messages longer than the cap and appends ellipsis dots' {
            $long = 'A' * 100
            $out  = Format-StatusErrorTail -Message $long -Max 60
            $out.Length    | Should -Be 63          # 60 + '...'
            $out           | Should -Match '\.\.\.$'
            $out.Substring(0, 60) | Should -Be ('A' * 60)
        }

        It 'returns the trimmed message untouched when it fits within the cap' {
            $msg = 'short message'
            Format-StatusErrorTail -Message $msg -Max 60 | Should -Be $msg
        }

        It 'returns empty string for null / empty input (no exception)' {
            Format-StatusErrorTail $null | Should -Be ''
            Format-StatusErrorTail ''    | Should -Be ''
        }
    }

    Context 'Format-AggregateBars' {
        # Builds a per-slot result row matching the shape Get-UsageSnapshot
        # emits. Keeping it here (not in the outer Invoke-UsageAction
        # BeforeAll) avoids visibility surprises if either Context is
        # later moved or split into a separate file.
        BeforeAll {
            function New-OkRow {
                Param (
                    [string] $Name,
                    [bool]   $IsActive = $false,
                    $FiveUtil  = 'unset',
                    $SevenUtil = 'unset'
                )
                # Sentinel 'unset' distinguishes "bucket missing entirely"
                # (-> $null Data.<bucket>) from "bucket present, util=null"
                # (-> object with utilization=$null). Format-AggregateBars
                # treats both as 0% used; we exercise the missing-bucket
                # path here.
                $five  = $null
                $seven = $null
                if ($FiveUtil  -ne 'unset') { $five  = [pscustomobject]@{ utilization = [double]$FiveUtil;  resets_at = $null } }
                if ($SevenUtil -ne 'unset') { $seven = [pscustomobject]@{ utilization = [double]$SevenUtil; resets_at = $null } }
                $data = [pscustomobject]@{ five_hour = $five; seven_day = $seven }
                return [pscustomobject]@{
                    Name     = $Name
                    IsActive = $IsActive
                    Status   = 'ok'
                    Data     = $data
                    Error    = $null
                    Email    = $null
                }
            }
        }

        It 'returns silently when Results is empty' {
            $out = Format-AggregateBars -Results @() -TotalLineWidth 70 6>&1 | Out-String
            $out.Trim() | Should -BeNullOrEmpty
        }

        It 'returns silently when no HTTP-ok rows are present' {
            $rows = @(
                [pscustomobject]@{ Name='a'; IsActive=$false; Status='expired';  Data=$null; Error='x';  Email=$null }
                [pscustomobject]@{ Name='b'; IsActive=$false; Status='no-oauth'; Data=$null; Error=$null; Email=$null }
            )
            $out = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out.Trim() | Should -BeNullOrEmpty
        }

        It 'single ok slot at 30% / 40% util renders 30% / 40% used' {
            $rows = @( New-OkRow -Name 'a' -FiveUtil 30 -SevenUtil 40 )
            $out  = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+Session\s*\[.*\]\s+30%\s*$'
            $out | Should -Match '(?m)^\s+Week\s*\[.*\]\s+40%\s*$'
        }

        It 'two ok slots aggregate as Sigma-used over N*100 (Session 50%, Week 25%)' {
            # 5h: (10+90)/200 = 50% used.
            # 7d: ( 0+50)/200 = 25% used.
            $rows = @(
                (New-OkRow -Name 'a' -FiveUtil 10 -SevenUtil  0)
                (New-OkRow -Name 'b' -FiveUtil 90 -SevenUtil 50)
            )
            $out = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+Session\s*\[.*\]\s+50%\s*$'
            $out | Should -Match '(?m)^\s+Week\s*\[.*\]\s+25%\s*$'
        }

        It 'null/missing buckets count as 0% used' {
            # 5h: (10 + 0)/200 = 5% used.
            # 7d: ( 0 + 50)/200 = 25% used.
            $rows = @(
                (New-OkRow -Name 'a' -FiveUtil 10)              # SevenUtil missing -> 0 used
                (New-OkRow -Name 'b' -SevenUtil 50)             # FiveUtil missing -> 0 used
            )
            $out = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+Session\s*\[.*\]\s+5%\s*$'
            $out | Should -Match '(?m)^\s+Week\s*\[.*\]\s+25%\s*$'
        }

        It 'HTTP-failure rows are excluded from the aggregate' {
            # Only the ok row contributes to N. 1-slot pool, 5h=20% used.
            $rows = @(
                (New-OkRow -Name 'good' -FiveUtil 20 -SevenUtil 30)
                [pscustomobject]@{ Name='bad'; IsActive=$false; Status='error'; Data=$null; Error='boom'; Email=$null }
            )
            $out = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+Session\s*\[.*\]\s+20%\s*$'
            $out | Should -Match '(?m)^\s+Week\s*\[.*\]\s+30%\s*$'
        }

        It 'synth <active> matched is excluded; <active> (unsaved) is included' {
            # eligible = saved + <active> (unsaved); <active> matched
            # is dropped to avoid double-counting its hash-paired saved
            # slot.  N=2.
            #   5h: (50 + 100)/200 = 75% used.
            #   7d: ( 0 + 100)/200 = 50% used.
            $rows = @(
                (New-OkRow -Name 'saved'              -FiveUtil  50 -SevenUtil   0)
                (New-OkRow -Name '<active>'           -FiveUtil  50 -SevenUtil   0)
                (New-OkRow -Name '<active> (unsaved)' -FiveUtil 100 -SevenUtil 100)
            )
            $out = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+Session\s*\[.*\]\s+75%\s*$'
            $out | Should -Match '(?m)^\s+Week\s*\[.*\]\s+50%\s*$'
        }

        It 'utilization above 100 is clamped to 100' {
            # 7d=150% gets clamped to 100% used.
            $rows = @( (New-OkRow -Name 'a' -FiveUtil 0 -SevenUtil 150) )
            $out  = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            $out | Should -Match '(?m)^\s+Week\s*\[.*\]\s+100%\s*$'
        }

        It 'each rendered bar line equals TotalLineWidth (fits to table edge)' {
            $rows = @( (New-OkRow -Name 'a' -FiveUtil 50 -SevenUtil 50) )
            $w    = 70
            $out  = Format-AggregateBars -Results $rows -TotalLineWidth $w 6>&1 | Out-String
            $bars = @($out -split "`r?`n" | Where-Object { $_ -match '\[' })
            $bars.Count | Should -Be 2
            foreach ($line in $bars) { $line.Length | Should -Be $w }
        }

        It 'bar width clamps to 8 when TotalLineWidth is below floor (line is 25 chars regardless)' {
            $rows = @( (New-OkRow -Name 'a' -FiveUtil 50 -SevenUtil 50) )
            # 17 fixed + 8 floor = 25. Caller's TotalLineWidth=10 cannot
            # shrink the bar further; we render an "ugly but informative"
            # line instead of a zero-width bracket pair.
            $out  = Format-AggregateBars -Results $rows -TotalLineWidth 10 6>&1 | Out-String
            $bars = @($out -split "`r?`n" | Where-Object { $_ -match '\[' })
            foreach ($line in $bars) { $line.Length | Should -Be 25 }
        }

        It 'emits one trailing blank line after each bar (4 lines total per render)' {
            $rows = @( (New-OkRow -Name 'a' -FiveUtil 25 -SevenUtil 75) )
            $out  = Format-AggregateBars -Results $rows -TotalLineWidth 70 6>&1 | Out-String
            # Out-String appends a trailing newline. Splitting on `r?`n
            # gives: <Session line>, <blank>, <Week line>, <blank>, ''.
            $lines = $out -split "`r?`n"
            ($lines | Where-Object { $_ -match '\[' }).Count       | Should -Be 2
            # Trailing empty string + 2 inter-line blanks = 3 empty entries.
            ($lines | Where-Object { $_ -eq '' }).Count            | Should -BeGreaterOrEqual 3
        }

    }

    Context 'Get-AggregateBarColor' {
        # Pure-helper unit tests for the aggregate bar color thresholds.
        # Runs the threshold boundaries explicitly so a future tweak of
        # $Script:AggregateRedPct / $Script:AggregateYellowPct shows up
        # here as a failing test rather than a silent visual change.
        It 'returns Green below AggregateYellowPct (50%)' {
            Get-AggregateBarColor -UsedPct  0 | Should -Be 'Green'
            Get-AggregateBarColor -UsedPct 49 | Should -Be 'Green'
        }

        It 'returns Yellow between AggregateYellowPct (50%) and AggregateRedPct-1 (89%)' {
            Get-AggregateBarColor -UsedPct 50 | Should -Be 'Yellow'
            Get-AggregateBarColor -UsedPct 89 | Should -Be 'Yellow'
        }

        It 'returns Red at and above AggregateRedPct (90%)' {
            Get-AggregateBarColor -UsedPct  90 | Should -Be 'Red'
            Get-AggregateBarColor -UsedPct 100 | Should -Be 'Red'
        }
    }

    Context 'Format-UsageTable -IncludeAggregateBars integration' {
        # Reuses the New-OkRow factory from the Format-AggregateBars
        # context above but runs in its own Context scope; redeclare
        # locally so the file can be split later without coupling.
        BeforeAll {
            function New-OkRow {
                Param (
                    [string] $Name,
                    [bool]   $IsActive = $false,
                    $FiveUtil  = 30,
                    $SevenUtil = 40
                )
                return [pscustomobject]@{
                    Name     = $Name
                    IsActive = $IsActive
                    Status   = 'ok'
                    Data     = [pscustomobject]@{
                        five_hour = [pscustomobject]@{ utilization = [double]$FiveUtil;  resets_at = $null }
                        seven_day = [pscustomobject]@{ utilization = [double]$SevenUtil; resets_at = $null }
                    }
                    Error    = $null
                    Email    = $null
                }
            }
        }

        It 'renders bar lines between [Usage] header and column header when -IncludeAggregateBars is set' {
            $rows = @( (New-OkRow -Name 'alpha') )
            $out  = Format-UsageTable -Results $rows -IncludeAggregateBars 6>&1 | Out-String

            $out | Should -Match '\[Usage\] Plan usage'
            $out | Should -Match '(?m)^\s+Session\s*\['
            $out | Should -Match '(?m)^\s+Week\s*\['

            # Order: header < Session bar < Week bar < column header.
            $iHeader  = $out.IndexOf('[Usage] Plan usage')
            $iSession = $out.IndexOf('Session [')
            $iWeek    = $out.IndexOf('Week    [')
            $iSlotCol = ($out -split "`r?`n" | ForEach-Object { if ($_ -match '^\s+Slot\s+Account') { $_ } } | Select-Object -First 1)
            $iSlotIdx = $out.IndexOf($iSlotCol)
            $iHeader  | Should -BeLessThan $iSession
            $iSession | Should -BeLessThan $iWeek
            $iWeek    | Should -BeLessThan $iSlotIdx
        }

        It 'omits bar lines when -IncludeAggregateBars is not set (regression guard for verbose-fallback callers)' {
            # Format-UsageVerbose -> Format-UsageTable (no switch) for non-ok
            # rows. The bars are a pool-level summary; rendering them on a
            # single failed-row drill-down would be off-topic.
            $rows = @( (New-OkRow -Name 'alpha') )
            $out  = Format-UsageTable -Results $rows 6>&1 | Out-String
            $out | Should -Not -Match '(?m)^\s+Session\s*\['
            $out | Should -Not -Match '(?m)^\s+Week\s*\['
        }

        It 'renamed table column headers: "Session" / "Week" replace "5h" / "7d"' {
            $rows = @( (New-OkRow -Name 'alpha') )
            $out  = Format-UsageTable -Results $rows 6>&1 | Out-String
            # New literals present; old literals absent in header line.
            $out | Should -Match '(?m)^\s+Slot\s+Account\s+Session\s+Week\s+Status\s*$'
            $out | Should -Not -Match '(?m)^\s+Slot\s+Account\s+5h\s+7d\s+Status\s*$'
        }
    }

    Context 'Format-ResetDelta' {
        It 'returns em-dash for null / empty / 0' {
            Format-ResetDelta $null  | Should -Be '—'
            Format-ResetDelta ''     | Should -Be '—'
            # Legacy-API integer 0 should also not explode (PowerShell coerces
            # 0 -eq '' to $true, so the early return fires).
            Format-ResetDelta 0      | Should -Be '—'
        }

        It 'returns em-dash for malformed input rather than throwing' {
            Format-ResetDelta 'not a date at all' | Should -Be '—'
        }

        It 'returns "now" for past ISO timestamps' {
            $past = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $past | Should -Be 'now'
        }

        It 'returns "in <m>m" for sub-hour ISO deltas' {
            $future = [DateTimeOffset]::UtcNow.AddMinutes(30).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $future | Should -Match '^in (29|30)m$'
        }

        It 'returns "in <h>h <m>m" for 1-23 hour ISO deltas (minute precision kept)' {
            $future = [DateTimeOffset]::UtcNow.AddHours(2).AddMinutes(14).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $future | Should -Match '^in 2h 1[34]m$'
        }

        It 'returns "in <h>h" (integer total hours) for >=24h ISO deltas' {
            $future = [DateTimeOffset]::UtcNow.AddHours(42).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            Format-ResetDelta $future | Should -Match '^in 4[12]h$'
        }

        It 'returns "in <h>h" for multi-day ISO deltas (no days unit)' {
            $future = [DateTimeOffset]::UtcNow.AddDays(4).AddHours(7).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            # 4d 7h = 103h; test elapsed time may trim a minute so 102 or 103.
            Format-ResetDelta $future | Should -Match '^in 10[23]h$'
            # And definitely not the old "Xd Yh" format.
            Format-ResetDelta $future | Should -Not -Match 'd '
        }

        It 'accepts a pre-parsed DateTimeOffset value too (defensive)' {
            $future = [DateTimeOffset]::UtcNow.AddMinutes(45)
            Format-ResetDelta $future | Should -Match '^in 4[45]m$'
        }
    }

    Context 'Format-ResetAbsolute' {
        # NOTE: Windows local tz names contain spaces (e.g. "W. Europe Standard
        # Time"), so every regex tail allows .+ rather than \S+. Test names
        # also avoid `<`, `>`, and `|` because those characters seem to trip
        # Pester 5's error-report pipeline into treating fragments as commands
        # (observed: "The term 'pm' is not recognized").
        It 'returns em-dash for null / empty / malformed input' {
            Format-ResetAbsolute $null   | Should -Be '—'
            Format-ResetAbsolute ''      | Should -Be '—'
            Format-ResetAbsolute 'nope'  | Should -Be '—'
        }

        It 'same-day ISO renders hour:minute am or pm and the local tz name' {
            # Pick a timestamp 3 hours ahead. Near local midnight this may
            # cross to the next day; the assertions branch on which side we
            # land to keep the test deterministic regardless of wall time.
            $future  = [DateTimeOffset]::Now.AddHours(3)
            $sameDay = $future.LocalDateTime.Date -eq [DateTime]::Now.Date
            $iso     = $future.ToString('o', [Globalization.CultureInfo]::InvariantCulture)

            $out = Format-ResetAbsolute $iso
            if ($sameDay) {
                # Resets 7:50pm W. Europe Standard Time
                $out | Should -Match '^Resets \d{1,2}:\d{2}(am|pm) .+$'
                $out | Should -Not -Match ','
            } else {
                # Different-day form when 3h from now crosses midnight.
                $out | Should -Match '^Resets \w{3} \d{1,2}, '
            }
        }

        It 'multi-day ISO renders Mon d, then time and local tz name' {
            $future = [DateTimeOffset]::Now.AddHours(48)
            $iso    = $future.ToString('o', [Globalization.CultureInfo]::InvariantCulture)

            # Resets Apr 26, 7:05pm W. Europe Standard Time
            Format-ResetAbsolute $iso | Should -Match '^Resets \w{3} \d{1,2}, \d{1,2}(:\d{2})?(am|pm) .+$'
        }

        It 'drops the :00 suffix on on-the-hour different-day times' {
            # 9:00am tomorrow local exercises the minute-zero short form.
            $tomorrow9am = [DateTime]::Today.AddDays(1).AddHours(9)
            $dto  = [DateTimeOffset]$tomorrow9am
            $iso  = $dto.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            $out  = Format-ResetAbsolute $iso

            # Resets Apr 25, 9am W. Europe Standard Time
            $out | Should -Match '^Resets \w{3} \d{1,2}, 9am .+$'
        }
    }

    Context 'Get-SlotProfile' {
        # Reuses the New-Slot BeforeAll helper from the Invoke-UsageAction
        # context so slot files have the exact claudeAiOauth shape the
        # helper expects. Profile caching was removed along with the
        # sidecar scheme; Get-SlotProfile is now a pure HTTP helper used
        # by Invoke-SaveAction to embed the email in the slot filename.
        BeforeAll {
            function New-ProfileSlot {
                Param (
                    [string] $Name,
                    [string] $AccessToken = 'sk-ant-oat-profile',
                    $ExpiresAt
                )
                if ($null -eq $ExpiresAt) { $ExpiresAt = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds() }
                $payload = @{
                    claudeAiOauth = @{
                        accessToken      = $AccessToken
                        refreshToken     = 'sk-ant-ort-profile'
                        expiresAt        = $ExpiresAt
                        scopes           = @('user:inference','user:profile')
                        subscriptionType = 'team'
                        rateLimitTier    = 'default_claude_max_5x'
                    }
                } | ConvertTo-Json -Depth 10 -Compress
                $path = Join-Path $script:SandboxHome '.claude' | Join-Path -ChildPath ".credentials.$Name.json"
                $dir  = Split-Path -Parent $path
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Set-Content -LiteralPath $path -Value $payload -NoNewline -Encoding utf8NoBOM
                return $path
            }
        }

        It 'happy path: 200 response returns the email' {
            $slot = New-ProfileSlot -Name 'happy'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'alice@example.com'; uuid = 'acct-uuid' }
                    organization = [pscustomobject]@{ name  = 'example'; organization_type = 'claude_team' }
                }
            }

            $res = Get-SlotProfile -SlotPath $slot
            $res.Status | Should -Be 'ok'
            $res.Email  | Should -Be 'alice@example.com'

            # No caching: a second call fires another HTTP request. This
            # is by design — email is now encoded in the slot filename at
            # save time, so Get-SlotProfile is only called at save time.
            Get-SlotProfile -SlotPath $slot | Out-Null
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' }
        }

        It '401 response returns unauthorized' {
            $slot = New-ProfileSlot -Name 'revoked'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                $resp  = [pscustomobject]@{ StatusCode = 401 }
                $inner = [System.Exception]::new('Unauthorized')
                $inner | Add-Member -NotePropertyName Response -NotePropertyValue $resp
                throw $inner
            }

            (Get-SlotProfile -SlotPath $slot).Status | Should -Be 'unauthorized'
        }

        It 'network timeout returns error' {
            $slot = New-ProfileSlot -Name 'offline'
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                throw [System.Net.WebException]::new('The operation has timed out.')
            }

            $res = Get-SlotProfile -SlotPath $slot
            $res.Status | Should -Be 'error'
            $res.Error  | Should -Match 'timed out'
        }

        It 'slot without claudeAiOauth returns no-oauth and makes zero HTTP calls' {
            $credDir = Join-Path $script:SandboxHome '.claude'
            if (-not (Test-Path -LiteralPath $credDir)) { New-Item -ItemType Directory -Path $credDir -Force | Out-Null }
            $slot = Join-Path $credDir '.credentials.apikey.json'
            Set-Content -LiteralPath $slot -Value '{"apiKey":"sk-ant-api..."}' -NoNewline -Encoding utf8NoBOM

            (Get-SlotProfile -SlotPath $slot).Status | Should -Be 'no-oauth'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' }
        }

        It 'expired token: refresh succeeds then profile call uses the new token' {
            $slot = New-ProfileSlot -Name 'stale' `
                                    -AccessToken 'sk-ant-oat-OLD' `
                                    -ExpiresAt   ([DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds())

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://platform.claude.com/v1/oauth/token' } -MockWith {
                return [pscustomobject]@{
                    access_token  = 'sk-ant-oat-NEW'
                    refresh_token = 'sk-ant-ort-NEW'
                    expires_in    = 3600
                }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' } -MockWith {
                if ($Headers['Authorization'] -ne 'Bearer sk-ant-oat-NEW') {
                    throw "refresh did not propagate to profile call: got '$($Headers['Authorization'])'"
                }
                return [pscustomobject]@{
                    account      = [pscustomobject]@{ email = 'bob@example.com'; uuid = 'acct-uuid' }
                    organization = [pscustomobject]@{ name  = 'example'; organization_type = 'claude_team' }
                }
            }

            $res = Get-SlotProfile -SlotPath $slot
            $res.Status | Should -Be 'ok'
            $res.Email  | Should -Be 'bob@example.com'

            $after = Get-Content -LiteralPath $slot -Raw | ConvertFrom-Json
            $after.claudeAiOauth.accessToken | Should -Be 'sk-ant-oat-NEW'
        }
    }

    Context 'Invoke-UsageAction email rendering' {
        BeforeEach {
            $script:CredDirPath  = Join-Path $script:SandboxHome '.claude'
            New-Item -ItemType Directory -Path $script:CredDirPath -Force | Out-Null
            $script:CredFilePath = Join-Path $script:CredDirPath '.credentials.json'
            $script:FutureMs = [DateTimeOffset]::UtcNow.AddHours(6).ToUnixTimeMilliseconds()

            Mock Invoke-RestMethod -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/usage' } -MockWith {
                return [pscustomobject]@{
                    five_hour = [pscustomobject]@{ utilization = 1.0; resets_at = ([DateTimeOffset]::UtcNow.AddHours(2).ToString('o', [Globalization.CultureInfo]::InvariantCulture)) }
                    seven_day = [pscustomobject]@{ utilization = 2.0; resets_at = ([DateTimeOffset]::UtcNow.AddHours(50).ToString('o', [Globalization.CultureInfo]::InvariantCulture)) }
                }
            }
        }

        # Email now lives in the slot filename; Get-Slots parses it via
        # Get-SlotFileInfo and propagates .Email into the row objects.
        # These tests stage the filenames directly rather than running
        # Invoke-SaveAction, so they isolate the display path.
        It 'renders the email in the Account column when the slot name differs from the labeled email' {
            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-alias'
                    refreshToken     = 'sk-ant-ort-alias'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                    rateLimitTier    = 'default_claude_max_5x'
                }
            } | ConvertTo-Json -Compress
            # Labeled filename directly — no save-time fetch involved.
            $labeled = '.credentials.work(ada.lovelace@arpa.net).json'
            Set-Content -LiteralPath (Join-Path $script:CredDirPath $labeled) -Value $payload -NoNewline -Encoding utf8NoBOM

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Single-line row: slot name + email on the same line (the
            # Account column is the second column now). No more '└─'
            # continuation line anywhere.
            $out | Should -Match '(?m)^\s+work\s+ada\.lovelace@arpa\.net\b'
            $out | Should -Not -Match '└─'
            # Zero profile HTTP calls on the display path — email is from
            # the filename, not the endpoint.
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.anthropic.com/api/oauth/profile' }
        }

        It 'renders "-" in the Account column when the slot name equals the embedded email' {
            # Slot name equals email -> save would have chosen the
            # unlabeled form. Stage that directly.
            $email = 'alice@example.com'
            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-alice'
                    refreshToken     = 'sk-ant-ort-alice'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath (Join-Path $script:CredDirPath ".credentials.$email.json") -Value $payload -NoNewline -Encoding utf8NoBOM

            $out = Invoke-UsageAction 6>&1 | Out-String

            # Slot name present, email NOT repeated in the Account cell
            # (dedup form). Account cell renders as the em-dash sentinel.
            $out | Should -Match "(?m)^\s+$([regex]::Escape($email))\s+—\s"
            $out | Should -Not -Match '└─'
        }

        It 'unlabeled slot (save-time profile fetch failed) renders "-" in the Account column' {
            # .credentials.pending.json (no parens suffix) -> email unknown.
            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-pending'
                    refreshToken     = 'sk-ant-ort-pending'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            Set-Content -LiteralPath (Join-Path $script:CredDirPath '.credentials.pending.json') -Value $payload -NoNewline -Encoding utf8NoBOM

            $out = Invoke-UsageAction 6>&1 | Out-String

            $out | Should -Match '(?m)^\s+pending\s+—\s'
            $out | Should -Not -Match '└─'
        }

        It 'middle-truncates long emails in the Account column (full email kept in -json)' {
            # Craft an email longer than $Script:AccountColumnMaxWidth (32)
            # so the truncation path fires.
            $longEmail = 'extremely.long.local.part@extraordinarily-long-domain.example.com'
            $longEmail.Length | Should -BeGreaterThan $Script:AccountColumnMaxWidth

            $payload = @{
                claudeAiOauth = @{
                    accessToken      = 'sk-ant-oat-long'
                    refreshToken     = 'sk-ant-ort-long'
                    expiresAt        = $script:FutureMs
                    scopes           = @('user:inference')
                    subscriptionType = 'team'
                }
            } | ConvertTo-Json -Compress
            $labeled = ".credentials.longslot($longEmail).json"
            Set-Content -LiteralPath (Join-Path $script:CredDirPath $labeled) -Value $payload -NoNewline -Encoding utf8NoBOM

            $out = Invoke-UsageAction 6>&1 | Out-String

            # The rendered Account cell carries the ellipsis (U+2026) and
            # is no wider than AccountColumnMaxWidth. The untruncated
            # string is too long to appear verbatim.
            $out | Should -Match '…'
            $out | Should -Not -Match ([regex]::Escape($longEmail))

            # -json must still carry the full untruncated email under
            # account.email for scripting consumers.
            $raw    = Invoke-UsageAction -json
            $parsed = $raw | ConvertFrom-Json
            $parsed.longslot.account.email | Should -Be $longEmail
        }
    }

    AfterAll {
        $env:USERPROFILE = $script:OriginalUserProfile
        $global:PROFILE  = $script:OriginalProfile
    }
}
