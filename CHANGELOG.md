# Changelog

Notable changes to Vizier, newest first. Versions follow `VERSION`.

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
