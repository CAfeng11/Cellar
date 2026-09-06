# Cellar for macOS

[简体中文](README.zh-CN.md)

[![Platform](https://img.shields.io/badge/macOS-14%2B-black)](https://support.apple.com/macos)
![Swift](https://img.shields.io/badge/Swift-5-orange)
[![Release](https://img.shields.io/github/v/release/CAfeng11/Cellar?label=release)](https://github.com/CAfeng11/Cellar/releases/latest)
[![CI](https://github.com/CAfeng11/Cellar/actions/workflows/ci.yml/badge.svg)](https://github.com/CAfeng11/Cellar/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-green)

**Fix Homebrew update confusion and Node/Python PATH conflicts from a native macOS app.**

Cellar is a native SwiftUI menu bar app and full-window workspace for explainable
Homebrew maintenance and local runtime diagnostics. It shows what needs attention,
why terminal and GUI environments disagree, and what a proposed repair will change
before anything is modified.

<p align="center">
  <a href="docs/images/cellar-demo.gif">
    <img src="docs/images/cellar-demo.gif" alt="Cellar dashboard, package library, and Runtime Doctor demo" width="900">
  </a>
</p>

<p align="center"><em>Dashboard → package library → Runtime Doctor in 10 seconds.</em></p>

## Download

[**Download the latest signed macOS build**](https://github.com/CAfeng11/Cellar/releases/latest/download/Cellar-macOS.zip)

Requirements: macOS 14 or newer and an existing Homebrew installation. The release
is a Universal app for Apple Silicon and Intel Macs. Published binaries are signed,
notarized, stapled, and checked with Gatekeeper before they are attached to a release.

> The first signed binary is being prepared as `2.2.3`. Until it appears on the
> Releases page, use the source-build instructions below. Cellar does not publish an
> unsigned fallback as a public download.

## Why Cellar

Homebrew, version managers, GUI apps, and login shells can each work correctly on
their own while producing a confusing combined state:

- Is there actually something worth updating today?
- Why do the app bundle, Homebrew receipt, and repository report different versions?
- Why can Terminal find Node or Python while a GUI app cannot?
- Which PATH is authoritative, and what would a repair affect?

Cellar does not replace Homebrew or a runtime manager. It turns their existing state
into an observable, explainable, and reversible maintenance workflow.

## What makes it different

| | Cellar | Typical Homebrew GUI |
|---|---|---|
| Homebrew package maintenance | Yes | Yes |
| App bundle vs receipt vs repository version | Explained separately | Often shown as one update state |
| GUI PATH vs login-shell PATH | Compared directly | Usually out of scope |
| Node/Python version-manager diagnostics | Runtime Doctor | Usually out of scope |
| Repairs | Scope, command, verification, and rollback shown | Varies |
| Risky environment changes | Never silent | Varies |

Cellar is for developers and Mac power users who want a GUI without losing the
evidence behind the result.

## Core features

### Homebrew maintenance

- Menu bar count for ordinary outdated packages
- Fast `brew outdated` snapshots with a separate `brew update` threshold
- Individual and batch upgrades, Formula pin/unpin, install, uninstall, and cleanup
- Separate states for ordinary updates, self-updating Casks, repository-version
  differences, and Homebrew receipt differences
- App bundle version inspection instead of treating a receipt as the installed app
- Structured proxy, DNS, network, endpoint, permission, timeout, and missing-brew
  diagnostics
- Cancellation and post-operation verification summaries for long-running work

### Runtime Doctor

- Node and Python observed in the same workspace
- GUI and login-shell PATH, interpreter, and package-manager comparison
- Homebrew, nvm, fnm, Volta, pyenv, conda, pipx, and uv source detection
- Global-tool versions, latest-version freshness, source, and check time
- Minimal Trusted PATH, Observe Only, full shell mirroring, and expert policy modes
- High-risk actions default to an explained command, impact scope, and rollback plan

### Explainable state

- A dashboard that answers “does this need action?” and “what comes next?”
- A package library that does not mislabel every version difference as an upgrade
- Structured events for important outcomes and raw logs for advanced investigation
- Exportable reports containing diagnostics, PATH policy, reliability findings, and
  repair history

## Safety and privacy

- Cellar does not silently rewrite shell configuration.
- Complete environment variables, proxy credentials, and registry credentials are
  not persisted.
- Runtime global tools are not mixed into the ordinary Homebrew upgrade queue.
- Installed size is not presented as download size.
- GUI PATH writes show their scope and rollback command first.

See [Architecture](docs/ARCHITECTURE.md) for module boundaries and [Security](SECURITY.md)
for the threat model and vulnerability-reporting process.

## Build from source

Source builds require macOS 14+, Xcode 26+, and Homebrew.

```bash
git clone https://github.com/CAfeng11/Cellar.git
cd Cellar
./script/build_and_run.sh
```

Useful modes:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --debug
```

You can also open `Cellar.xcodeproj` and run the shared `Cellar` scheme.

## Test

```bash
./script/test.sh
```

CI runs the same test entry point. Release packaging and notarization are documented
in [Releasing Cellar](docs/RELEASING.md).

## Contributing

Focused, verifiable contributions are welcome, especially around Homebrew behavior,
SwiftUI accessibility, menu bar UX, runtime-manager detection, tests, and docs.

Read [CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
before opening a pull request. Use the issue templates for bugs and feature requests.

Cellar is currently maintained by one person. See [ROADMAP.md](ROADMAP.md) for the
current direction and [CHANGELOG.md](CHANGELOG.md) for visible changes.

## License

[MIT License](LICENSE)
