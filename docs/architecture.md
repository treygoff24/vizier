# Architecture

Vizier is one engine with two front ends. `VizierEngine` is a library with no UI that builds on macOS and Linux: everything that decides what a take does, including the take's state machine, `TakeSession`. `Vizier` is the macOS menu bar app; it wires the engine to the keyboard, the microphone, the screen and the pasteboard. On Linux, `VizierCLI` (the `vizier` daemon and command) drives the same engine through its own adapters. Keeping the engine free of UI is what makes most of it testable without a window; see [building](building.md) for the test targets.

## The life of a take

A take moves through four phases (`idle`, `arming`, `recording`, `finalizing`) held by `TakeSession` in `VizierEngine/Session/`. It talks to the platform only through small protocols declared in `Session/Contracts.swift` (`TakePresentation`, `SoundPlayer`, `MicPermission`, `FocusProbe`, `PasteService`, and `AudioCapture` for the microphone) plus a table of platform wording, `TakeRemarks`. On the Mac, `TakeController` is a thin façade that builds a `TakeSession` with the app's adapters (`Sources/Vizier/Session/TakeAdapters.swift`). On Linux, the daemon in `Sources/VizierCLI` builds one with the Linux adapters and exposes it to `vizier toggle`, `vizier cancel` and the other commands. The steps below are the Mac's; the Linux front end differs at steps 1, 3 and 7 (a portal shortcut or a compositor bind running `vizier toggle`; `pw-record` capture; clipboard and paste-key tools per desktop). See [Vizier on Linux](linux.md).

1. **Hotkey.** `ShortcutMonitor` installs a macOS event tap (it needs Accessibility). It reports a press of the chosen right-hand modifier, Escape, and a typed Cmd+V. `RecordingShortcutManager` turns a press into a toggle: the first starts a take, the next stops it. `EscapeGate` decides whether an Escape cancels a take and swallows the repeats. `UserSessionInputPolicy` ignores all of it on a locked screen or a non-console session. The modifier choices are defined by `HotkeyModifier` in `VizierEngine/Hotkey/RightCommandKey.swift`.
2. **Config.** `ConfigStore` re-reads `vizier.jsonc`, `vocabulary.txt` and `replacements.txt` for each take and validates them. A file that fails validation never replaces the last good config; the store reports the error and the alert lights. `VizierConfig` defines the file's types and the validation rules.
3. **Capture.** `HALCapture` records from the system default input through Core Audio, follows a change of default device without ending the take, and hands samples to `TakeRecorder`. `TakeRecorder` writes every sample to a recording file on disk first, then sends 100 ms chunks to the live transcriber, so a failing engine never costs the audio. `LevelMeter` turns the buffers into the lamp's level.
4. **Live transcription.** A `LiveTranscriber` adapter streams the audio to the engine the mode names (`AppleSpeechTranscriber`, `ScribeRealtimeTranscriber`, `GeminiLiveTranscriber`) and reports words as they arrive. `WordLine` decides which words count as settled for the strip. A batch-only mode skips this stage.
5. **Stop.** On the second tap the recorder closes the file and the session waits up to `final_timeout_ms` for the live final. The audio is encoded to FLAC and verified by `TakeStore`. If the final is late, or the stream broke, the saved audio goes down the **batch chain** in `Engines.swift`: the batch transcribers the mode lists (its own, if batch-only, then `fallback`, then `offline_fallback`), stopping at the first that answers. A cloud link with no key is skipped.
6. **Text pipeline.** The transcript passes through `TextCleanup` (the model pass, with its safety checks), then `FillerFilter`, then `WordReplacer`, in that order. A failure in cleanup falls back to the raw text, never to nothing.
7. **Paste.** `Paster` puts the text on the pasteboard and posts Cmd+V, unless `PasteTarget` or the session decides the paste has nowhere safe to land, in which case the text is held on the clipboard with a remark.
8. **Record.** `TakeLedger` writes the row to `HistoryStore` at every stage, so text that exists is on disk before a cancel or crash can lose it. A store error is logged without transcript text and never fails the take.

The strip and the menu bar glyph observe the session through the presentation adapter; they never decide anything.

## Where things are

### `Sources/VizierEngine/`

| Folder | Contents |
|---|---|
| `Config/` | `VizierConfig` (types, validation, the starter file, `ConfigStore`), `Engines` (builds batch transcribers and cleanup from a mode), `SettingsEditor` (rewrites one top-level string in `vizier.jsonc` and leaves every other byte alone) |
| `Capture/` | The `AudioCapture` protocol; `HALCapture` and its adapter (Core Audio, macOS); `PipeCapture` (a recorder process, Linux) |
| `Audio/` | WAV and FLAC files written in plain Swift, for Linux takes |
| `Session/` | `TakeSession` (the take state machine), the contracts it uses, `TakeRemarks` (wording per platform) |
| `Platform/` | Paths, system locale and a logger shim, per platform |
| `Transcription/` | One file per engine adapter: Apple, Scribe, Gemini, local Whisper, plus the Gemini Live message codec and session state |
| `Cleanup/` | `TextCleanup` (safety checks), `GeminiCleanup`, `LocalCleanup`, `FillerFilter` |
| `Replacements/` | `ReplacementsFile` (parse and validate), `WordReplacer` (match and substitute) |
| `Hotkey/` | `RightCommandKey` (the modifier choices), `EscapeGate` |
| `Indicator/` | `LevelMeter`, `WordLine`: the logic behind the lamp and the strip's words |
| `Paste/` | `PasteTarget`, `PasteText`, `TypedPasteWatch` |
| `Secrets/` | `SecretStore`; `Keychain` (macOS) |
| `Takes/` | `TakeRecorder`, `TakeStore`, `TakeLedger`, `HistoryStore` (SQLite), `HistoryBoard`, `Rerun`, `VoiceInkImport`, `Waveform` |
| `UpdateEligibility.swift` | Decides whether the updater may run |

### `Sources/VizierCLI/` and `Sources/vizier-linux/` (Linux)

| Path | Contents |
|---|---|
| `Sources/vizier-linux/` | The `vizier` executable's entry point |
| `CLI.swift`, `Commands.swift`, `Protocol.swift`, `Socket.swift` | The command line and the private socket between it and the daemon |
| `Daemon.swift`, `LinuxRuntime.swift` | The daemon: builds the engine's `TakeSession` with the Linux adapters |
| `Setup.swift`, `Key.swift` | `vizier setup` and `vizier key` |
| `Adapters/` | Desktop detection, helper-process runner, the portal clients (global shortcuts, remote desktop), wlroots and X11 paste, notifications, sounds, secrets |

### `Sources/Vizier/` (macOS)

| Path | Contents |
|---|---|
| `VizierApp.swift` | Entry point; also dispatches the one-shot command-line flags |
| `TakeController.swift` | A thin façade over the engine's `TakeSession`, built with the Mac's adapters |
| `Session/` | The adapters: strip presentation, sound cues, microphone permission, focus probe, paste |
| `Hotkey/` | The event tap, the toggle, the session guard (adapted from VoiceInk) |
| `Paste/Paster.swift` | The pasteboard and the keystroke (adapted from VoiceInk) |
| `Strip/` | The borderless, non-activating recording strip |
| `Surfaces/` | The popover and the History window and its model |
| `Onboarding/`, `Settings/` | The setup guide and the Settings window |
| `Services/` | Accounts and keys, permissions, speech-model download, update checking |
| `StatusItemController.swift`, `StatusGlyph.swift` | The menu bar item and its animated glyph |
| `Updater.swift` | The Sparkle wrapper |
| `AppPreferences.swift`, `LoginItem.swift`, `DockPolicy.swift` | Preferences, Open at Login, the Dock-icon rule |
| `Sounds.swift` | The four sound cues |
| `RealDataGuard.swift` | Makes preview and render commands refuse real data folders |
| `*Command.swift`, `Preview.swift` | The command-line flags |
| `Board.swift`, `AppShell.swift` | Shared visual tokens and window chrome ([DESIGN.md](../DESIGN.md)) |

## Design choices worth knowing

- **Audio before anything else.** Samples hit the disk before they are streamed, and the FLAC is verified before the recording file is dropped. A crash leaves the recording, which is recovered at the next launch. Whatever an engine does, the audio survives.
- **No hidden state in the config.** The file is the source of truth and is re-read for every take. Switching the mode from the popover edits one string in place instead of re-serializing the file, so comments survive.
- **Cleanup is a guest.** The model's output is checked against the transcript and discarded when it looks rewritten.
- **Local means loopback.** The config validator only accepts local engines on a numeric loopback address (`127.0.0.1` or `::1`; `localhost` is refused).
- **Privacy is enforced in code.** Transcript text is logged only with private markers, and the preview commands refuse real data folders.
- **One state machine, two platforms.** `TakeSession` has no AppKit and no Linux code. The Mac's behavior is the original `TakeController`'s, moved into the engine; Mac and Linux differ only in their adapters and wording.
- **Hotkey is a toggle.** A take starts on the key-down of the modifier and the next key-down stops it; there is no hold-to-talk path and no chord check.
- **Updates need a real signature.** `UpdateEligibility` allows Sparkle to run only in an `.app` with a valid signature that carries a team identifier.

For a guide to working in the repository, see [agents](agents.md).
