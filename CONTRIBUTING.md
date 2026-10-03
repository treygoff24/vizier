# Contributing

Vizier is a native macOS app written in Swift. It needs macOS 26 or later on Apple Silicon, and Xcode 26 or later (Swift 6.2+) to build.

## Build and test

```bash
swift build                # the engine library and the app target
swift test                 # the unit tests (Swift Testing)
scripts/build-app.sh       # builds build/Vizier.app, signed ad hoc by default
scripts/test-release-checks.sh  # tests for the release script's checks (not part of swift test)
```

Run the tests that cover what you changed while you work, and the full suite before you open a pull request.
Do not run `scripts/install.sh` unless you mean to replace your own installed copy: it quits and relaunches Vizier.

## Looking at the UI without the installed app

Run these from `build/Vizier.app/Contents/MacOS/Vizier` after `scripts/build-app.sh`. Both use synthetic data in a folder you name and refuse your real Vizier folders:

- `--render-ui <folder>` writes a PNG of every onboarding step and settings pane, then exits.
- `--preview-surfaces <folder> [--open-popover] [--show-strip]` opens the History window (and the popover, and the recording strip with sample words) on made-up takes.

## Rules

- **No real transcripts.** Never put your own dictations, audio, vocabulary, or word replacements in a commit, test, issue, or log. Test audio is synthetic: `say -o x.aiff "some text"`, then `afconvert` to the format you need. Logs never contain transcript text.
- **Prove new tests by breaking the code.** A new test counts only once you have broken the code it guards, watched the test fail, and restored the code. Say which change you used in the pull request.
- **Keep changes small and explain why** in the commit message. A subject line of 72 characters or fewer, then a blank line, then the reason.

## Reporting bugs and requesting features

Use the [issue forms](https://github.com/treygoff24/vizier/issues/new/choose); blank issues are off. [SUPPORT.md](SUPPORT.md) says where questions go, what is in scope, and how to collect diagnostics. Search existing issues first. Never include dictated text, audio, API keys or personal paths. For a security vulnerability, use private vulnerability reporting ([SECURITY.md](SECURITY.md)), not an issue.

Open an issue before a pull request for anything larger than a small fix, and wait for a reply. The [pull request template](.github/PULL_REQUEST_TEMPLATE.md) lists what a PR must show: the exact `swift test` command and count, a mutation for every new test, and the privacy check.

Everyone, including AI agents and the people who run them, follows the [Code of Conduct](CODE_OF_CONDUCT.md). AI-assisted issues and pull requests are welcome when a person stands behind them and the disclosure fields say what the AI did.

## Forking

A fork that ships its own builds must not reuse the project's identity. Before you distribute one, change:

- **The update feed and key.** `SUFeedURL` and `SUPublicEDKey` in `Resources/Info.plist`. The public key must match a Sparkle EdDSA private key you hold (`generate_keys`), and the feed must be one you publish. Left as they are, your builds would look for updates from this project, and could not verify yours.
- **The bundle id**, `net.praxient.dictum`: `CFBundleIdentifier` in `Resources/Info.plist`, the Keychain service in `Sources/VizierEngine/Secrets/Keychain.swift`, the launch-agent labels (`net.praxient.dictum.whisper` and `.cleanup`) in `scripts/local-models.sh` and `Sources/Vizier/LocalModels.swift`, and the logging subsystem. Search the repository for `net.praxient.dictum` to find every use. A different bundle id also means a different preferences domain, so macOS treats the fork as a new app and asks for Microphone and Accessibility again.
- **The signing identity.** Sign with your own Developer ID Application certificate (`VIZIER_SIGN_IDENTITY`), notarize with your own `notarytool` profile, and keep the identity stable between releases.
- **Release URLs and docs.** The GitHub release links in the README and docs.

Vizier is GPL-3.0-only, so your fork stays under it and keeps the attributions in `NOTICE` and the VoiceInk file headers. See [docs/building.md](docs/building.md#making-a-release) for the release steps.

## Licensing

Vizier is GPL-3.0-only, because it includes code adapted from VoiceInk, which is GPLv3. By contributing you agree your work is released under the same license.
