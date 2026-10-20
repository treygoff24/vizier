# Changelog

Notable changes to Vizier, newest first. Versions follow `VERSION`.

## Unreleased

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
