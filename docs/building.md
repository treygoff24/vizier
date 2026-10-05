# Building Vizier

Vizier builds on two platforms from one package: the macOS app, and the Linux `vizier` daemon and command. Both use the same `VizierEngine` library.

## What you need

**macOS (the app):**

- macOS 26 or later on Apple Silicon.
- Xcode or the Command Line Tools with Swift 6.2 or later. The package declares `swift-tools-version: 6.2` and `macOS 26` as the deployment target.
- Which SDK you build against decides one thing: the menu bar item. With the macOS 27 SDK (Xcode 27, as releases are built), the app uses the macOS 27 expanded menu bar interface when it runs on macOS 27, which brings menu bar keyboard navigation and menu tracking. With the macOS 26 SDK, that code is left out, and the popover opens from a plain button action on every macOS version.
- Sparkle 2.10.0, which Swift Package Manager fetches.

**Linux (the daemon and CLI):** Swift 6.4, installed with [swiftly](https://www.swift.org/install/linux/). The Linux packages are built for x86_64 only. Docker is needed for `scripts/linux/ci.sh` and the packages.

## Build, test, run

```bash
swift build               # the VizierEngine library and the Vizier executable
swift test                # all tests (Swift Testing)
swift test --filter ConfigStoreTests    # one suite
scripts/build-app.sh      # build/Vizier.app
open build/Vizier.app
```

## Build and test on Linux

Install `libwayland-dev` on the build host for the bundled COSMIC focus reader,
including package builds (Debian/Ubuntu: `sudo apt install libwayland-dev`).

```bash
swift build -c release --product vizier    # .build/release/vizier
scripts/linux/ci.sh                        # build and test in a clean Debian 13 container (needs Docker)
```

`scripts/linux/ci.sh [--filter SUITE]` is what the Linux CI workflow (`.github/workflows/linux.yml`) runs. The Linux checks run on Linux: the macOS app target and its tests build only on a Mac. Swift Package Manager picks the targets for the platform it runs on.

The package has a library, an app executable and a Linux executable, each with its own tests:

| Target | What it is |
|---|---|
| `VizierEngine` | The library: config, capture, transcribers, cleanup, replacements, paste targeting, hotkey logic, take storage. No UI. |
| `Vizier` | The macOS app executable: AppKit and SwiftUI, with `MainActor` as the default isolation. macOS only. |
| `VizierCLI`, `vizier` | The Linux daemon, command and desktop adapters (`Sources/VizierCLI`, entry point in `Sources/vizier-linux`). Linux only. |
| `VizierEngineTests` | Engine tests |
| `VizierTests` | App tests: login item, preferences and Dock, real-data guard, settings, window chrome |
| `VizierCLITests` | Linux daemon, CLI and adapter tests |

Tests use made-up data. Never put your own dictations, audio, vocabulary or replacements into a test. For audio, generate it: `say -o x.aiff "some text"`, then convert with `afconvert` to the format you need.

## What build-app.sh does

`scripts/build-app.sh` builds a release binary and assembles `build/Vizier.app`: it embeds `Sparkle.framework`, copies in `Info.plist`, the icon, the Archivo font and the sound cues, writes the version from the `VERSION` file, and signs the bundle from the inside out.

`VERSION` is the single source for the version: `MARKETING_VERSION` is the version people see, and `BUILD_NUMBER` must only go up, because Sparkle compares it to decide what is newer.

### Signing

| `VIZIER_SIGN_IDENTITY` | Result |
|---|---|
| unset, or `-` | Ad-hoc signature, no hardened runtime. This is the contributor build. It runs on your Mac but never updates itself. |
| A Developer ID name or its SHA-1 | Hardened runtime with a secure timestamp (needs network). The script then verifies the runtime flag on the app, `Sparkle.framework`, `Installer.xpc` and `Updater.app`. |

macOS ties the Microphone and Accessibility grants to the app's bundle id (`net.praxient.dictum`) and signing identity. Keep both stable, or macOS asks again. An ad-hoc rebuild changes the signature each time, so you lose the Accessibility grant after each build; see [troubleshooting](troubleshooting.md).

## Installing your build

`scripts/install.sh` builds, quits any running Vizier, replaces `~/Applications/Vizier.app` with the new build, and relaunches it. It also seeds Keychain keys from `ELEVENLABS_API_KEY` and `GEMINI_API_KEY` when those are set, piping them through `Vizier --store-key` so they are never printed. Run it only if you mean to replace your installed copy; it stops dictation while it runs.

To try a build without disturbing an installed copy on the same account, do not run two full copies of the app at once: both would listen for the same hotkey.

## Linux packages

`scripts/linux/package/` builds the `.deb` and the AppImage inside Docker, on an amd64 Debian 13 host with Swift 6.4:

```bash
scripts/linux/package/build-deb.sh 0.2.0         # vizier_0.2.0_amd64.deb
scripts/linux/package/build-appimage.sh 0.2.0    # Vizier-0.2.0-x86_64.AppImage
scripts/linux/package/test-install.sh 0.2.0      # installs them in clean containers and takes a test dictation
```

The files land in `scripts/linux/package/out/` (ignored by git). [scripts/linux/package/README.md](../scripts/linux/package/README.md) has the dependencies, the clean-install test and the known follow-ups.

## Looking at the UI with made-up data

After `scripts/build-app.sh`, run these from `build/Vizier.app/Contents/MacOS/Vizier`. Both use synthetic data in a folder you name, and both refuse your real Vizier folders.

- `--render-ui <folder>` writes a PNG of every onboarding step and settings pane, then exits.
- `--preview-surfaces <folder> [--open-popover] [--show-strip]` opens the History window, and optionally the popover and the strip with sample words, on invented takes.

`scripts/make-icon.swift` draws the app icon at each size macOS asks for and writes `Resources/Vizier.icns`; run it with `swift scripts/make-icon.swift` only when the icon changes. [DESIGN.md](../DESIGN.md) is the visual design system.

## Making a release

Releases are a maintainer task. `scripts/release.sh` needs:

- `VIZIER_SIGN_IDENTITY`, set to a Developer ID identity.
- A `notarytool` keychain profile. The default name is `dictum-notary` (Vizier was called Dictum until 2026-10-03, and the default profile and key account keep the names they were created under; each `VIZIER_` variable here also falls back to its older `DICTUM_` name); make it with `xcrun notarytool store-credentials`, or name another with `VIZIER_NOTARY_PROFILE`.
- The Sparkle EdDSA private key in the login Keychain under the account `dictum` (`VIZIER_SPARKLE_ACCOUNT` overrides it), created with Sparkle's `generate_keys --account dictum`. The matching public key is `SUPublicEDKey` in `Info.plist`.

It then:

1. builds and signs the app;
2. builds a DMG with an Applications shortcut (volume name `Vizier`) and signs it;
3. submits it for notarization and requires `Accepted`;
4. staples the ticket and validates it, and assesses both the DMG and the app inside with `spctl`;
5. signs the DMG with Sparkle's `sign_update` and writes an appcast entry whose URL is `<releases>/download/v<version>/Vizier-<version>.dmg`, derived from `SUFeedURL`, with `minimumSystemVersion` taken from `Info.plist`.

The outputs are `build/Vizier-<version>.dmg` and `build/appcast.xml`. `--skip-notarize` produces files marked `-NOT-NOTARIZED` for testing the pipeline; do not release those. The script publishes nothing: uploading the DMG and appcast to GitHub Releases is a separate, deliberate step. The updater reads `https://github.com/treygoff24/vizier/releases/latest/download/appcast.xml`, so the appcast must be attached to the latest release.

The Linux `.deb` and AppImage are built separately (above) and attached to the same GitHub release as the DMG. The Sparkle appcast is Mac-only; Linux users download new packages from the release page.
