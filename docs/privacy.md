# Privacy

Vizier records your voice, so here is exactly where it goes. The short version: the default mode keeps everything on your Mac, the cloud modes send audio to the provider you chose, and Vizier does not write what you say to logs.

## What leaves your Mac, by mode

| Mode | What is sent, and to whom |
|---|---|
| **Apple** (default) | Nothing. Recognition runs on your Mac, using a model Apple downloads once. |
| **Scribe** | Your audio, streamed live to ElevenLabs, along with your vocabulary terms as recognition hints. If the live stream fails or is late and a Gemini key is saved, Vizier sends the saved audio and the vocabulary to Google Gemini for a batch transcript. The final fallback, Apple's recognizer on the saved audio, stays on your Mac. |
| **Gemini Clean** | Your audio, streamed live to Google, with your vocabulary terms. After transcription, the transcript text, your vocabulary, your replacement mappings (heard word and intended word) and the language names are sent to a Google model to tidy the text. |
| **Gemini SMART** | Your audio, streamed live to Google, with your vocabulary terms. If the stream fails, the saved audio and vocabulary go to Gemini in batch. |
| **Local Whisper** (experimental, off by default) | Audio goes to a server on your own Mac, over the loopback address only. Vizier refuses a non-local address for local engines. |

Gemini batch requests are made with storage turned off; audio larger than 14.5 MB is uploaded through Google's Files API and deleted afterwards (Google also deletes uploads after 48 hours). What a provider does with what it receives is set by its terms, below. If that matters to you, use Apple mode.

### Provider terms

When you add your own API key, you become that provider's customer and are bound by its terms; Vizier is not a party to them. The summary below was checked against the providers' pages on 2026-10-02. Terms change, so read the current ones before you rely on this.

- **Google Gemini** ([Gemini API Additional Terms](https://ai.google.dev/gemini-api/terms)). On the unpaid tier, Google may use the content you submit and the responses to improve its products and machine learning, and human reviewers may read and annotate them (with the data disconnected from your account, key and project first). The terms say not to submit sensitive, confidential or personal information to unpaid services. On the paid tier (a Cloud project with active billing), Google does not use prompts or responses to improve its products, and keeps logs for a limited time to detect abuse. The terms also say that when you make an API client available to users in the European Economic Area, Switzerland or the United Kingdom, you may use only paid services. Which tier applies depends on your key and its project, not on Vizier.
- **ElevenLabs** ([Terms of Use](https://elevenlabs.io/terms-of-use)). ElevenLabs may use your content to provide and improve its services, including its models, unless you opt out under Terms and privacy › Data use in your ElevenLabs account (the "Improve the models for everyone" toggle); an opt-out applies to data submitted afterwards. Enterprise customers are not trained on by default, and Zero Retention Mode, which deletes request data after the request completes, is an enterprise-only API option ([documentation](https://elevenlabs.io/docs/eleven-api/resources/zero-retention-mode.mdx)).

Other network traffic:

- **Key tests.** Settings › Accounts › Test key makes a read-only request to ElevenLabs or Google. It transmits the key to that provider, which is the point of the test.
- **Update checks.** Release builds contact github.com to read the update feed (`appcast.xml`) through Sparkle, which means GitHub sees the request. Builds you make yourself never check.
- Vizier has no analytics and no account of its own. The only hosts the code contacts are ElevenLabs, Google, the GitHub update feed, and your own Mac.

The microphone permission text says that recordings stay on this Mac, and that in the cloud modes the audio also goes to the provider you picked.

## What is stored on your Mac

| Where | What |
|---|---|
| `~/Library/Application Support/Vizier/history.sqlite` | One row per take: raw transcript, cleaned text, final text, the name of the app that was frontmost, mode, engine, timings, outcome, reasons, and any Re-run attempts |
| `~/Library/Application Support/Vizier/Takes/<yyyy-MM>/<id>.flac` | The take's audio: 16 kHz mono, 16-bit FLAC. Cancelled takes are kept too. |
| `~/.config/vizier/` | `vizier.jsonc`, `vocabulary.txt`, `replacements.txt` |
| macOS Keychain, service `net.praxient.dictum` | Accounts `elevenlabs` and `gemini`: your API keys. Settings never shows a saved key again. |
| App preferences | Hotkey, Show in Dock, sounds, whether setup is done |

Audio is recorded to a temporary file first, then encoded to FLAC and checked. After a crash, the leftover recording is recovered at the next launch.

**Vizier never deletes a take.** There is no delete button, so History grows until you act. To remove takes, quit Vizier and delete the files you want from the `Takes` folder and the matching rows in `history.sqlite`, or delete both to start over. History is plain SQLite and the audio is ordinary FLAC, so any tool will do.

**The clipboard is not restored after a paste.** To paste, Vizier puts the dictated text on the clipboard and leaves it there. Whatever you had copied before is gone, and the dictated text stays on the clipboard, readable by any app and by clipboard-history tools, until you copy something else. This applies to every mode, including Apple mode.

## Command-line output

The app binary's `--transcribe-apple <file>` flag prints the transcript of that file to standard output (along with the engine, timing and word count), so a shell, a script's log or a terminal's scrollback may keep it. It runs on-device with Apple's recognizer only. Other flags print counts and status, not text. See [using Vizier](using.md#command-line-flags).

## Logs

Vizier logs through macOS unified logging with the subsystem `net.praxient.dictum`. Transcripts, provider responses, vocabulary terms, configuration values and file paths that could identify your data are marked private, which means macOS redacts them in the log. What stays visible is take ids (a UTC timestamp), durations, counts and error categories. A malformed config or replacements file is reported by file and, for replacements, line number only. Only the optional local cleanup server writes a log file (`~/Library/Logs/Vizier/cleanup.log`); the local Whisper server's log goes to `/dev/null`.

## Permissions

Vizier asks for Microphone access (to record) and Accessibility access (to see your hotkey and send the paste keystroke). The hotkey is watched through a macOS event tap, which sees key events system-wide, as any global shortcut tool must. The code acts on three things only: the hotkey modifier, Escape, and a Cmd+V typed near a take's stop, which it notes in the log for diagnosing double pastes (the log records that it happened, not what you typed). It does not record, store or send other keystrokes. See [installing](installing.md#permissions).

## Reporting a vulnerability

Use GitHub's private vulnerability reporting, described in [SECURITY.md](../SECURITY.md).

## Linux COSMIC integration

On COSMIC, automatic paste uses ydotoold's keyboard-injection access to
`/dev/uinput`. `vizier setup` can install a per-user input service with a private
0700 runtime directory and 0600 socket; it does not grant device permissions or
change group membership. `--autostart` enables the service when access is already
available. A compatible existing input daemon is reused.

The bundled focus reader queries COSMIC window metadata, discards titles, and
returns only the active app ID to Vizier for terminal paste-key selection. It
runs as a short-lived subprocess and does not retain the window list. The app ID
can appear in the existing take history as the frontmost app. Neither this reader
nor the input service sends network traffic. Local Whisper sends audio only to the
configured loopback server. Downloading its model is a separate installation step. See [Linux setup](linux.md#pop_os-cosmic).
