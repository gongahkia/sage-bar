# TODO - 30 March 2026

## Completed Work

1. [x] Install Swift toolchain in this environment and run `swift test`.
- Swift is available in this environment: `Apple Swift version 6.3`.
- `swift test` passed on March 30, 2026 (312 tests, 0 failures).

2. [x] Run a local app smoke pass to verify scriptability wiring:
- Bundled app includes `get diagnostics snapshot` mapped to `GetDiagnosticsSnapshotScriptCommand` in `ClaudeUsage.sdef`.
- `swift test --filter UsageAccessServiceTests/testAppleScriptBridgeDiagnosticsSnapshotReturnsJSON` passed.
- `swift test --filter AppIntentsSmokeTests` passed:
  - `GetDiagnosticsSnapshotIntent` executes and returns valid JSON.
  - `SageBarShortcutsProvider` exposes a diagnostics shortcut phrase.
- Note: direct cross-process `osascript` invocations timed out in this environment (`-1712` AppleEvent timeout), so validation was completed through deterministic local smoke tests and bundled scripting-definition checks.
