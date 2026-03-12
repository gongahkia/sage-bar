[![](https://img.shields.io/badge/sage_bar_v1.0.0-passing-green)](https://github.com/gongahkia/sage-bar/releases/tag/1.0.0)

# `Sage Bar`

MacOS [menu bar](https://support.apple.com/en-sg/guide/mac-help/mchlp1446/mac) app for tracking [AI token usage and spend](https://blogs.nvidia.com/blog/ai-tokens-explained/) across [providers](#support).

<div align="center">
    <img src="./asset/logo/wizard.png">
</div>

## Stack

* *Frontend*: ...
* *Backend*: ...
* *Script*: ...
* *API*: ...

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

* [Anthropic API]()
* [OpenAI organization usage]()
* [GitHub Copilot organization metrics]()
* [Windsurf Enterprise analytics]()
* [Claude AI session-based usage]()

### Local providers

* [Claude Code local session logs]()
* [Codex local session logs]()
* [Gemini CLI local session logs]()