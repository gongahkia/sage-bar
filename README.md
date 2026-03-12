[![](https://img.shields.io/badge/sage_bar_v1.0.0-passing-green)](https://github.com/gongahkia/sage-bar/releases/tag/1.0.0)

# `Sage Bar`

MacOS [menu bar](https://support.apple.com/en-sg/guide/mac-help/mchlp1446/mac) app for tracking [AI token usage and spend](https://blogs.nvidia.com/blog/ai-tokens-explained/) across [providers](#support).

<div align="center">
    <img src="./asset/logo/wizard.png">
</div>

## Stack

* *Script*: [Swift](https://www.swift.org/), [Swift Package Manager](https://docs.swift.org/package-manager/)
* *UI*: [SwiftUI](https://developer.apple.com/swiftui/), [Apple AppKit](https://developer.apple.com/documentation/appkit), [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem), [NSPopover](https://developer.apple.com/documentation/appkit/nspopover)
* *Configuration*: [TOMLKit](https://github.com/LebJe/TOMLKit)
* *Package*: [Sparkle](https://sparkle-project.org/), [Homebrew](https://brew.sh/)
* *CI/CD*: [GitHub Actions](https://github.com/features/actions)

## Screenshots

<div align="center">
    <img src="./asset/reference/1.png" width="40%">
    <img src="./asset/reference/2.png" width="59%">
</div>

## Usage

Below are instructions for locally downloading and using `Sage Bar`.

1. First run the below to [install](./docs/INSTALL.md) `Sage Bar`'s source code.'

```console
$ git clone https://github.com/gongahkia/sage-bar && cd sage-bar
```

2. Alternatively download `Sage Bar`'s latest release from [GitHub Releases](https://github.com/gongahkia/sage-bar/releases).

3. Optionally execute the below commands to invoke `Sage Bar`'s core build functionality. 

```console
$ swift run SageBar # run immediately
$ make run # alternative run command

$ swift build # build the app
$ swift test # run the test suite
$ make bundle # create a local .app bundle

$ make verify-bundle # smoke-test the bundled app locally
$ make archive-release #create a release-style local archive
```

## Architecture

![](./asset/reference/architecture.png)

## Support

`Sage Bar` currently supports the following [local](#local-providers) and [remote](#remote-providers) AI providers.

### Remote providers

* [Anthropic API](https://docs.anthropic.com/en/api/data-usage-cost-api)
* [OpenAI organization usage](https://platform.openai.com/docs/overview)
* [GitHub Copilot organization metrics](https://docs.github.com/en/rest/copilot/copilot-usage)
* [Windsurf Enterprise analytics](https://docs.windsurf.com/plugins/accounts/api-reference/analytics-api-introduction)
* [Claude AI session-based usage](https://claude.ai/)

### Local providers

* [Claude Code local session logs](https://docs.anthropic.com/en/docs/claude-code/overview)
* [Codex local session logs](https://openai.com/codex/)
* [Gemini CLI local session logs](https://github.com/google-gemini/gemini-cli)
