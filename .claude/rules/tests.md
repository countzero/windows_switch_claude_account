---
paths:
  - "tests/**/*.ps1"
---

# Test conventions

## Layout

- One file per action under `tests/Invoke-<Action>Action.Tests.ps1`, plus `Helpers.Tests.ps1` and `Profile-Install.Tests.ps1`.
- Each file's outer `Describe` is named `'switch_claude_account'` so `-FullNameFilter` recipes work uniformly across files.
- Shared per-test setup lives in `tests/Common.ps1`, dot-sourced from each file's `BeforeEach`.

## Sandboxing

- `tests/Common.ps1` sandboxes `$env:USERPROFILE` and `$PROFILE.CurrentUserAllHosts` per test via `$TestDrive` — the real profile and real `.claude` directory are never touched.
- `$PSStyle.OutputRendering = 'PlainText'` is set once per `BeforeEach` so existing string-match assertions see ANSI-stripped output without per-test changes. The `Helpers.Tests.ps1` 'No-color mode' Context overrides this to `'Host'` in its `It` bodies (with `try/finally` restore) so the toggle's gate logic is testable.

## Direct-call pattern

- The script is dot-sourced; tests call `Invoke-*Action` functions directly (bypassing `Invoke-Main`).
- The script's top-level dispatcher is guarded by `if ($MyInvocation.InvocationName -ne '.') { Invoke-Main }` so dot-sourcing does not trigger a live run.
- Because `Invoke-Main` is bypassed, the `-NoColor` / `$PSStyle.OutputRendering` `try/finally` in `Invoke-Main` does not fire in tests — `Common.ps1` substitutes for it.

## Mocks

- `Invoke-RestMethod` is mocked by `$Uri` to verify the action's *shape contract*. This will NOT catch the unofficial `/api/oauth/usage` constants drifting out of date — only a live call can. After bumping the constants, run `tests/Invoke-Tests.ps1` then exercise `sca usage` against a real account.

## Output capture

- Use `6>&1 | Out-String` to capture `Write-Host` output (information stream 6). Stream 4 (`Write-Progress`) is not captured by this pattern — relevant when adding new rendering helpers.
