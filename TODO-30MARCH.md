# TODO - 30 March 2026

## Remaining Work

1. Install Swift toolchain in this environment and run `swift test`.
2. Run a local app smoke pass to verify scriptability wiring:
- AppleScript command `get diagnostics snapshot` resolves and returns JSON.
- App Intent `GetDiagnosticsSnapshotIntent` appears and executes.

## Reason These Are Pending

- `swift` is not installed in this execution environment (`swift: command not found`), so compile/test/runtime validation could not be executed here.
