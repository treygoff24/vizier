# Changelog

Notable changes to Vizier, newest first. Versions follow `VERSION`.

## Unreleased

## 0.4.0 (2026-11-20)

Scribe v3 Live with a much larger vocabulary, and a round of fixes to pasting, recovery and privacy on both platforms. The release page carries the notarized Mac DMG (with its Sparkle update) and the Linux `.deb` and AppImage.

### Added

- **Scribe v3 Live** (`scribe_v3_live`) is the starter Scribe mode. Vizier sends the first 50 vocabulary terms of 20 characters or fewer as key terms, as before, and the remaining terms of 50 characters or fewer as a keyterm library, which the model consults when it hears a likely match. A long vocabulary is no longer cut off at 50 terms. Existing settings that name Scribe v2 Realtime keep using it; change `model` in the mode to switch.
- Settings › Words shows which vocabulary terms the active mode's primary recognizer leaves out.
- On Linux, the desktop notification explains when a recording was interrupted, even if Vizier switches to batch transcription.

### Changed

- If the microphone stops unexpectedly or a recording cannot be fully saved, Vizier stops the take, explains what happened, and keeps any recovered text in History without pasting it.
- If another app changes the clipboard before Vizier can paste, Vizier skips the paste and keeps the transcript in History.
- Errors from transcription and cleanup providers report the HTTP status and any recognized error name. Text echoed by a provider, which can include your vocabulary or words from a take, no longer reaches diagnostic logs or benchmark results.
- Onboarding practice appears in History as practice, with no paste destination or time.
- The strip does less drawing while you dictate, which lowers the load on the Mac's window server.
- Updated the Mac updater to Sparkle 2.10.1, which fixes release note links and updates stored at paths with certain Unicode characters.

### Fixed

- Switching transcription modes works even if the vocabulary or replacements file has an error. Each broken or unreadable file keeps its own last good values, so a take can no longer go to the previously selected provider.
- A practice take stays in onboarding and History if the guide closes while it is running, and an ordinary take is not swallowed if the guide opens while it is transcribing.
- Apple speech model status follows the active mode's language, even if you switch modes during a download.
- The startup alert for an incomplete Dictum migration explains that completed moves are kept and existing files and folders are left alone.
- Scribe skips vocabulary terms made of too many Unicode characters even when those characters combine into a single symbol onscreen.
- Settings reports an invalid local server port instead of letting it reach the server check in Linux setup or doctor.
- Linux builds on arm64 again: the process capture shim no longer imports conflicting definitions of libc types.
- On Linux, `vizier doctor` accepts an older libcurl for batch modes, including local Whisper on Ubuntu 24.04. It warns if a different mode needs live transcription, and fails if the active mode needs it.
- On Linux, cancelling a dictation while Vizier checks the clipboard or focused app stops it from sending the paste shortcut.
- On Linux, Vizier waits for portal key release requests before finishing a paste or closing the portal session.
- On Linux, rotating a key held in a locked keyring asks you to unlock it instead of saving a copy that the old key would override.

## 0.3.0 (2026-10-20)

Two new live cloud engines on the Mac, a faster stop for Scribe, macOS 26 support, and Pop!_OS COSMIC support on Linux. The release page carries the notarized Mac DMG (with its Sparkle update) and the Linux `.deb` and AppImage.

### Added

- **Soniox live engine** (`soniox-realtime`, model `stt-rt-v5`). It streams audio as you speak, sends your vocabulary as context terms (up to 8,000 characters) and your languages as hints, and finishes at the stop with a short tail of silence. Verbatim only. Its key is the Keychain account `soniox`.
- **AssemblyAI live engine** (`assemblyai-realtime`, Universal-3.6 Pro streaming, model `universal-3-6-pro`). Vocabulary goes as key terms (the first 100 of 50 characters or fewer); at the stop Vizier forces the end of the turn and finishes on it. Verbatim only. Its key is the Keychain account `assemblyai`.
- Both new engines are Mac only for now, and neither is in the starter file: store the key with `printf '%s' "$KEY" | Vizier --store-key soniox` (or `assemblyai`) and add a mode, as [docs/modes-and-config.md](docs/modes-and-config.md#soniox-and-assemblyai) shows. The popover, Settings and History name them.
- **macOS 26.** Vizier runs on macOS 26 as well as 27 (contributed by Matt Mascolo). On macOS 26 the menu bar item opens the popover with a plain click; on macOS 27 it keeps the system's expanded menu bar interface. The app builds with either the macOS 27 SDK (Xcode 27, as releases are) or the macOS 26 SDK.
- **Pop!_OS COSMIC on Linux** (contributed by Matt Mascolo). On COSMIC, Vizier pastes with `wl-copy` and `ydotool`, using Ctrl+Shift+V in known terminals, and reads the focused app through a small native helper built into the `vizier` binary. `vizier setup --autostart` installs and starts a private `ydotoold` input service, prints the two commands to bind as COSMIC shortcuts, and warns that text stays on the clipboard until the input socket is live. See [docs/linux.md](docs/linux.md#pop_os-cosmic).
- **Live-engine bench, for developers.** `Vizier --bench-live` replays recorded clips through live engines at real-time pace and times each stop; `Vizier --bench-judge` has a Gemini model write reference transcripts; `scripts/bench/score.py` prints error rates and latencies, never text. See [docs/using.md](docs/using.md#command-line-flags).

### Changed

- **Scribe Realtime finishes faster.** While you talk, Vizier now prepares the repair of the last stretch of audio, so at the stop it rarely has to replay audio before pasting. On 150 real takes the slowest tenth of stops went from about 750 ms to about 150 ms, with accuracy essentially unchanged. A preparation that stalls or fails falls back to the old repair at the stop.
- On Linux, a nonzero exit from `xdotool`, `wtype` or `ydotool` now reports a failed paste (`failed-key-helper`) instead of success. Before, a helper that ran but failed left the take marked as pasted.
- On Linux, Secret Service calls (`secret-tool`) run on the calling thread instead of Swift's shared thread pool, so a busy pool can no longer stall a key lookup.
- `scripts/install.sh` stops only the installed copy of the app, matched by its path, instead of every process named Vizier.

## 0.2.0 (2026-10-03)

Linux support, released together with the macOS app. The release page carries the notarized Mac DMG (with its Sparkle update) and the Linux `.deb` and AppImage.

### Added

- **Linux.** A background daemon and the `vizier` command (`vizier setup`, `toggle`, `cancel`, `status`, `last`, `history`, `config`, `key`, `doctor`). Packages for x86_64: `vizier_0.2.0_amd64.deb` and `Vizier-0.2.0-x86_64.AppImage`. The hotkey is a desktop-portal shortcut (GNOME 48+, KDE, Hyprland) or a compositor bind; pasting uses the desktop portal, `wtype` or `xdotool`. The default mode is `local`, a whisper.cpp server on your own machine; ElevenLabs and Gemini work with your keys. It was tested end to end on X11 and headless Sway; the GNOME and KDE portal flows were tested against a mock, not a real session. See [docs/linux.md](docs/linux.md) and [docs/cli.md](docs/cli.md).
- A Linux CI script, `scripts/linux/ci.sh`, and a GitHub Actions workflow that runs it.

### Changed

- The take state machine moved from the Mac app's `TakeController` into `VizierEngine` as `TakeSession`, so the Mac app and the Linux daemon run the same code. The Mac app keeps a thin façade and its own adapters for the strip, sounds, microphone permission, focus and paste. Mac behavior is unchanged.
- When the clipboard write fails, the take's remark no longer says the text is on the clipboard; it says the text is saved in History.

## 0.1.0 (2026-10-03)

First public release: the macOS menu-bar dictation app. Tap a hotkey, talk, tap again, and the cleaned text is pasted at the cursor. On-device Apple speech by default, optional ElevenLabs Scribe and Google Gemini modes, a History window that keeps every take with its audio, vocabulary and replacements, and Sparkle updates. Released as a notarized DMG on 2026-10-03.
