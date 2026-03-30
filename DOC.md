# Sage Bar: Repository Intent, Value Proposition, and Expansion Plan

_Last updated: March 30, 2026._

## 1. Repository Structure and Intent

Sage Bar is a macOS menu bar observability tool for AI-agent usage economics. Its center of gravity is not “chat UI,” but **operational telemetry** across heterogeneous agent providers (local and remote).

### Top-level structure

- `Sources/ClaudeUsage/App`: app lifecycle and launch orchestration.
- `Sources/ClaudeUsage/MenuBar`: core menu bar UX (live status, account switcher, summaries).
- `Sources/ClaudeUsage/Services`: polling, webhook dispatch, sync, and runtime plumbing.
- `Sources/ClaudeUsage/API`: provider clients (Anthropic, OpenAI Org usage, GitHub Copilot, Windsurf, Claude AI).
- `Sources/ClaudeUsage/Parsers`: local log ingestors (Claude Code, Codex, Gemini CLI).
- `Sources/ClaudeUsage/Cache`: persisted snapshots/forecasts and ingestion cursors.
- `Sources/ClaudeUsage/Reporting`: human and CSV reporting surfaces.
- `Sources/ClaudeUsage/Scriptable`: AppleScript/AppIntents integration layer.
- `Sources/ClaudeUsage/Settings` + `Dashboard`: control plane and analysis UI.
- `Tests/ClaudeUsageTests`: broad behavior coverage across ingestion, automation, and persistence.

### Functional architecture (what it does today)

1. Collects usage from local logs and provider APIs.
2. Normalizes into `UsageSnapshot` with token/cost metadata.
3. Persists snapshots, cursor state, and forecasts locally.
4. Surfaces operating state in menu bar/settings/dashboard.
5. Supports export and automation (CSV, webhooks, command automation, AppIntents, AppleScript).

This is already a strong foundation for agent developers who need one pane for spend and token flow.

## 2. Philosophical Value Proposition (Current)

Current implied philosophy:

- **“Keep AI usage observable where developers already live.”**
- **“Make provider heterogeneity operationally manageable.”**
- **“Support both individual and team-level accountability.”**

This is directionally correct, but adoption risk existed in two areas:

1. **Machine-readability gap:** strong UI and CSV outputs, but weaker single-shot diagnostics contract for automated agent tooling.
2. **Silent-failure pockets:** several fallback paths used `try?` and dropped failure reasons that matter for debugging in production workflows.

## 3. Market Conventions for Agent-Dev Observability

Across current observability products, common conventions are:

1. **Trace-first debugging and metadata richness**
- Operational traces with consistent semantic fields.
- Sources: OpenTelemetry semantic conventions, OpenInference spec.

2. **Automation-ready outputs**
- JSON-first payloads and API/script surfaces for CI/ops integration.
- Sources: Langfuse observability workflows, LangSmith observability workflows.

3. **Runtime governance and reliability controls**
- Cost visibility, retries, rate-limit handling, and actionable failure telemetry.
- Sources: Helicone product focus on reliability/cost observability.

### Reference links

- OpenTelemetry semantic conventions: <https://opentelemetry.io/docs/specs/semconv/>
- OpenInference specification: <https://github.com/Arize-ai/openinference/tree/main/spec>
- Langfuse observability docs: <https://langfuse.com/docs/observability/get-started>
- LangSmith observability docs: <https://docs.smith.langchain.com/observability>
- Helicone platform overview: <https://www.helicone.ai/>

## 4. Expansion Implemented in This Update

## 4.1 New diagnostics contract for agent developers

Added a machine-readable runtime snapshot that captures:

- app/build/config metadata,
- account inventory and account health signals,
- polling health and skip reasons,
- parser metrics,
- recent error log lines.

This creates a stable “state handoff” for scripts, agent orchestrators, and runbooks.

### New surfaces

- Core service:
  - `Sources/ClaudeUsage/Diagnostics/DiagnosticsSnapshotService.swift`
- Programmatic access:
  - `UsageAccessService.diagnosticsSnapshot(...)`
  - `UsageAccessService.diagnosticsSnapshotJSON(...)`
- AppleScript:
  - `get diagnostics snapshot`
- App Intents / Shortcuts:
  - `GetDiagnosticsSnapshotIntent`

## 4.2 Silent-failure hardening and observability improvements

Implemented explicit failure logging in high-value paths:

- `ErrorLogger` filesystem reads/writes/rotation now emit explicit failures.
- `SetupExperienceStore` decode fallback now logs structured warning context.
- `ParserMetricsStore` read/decode fallback now logs and degrades safely.
- model hints cache loading in popover now logs decode/read failures.
- `WebhookService` payload build now fails fast on serialization issues instead of returning empty payload data.

## 4.3 Test coverage updates

Added/updated tests to protect the new contract:

- diagnostics snapshot output is valid JSON and includes key account/total fields,
- AppleScript diagnostics bridge returns machine-readable snapshot,
- webhook payload tests updated for explicit throwing behavior.

## 5. Why this materially improves adoption for agent developers

The project now better satisfies practical adoption criteria:

1. **Integrates into automation loops** via a stable diagnostics JSON envelope.
2. **Improves mean-time-to-debug** by logging formerly silent fallback failures.
3. **Keeps UX and DX aligned**: menu bar/UI for humans, machine-readable snapshots for agents/scripts.
4. **Aligns with market expectations** around telemetry semantics, reliability, and traceable runtime state.

## 6. Recommended Next Expansion Steps (High Impact)

1. Add optional trace/span IDs to poll cycles and webhook/automation events for cross-system correlation.
2. Add signed/redacted diagnostics export mode for safe issue sharing.
3. Add a headless CLI wrapper (`sage-bar diagnostics --json`) around the same snapshot contract.
4. Add policy checks (budget breaches, stale data SLAs, credential drift) as machine-evaluable diagnostics flags.

