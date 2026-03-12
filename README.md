# Sage Bar

Sage Bar is a macOS menu bar app for tracking AI usage, spend, quotas, and account health across local agents and connected provider accounts.

It is built around one always-available workflow: open the menu bar icon, see the current state of your accounts, and take action before usage or quota problems become expensive.

## Supported Sources

Local sources:
- Claude Code local session logs
- Codex local session logs
- Gemini CLI local session logs

Connected providers:
- Anthropic API
- OpenAI organization usage
- GitHub Copilot organization metrics
- Windsurf Enterprise analytics
- Claude AI session-based usage

## Run From Source

From the repository root:

```bash
swift run SageBar
```

Or with `make`:

```bash
make run
```

Sage Bar is a menu bar app. After launch, look for it in the macOS menu bar rather than expecting a normal dock-first window.

## Build, Test, and Bundle

Build the app:

```bash
swift build
```

Run the test suite:

```bash
swift test
```

Create a local `.app` bundle:

```bash
make bundle
open "Sage Bar.app"
```

Smoke-test the bundled app locally:

```bash
make verify-bundle
```

Create a release-style local archive:

```bash
make archive-release
```

## Install

Primary install path:
- Download the latest `Sage Bar.app` release archive from [GitHub Releases](https://github.com/gongahkia/sage-bar/releases).
- Unzip it.
- Move `Sage Bar.app` into `/Applications`.
- Open it once from Finder.

Development install path:
- Run `make bundle`.
- Open `Sage Bar.app`.

Detailed install, upgrade, and reset instructions live in [docs/INSTALL.md](./docs/INSTALL.md).

## First Run

On first launch, Sage Bar opens a setup wizard. The fastest useful path is:

1. Connect one account.
2. Validate it immediately.
3. Confirm notifications and Accessibility status.
4. Open the menu bar popover.

If you skip setup, Sage Bar keeps a lightweight `Finish setup` prompt until at least one account is validated.

## Permissions Sage Bar May Request

- Notifications: for spend thresholds, burn-rate alerts, and `claude.ai` low-quota warnings.
- Accessibility: required only for the global hotkey and account-cycle chord.
- Network access: required for connected providers and update checks.

## Troubleshooting

Missing menu bar icon:
- Launch the app again with `open -n "Sage Bar.app"` or `swift run SageBar`.
- Check whether macOS hid the menu bar item in the menu bar overflow area.

Hotkey is not working:
- Open macOS Accessibility settings and allow the app controlling Sage Bar.
- Re-open Sage Bar after granting permission.

`claude.ai` needs re-authentication:
- Open Settings > Accounts.
- Reconnect the Claude AI account with a fresh `sessionKey` token.

Bundled app does not launch:
- Rebuild with `make bundle`.
- Re-run `make verify-bundle` to confirm the executable, framework embedding, codesign, and smoke launch are valid.

## Release Notes

Local `make bundle` and release CI both use the same bundle script in [scripts/bundle_app.sh](./scripts/bundle_app.sh). Bundle verification and smoke launch checks use [scripts/verify_app_bundle.sh](./scripts/verify_app_bundle.sh).
