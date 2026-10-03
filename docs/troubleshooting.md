# Troubleshooting

This page is about the Mac app. On Linux, run `vizier doctor` and see the troubleshooting section of [Vizier on Linux](linux.md#troubleshooting).

Whenever a take does not go as expected, it is still in History with its audio, and its detail pane gives a reason. The text of a held take is on the clipboard.

## Common problems

**The hotkey does nothing, or paste stops working after a rebuild.**
Vizier needs Accessibility access to see the hotkey and to paste. A copy you build yourself is signed ad hoc, and each ad-hoc build gets a new signature, so macOS drops the grant. In System Settings › Privacy & Security › Accessibility, remove Vizier and add it again. Released DMG builds are signed and keep the grant. The setup guide's Accessibility step shows a hint for this.

**Vizier says another copy is already running, and quits.**
Only one copy can run at a time, and Dictum (Vizier's name until October 2026) counts. The message names the other copy. Quit it from its menu bar icon, then open Vizier again. Vizier never quits the other copy itself, since it may be in the middle of a take.

**Vizier says it could not move your Dictum data, and quits.**
On its first launch Vizier renames `~/Library/Application Support/Dictum` to `…/Vizier`, `~/.config/dictum` to `~/.config/vizier`, and `dictum.jsonc` to `vizier.jsonc`. When a rename fails, or both the old and the new one already exist, Vizier stops without changing anything, and the message names the folders. Keep the one you want at the new name and move the other out of the way, or fix the permission the message names, then open Vizier again; it tries the move on every launch.

**The hotkey does nothing while the screen is locked or in another login session.**
That is intended: Vizier ignores the hotkey when the screen is locked or the session is not the one at the console.

**Apple mode transcribes nothing.**
Apple's speech model is a one-time download for your language. The setup guide's Speech model step does it; Settings › Transcription has a Download button if you skipped it or it failed. Until it is installed, Apple mode and the Apple fallbacks cannot transcribe. The audio is saved, and Re-run can transcribe it later.

**Settings shows Unsupported for the speech model.**
Apple's on-device speech does not cover the active mode's language (your system language, unless you changed the mode's `languages`). The Apple mode cannot transcribe it, and Apple-mode takes fail with their audio kept. Add a Scribe or Gemini key under Accounts and choose that mode under Transcription; the setup guide notes the same. See [Languages](modes-and-config.md#languages).

**Nothing is pasted.**
Check that Vizier has Accessibility access and that a text field has focus in an app that accepts pasted text. The text is on the clipboard; Cmd+V pastes it.

**The text pastes twice, or the wrong key is used.**
Another dictation or key-remapping app may be listening to the same key. Quit it, or pick a different hotkey in Settings › General.

**A cloud mode produces nothing.**
It needs its key in Settings › Accounts. Without one, Vizier skips that link and uses the fallbacks the mode still has, and finishes with Apple's recognizer if its model is installed. Use Test key to check a key.

**The microphone is the wrong one, or "the mic never delivered audio".**
Vizier records from the macOS default input device. Choose the input in System Settings › Sound. Vizier follows a change of default input during a take.

**Pasting works in some keyboard layouts and not others.**
Vizier pastes by sending Cmd+V. If your layout (for example Dvorak or Colemak) does not put V where Vizier expects it, it pastes through System Events instead, and macOS asks once for permission to control System Events. Allow it under Privacy & Security › Automation.

**Words are wrong.**
Add them to `vocabulary.txt` (cloud modes only) or fix them after the fact in `replacements.txt`. See [vocabulary and replacements](vocabulary-and-replacements.md).

**Vizier says my config is broken.**
A syntax or validation error in `vizier.jsonc` lights the alert and Vizier keeps running the last good config. Fix the file; the next take picks it up. A bad `replacements.txt` is reported with a line number (`replacements.txt line N`) and the last good rules keep running. [Modes and configuration](modes-and-config.md) lists what is checked.

**A mode you edited does not show up.**
The `mode` value must match the `id` of one of the `modes`. Also, the file must be valid JSON5.

## What the strip says

Statuses are PASTED, RE-ROUTED, HELD, FAILED, CANCELLED, DELAYED and BATCH (see [using Vizier](using.md#the-strip)). The line beneath gives a one-sentence reason. These are the ones that need a response:

| Message | What it means and what to do |
|---|---|
| The live stream dropped. Audio is still recording and will go through batch when you stop. | The connection broke mid-take. Keep going; the saved audio is transcribed at the stop. |
| The live transcript did not finish in time, so the saved audio went through batch. | The engine was slow past the mode's `final_timeout_ms`. The text is still produced. |
| The engine could not be reached. The audio is saved. | No network or the provider is down. Re-run the take later. |
| The cloud could not be reached, so this Mac transcribed the saved audio. | The offline fallback was used. |
| There is no … key yet, so nothing was transcribed. | Add the key in Settings › Accounts. The audio is saved. |
| The Apple speech model is not ready yet … | Download it in Settings › Transcription. |
| No speech came through. | Nothing audible was heard. |
| The mic never delivered audio. / The mic could not start. Check the input device. | Check the input device and the Microphone permission. |
| Local whisper did not answer. Is its server running? | See [Local Whisper](modes-and-config.md#local-whisper-experimental). |
| The paste did not go through / No text field had focus / Vizier itself had focus / You switched apps after the take stopped | Nothing was pasted. The text is on the clipboard, unless the message says it is saved in History instead (the clipboard write failed). |
| The cleanup pass did not finish in time / failed / dropped too many words / added words | The raw transcript was pasted instead of the cleaned one. |
| The live transcript did not finish, so the settled words were pasted. | The text may be missing its last words. |
| The take is longer than the batch model's one-hour limit | The audio is saved, not transcribed. |
| The batch transcript hit the model's output limit / may contain repeated text | Review the text; it may be cut off or contain a loop. |

## Where to look

- **History.** The take's detail pane has the reason sentence, the raw transcript and the audio.
- **Logs.** Vizier logs through macOS's unified logging under the subsystem `net.praxient.dictum`. Transcript text, provider text, vocabulary and settings values are marked private and never appear in plain logs. Open Console and filter on the subsystem. Only the optional local cleanup server writes a file, `~/Library/Logs/Vizier/cleanup.log`.
- **`Vizier --version`.** Shows the version, the build number, and whether the updater is eligible.

## Reporting a bug

Open an issue on the GitHub repository. Do not paste your transcripts, audio, vocabulary or replacements. For a security problem, follow [SECURITY.md](../SECURITY.md).
