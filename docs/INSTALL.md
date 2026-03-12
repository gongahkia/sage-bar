# Install Sage Bar

This guide covers the supported ways to install, update, run, and fully reset Sage Bar on macOS.

## Preferred: Install the Release App

1. Open [GitHub Releases](https://github.com/gongahkia/sage-bar/releases).
2. Download the latest `Sage-Bar-vX.Y.Z.zip`.
3. Unzip the archive.
4. Move `Sage Bar.app` into `/Applications`.
5. Open `Sage Bar.app`.

If Gatekeeper warns on first launch:
- Control-click `Sage Bar.app`.
- Choose `Open`.
- Confirm once.

## Run From Source

From the repository root:

```bash
swift run SageBar
```

For a local app bundle:

```bash
make bundle
open "Sage Bar.app"
```

For a bundle smoke test:

```bash
make verify-bundle
```

## Update an Existing Install

Release app update:
1. Quit Sage Bar.
2. Download the latest release zip.
3. Replace the existing `Sage Bar.app` in `/Applications`.
4. Re-open the app.

Local development update:
1. Pull the latest source.
2. Re-run `make bundle`.
3. Replace the old local `Sage Bar.app`.

## Remove Sage Bar Completely

Delete the app:

```bash
rm -rf "/Applications/Sage Bar.app"
```

Remove config, cache, and logs kept under compatibility paths:

```bash
rm -rf ~/.config/claude-usage
rm -rf ~/.claude-usage
rm -rf ~/Library/Group\ Containers/group.dev.claudeusage
rm -f ~/Library/Preferences/dev.claudeusage.ClaudeUsage.plist
```

Optional: remove stored credentials from Keychain Access:
- `claude-usage`
- `claude-usage-session-token`

## Where Sage Bar Stores Data

- Config: `~/.config/claude-usage`
- Logs and local app data: `~/.claude-usage`
- Shared app-group container: `~/Library/Group Containers/group.dev.claudeusage`
- Preferences plist: `~/Library/Preferences/dev.claudeusage.ClaudeUsage.plist`

These paths remain on the legacy namespace for compatibility with existing installs.

## Install Notes

- Direct download of `Sage Bar.app` is the primary install path.
- Homebrew is secondary and may lag behind the direct release artifact.
- The bundled app includes Sparkle for update distribution and verification.
