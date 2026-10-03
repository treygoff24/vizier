# Using Vizier

## Taking a dictation

1. Put the cursor where you want the text, in any app.
2. Tap the hotkey. Vizier starts listening and shows the strip.
3. Talk.
4. Tap the hotkey again. Vizier finishes the transcript and pastes it at the cursor.

It is tap to start and tap to stop, not hold to talk. A take starts the moment the key goes down and the next key-down stops it; Vizier does not wait for the key to come back up.

The pasted text has one trailing space after it, so you can keep typing or start the next take. It is put on the clipboard and stays there afterwards; Vizier does not restore what the clipboard held before.

Press **Escape** to cancel a take that is recording or finishing. Nothing is pasted, and the take is kept in History as Cancelled. That Escape is swallowed and so is any further Escape during the next second, so a double tap does not reach the app underneath. At any other time Escape goes through to the app as normal.

Batch transcription (used by batch-only modes and by every fallback) has a one-hour limit; a longer take is saved but not sent to batch.

### The hotkey

The default is Right Command. Right Option and Right Control are the alternatives; most laptop keyboards have no Right Control. Choose in the setup guide or in Settings › General. The key is watched through an event tap, which needs Accessibility access. Vizier ignores the hotkey while the screen is locked or the session is not the one at the console.

If a take starts or ends with the wrong key, check that no other dictation or key-remapping app is listening to the same key.

### Sounds

Short cues play when a take starts (on the first real audio), stops, is cancelled, or runs into a problem. Settings › General has a Sounds switch.

### Which microphone

Vizier records from the system's default input device and follows it if you change it in the middle of a take. The menu bar popover shows the current input's name.

## The strip

While a take is running, a small panel appears near the bottom of the screen the mouse is on. It never takes focus and ignores the mouse, so it does not interfere with the app you are dictating into.

It shows:

- a lamp that follows the microphone level
- the app that will receive the text, in capitals
- the time recorded so far
- a two-letter code for the mode (initials of its name: AP for Apple, SC for Scribe, GC for Gemini Clean, GS for Gemini SMART)
- the words heard so far, with the settled ones set apart from those still changing
- a status

| Status | Meaning |
|---|---|
| PASTED | The text went into the app |
| RE-ROUTED | A fallback produced it; the second line says via batch or raw text |
| HELD | The text was not pasted and is on the clipboard |
| FAILED | Nothing usable came out; the audio is saved |
| CANCELLED | You pressed Escape |
| DELAYED +n.n S | Finishing is taking longer than usual |
| BATCH, SAVED AUDIO | The mode transcribes after you stop, or the live words are unavailable |

A short line under the status says why when something went differently, in a plain sentence. [Troubleshooting](troubleshooting.md#what-the-strip-says) lists them.

## The menu bar popover

Click the menu bar icon. While recording, the icon shows an amber lamp; a red square marks a failed or held take until you open the popover. The popover does not open during a take, and closes if a take starts while it is open.

- **Modes.** The active one is tagged with the hotkey. Click another to switch. Vizier changes only the `mode` line of `vizier.jsonc`, leaving your comments alone. It will not do this if the file is broken or has changed on disk since it was read; fix the file first.
- **Recent takes.** The last six: time, destination app, mode code, word count and status. Click a row to open it in History; the copy button copies its text.
- **Alert.** After a held or failed take, a banner with Copy and Open.
- **Facts.** Mic (the input device), Engine (the last engine answer), Today (takes, words, median seconds after stop).
- **Buttons.** History, Re-run, Settings, Quit.
- **Links.** Setup guide and Check for updates.

There is no Quit in the main menu, so Cmd+Q in the History window does not stop dictation. Quit from the popover.

## History

Open History from the popover. It lists every take, grouped by day, with time, destination, mode code, words, status and text.

- Search with the box at the top, or press `/` in the list.
- Filter All, Problems (re-routed, held, failed) or Cancelled.
- Arrow keys move; Space plays or stops the take's audio; Cmd+C copies its text.
- The detail pane shows the clock time, status, destination, mode, words, length, time after stop, which engine answered, the audio size, a waveform, and the text as pasted. When a cleanup or filler pass changed it, the raw transcript is shown too. A reason sentence explains a re-routed, held or failed take.

Opening the window makes Vizier the frontmost app. A take that finishes while Vizier has focus is held on the clipboard, since there is nowhere to paste it.

Every take's audio is kept, including cancelled ones. There is no delete button; to free space, remove files yourself (see [privacy](privacy.md#what-is-stored-on-your-mac)).

### Re-run

Re-run sends a take's saved audio through a mode again, which is useful after you fix your vocabulary, or to compare modes. It needs a finished take with its audio on disk and a mode with a batch transcriber (the button is disabled for a mode that has none). It runs that mode's batch chain, then its cleanup, filler removal and replacements. The result goes on the clipboard; it is never pasted. It is stored as a numbered attempt under the take, and the original is not changed.

## Settings

- **General.** Hotkey, Open at Login, Show in Dock, Sounds.
- **Transcription.** Choose the active mode. Shows the Apple speech model's status, with a Download button.
- **Accounts.** ElevenLabs and Gemini key fields. Save stores the key in the Keychain. Test key makes a harmless read-only request to the provider (no charge) and tells you if the key works. A saved key is never shown again.
- **Words.** Open `vocabulary.txt` and `replacements.txt` in your editor. Changes apply from the next take. See [vocabulary and replacements](vocabulary-and-replacements.md).
- **About.** Version, license, credits, Check for updates, the setup guide.

## Command-line flags

The app binary, `Vizier.app/Contents/MacOS/Vizier`, has flags that run once and exit before the app starts up, so they do not touch a running Vizier's hotkey or windows. Run them from a terminal; each prints what it did and exits non-zero on failure.

| Flag | What it does |
|---|---|
| `--version` | Prints the version, the build number, and whether the updater is eligible or off. |
| `--store-key <account>` | Saves an API key to the Keychain. The account is `elevenlabs` or `gemini`. The key must arrive on standard input (`printf '%s' "$KEY" \| Vizier --store-key gemini`); the command refuses to read from a terminal and never prints the key. |
| `--install-apple-model [locale]` | Downloads Apple's speech model for the locale (default `en-US`), printing progress. The setup guide does the same. |
| `--transcribe-apple <file> [locale]` | Transcribes one audio file with Apple's on-device recognizer and prints the transcript to standard output, with the engine, seconds and word count. It ignores the active mode and uses no other engine. It needs the speech model installed. See [privacy](privacy.md#command-line-output). |
| `--import-voiceink [--dry-run] [--no-audio]` | Imports takes from VoiceInk's history (`~/Library/Application Support/com.prakashjoshipax.VoiceInk/default.store`) into Vizier's History. VoiceInk's files are only read; the one exception is that SQLite may create an empty `default.store-shm` sidecar file next to the VoiceInk database when it opens it, even on a `--dry-run`. Each import becomes a finished take with its text, times and models, and its recordings are converted to FLAC so Re-run works on them; `--no-audio` skips the recordings. Takes already imported are skipped, so it is safe to run again, and safe while Vizier runs. `--dry-run` imports nothing and reports how many takes are new and how much audio they hold. |
| `--render-ui <folder>` | Developer tool. Writes a PNG of every onboarding step and settings pane to the folder, using made-up data, and exits. |
| `--preview-surfaces <folder> [--open-popover] [--show-strip] [--show-rerun]` | Developer tool. Opens the History window on invented takes in the folder, and optionally the popover, the strip with sample words, or a take with its Re-run attempts. It installs no hotkey and records nothing. |

`--render-ui` and `--preview-surfaces` refuse to use your real Vizier folders. For their use in development, see [building](building.md#looking-at-the-ui-with-made-up-data).
