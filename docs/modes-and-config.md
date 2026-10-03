# Modes and configuration

A **mode** is a recipe for turning speech into text: which engine listens, what to try if it fails, whether to clean the text, and whether to strip filler words. You pick the active mode from the menu bar popover or Settings › Transcription. Modes live in `~/.config/vizier/vizier.jsonc`, which you can edit by hand.

## The files

| File | What it holds |
|---|---|
| `~/.config/vizier/vizier.jsonc` | The active mode and the list of modes |
| `~/.config/vizier/vocabulary.txt` | Words to recognize, see [vocabulary and replacements](vocabulary-and-replacements.md) |
| `~/.config/vizier/replacements.txt` | Text substitutions, see the same page |

Vizier writes starter versions of all three if they are missing. They are re-read on every take, so an edit applies to the next take without a restart. If a file does not load, the alert lights and the last good config keeps running; fix the file and the next take picks it up. Settings › Words opens the vocabulary and replacements files. Your hotkey, Show in Dock, Sounds and Open at Login are ordinary app preferences, not part of these files.

## The starter modes

| Mode | Engine | Cloud | Cleanup | Fillers removed by |
|---|---|---|---|---|
| Apple (default) | Apple speech recognizer, live | No | None | Filler rule |
| Scribe | ElevenLabs Scribe, live | ElevenLabs, with Gemini batch as the first fallback | None | Filler rule |
| Gemini Clean | Gemini Live | Google | Gemini model pass | The cleanup pass |
| Gemini SMART | Gemini Live in SMART mode | Google | None | Gemini |

A new install writes your Mac's system language into all four starter modes. See [Languages](#languages).

The code also has a built-in **Local** mode (whisper.cpp on this Mac). It is experimental and not in the starter file; see [Local Whisper](#local-whisper-experimental).

If a live mode's stream fails or is late, Vizier sends the saved audio through the mode's fallbacks, in order; the first that answers wins. A cloud link with no key is skipped. Every starter mode other than Apple's ends with Apple's recognizer on the saved audio, which works with no network, provided Apple's speech model is installed.

## Config format

`vizier.jsonc` is JSON5: comments (`//`) and trailing commas are allowed. Keys are snake_case. A trimmed example:

```jsonc
{
  // The mode every take runs through. Must match one of the ids below.
  "mode": "apple",
  "modes": [
    {
      "id": "apple",
      "name": "Apple",
      "transcriber": {
        "engine": "apple-speech",
        "model": "speech-transcriber",
        "mode": "general",
        "languages": ["en-US"], // your system language on a new install
        "final_timeout_ms": 3000,
      },
      "fallback": { "engine": "apple-speech-batch", "model": "speech-transcriber", "mode": "general" },
      "remove_fillers": true,
    },
  ],
}
```

### Top level

| Key | Meaning |
|---|---|
| `mode` | The `id` of the active mode. It must match a mode in `modes`. |
| `modes` | A non-empty list of modes. |

### A mode

| Key | Required | Meaning |
|---|---|---|
| `id` | yes | Short name that `mode` refers to. |
| `name` | yes | Shown in the popover and Settings. Its initials become the two-letter code on the strip. |
| `transcriber` | yes | The engine that listens. |
| `fallback` | no | A batch engine to try on the saved audio if the transcriber fails. |
| `cleanup` | no | A text pass over the transcript. |
| `remove_fillers` | no | `true` to drop "um", "uh" and similar. Default off. |
| `offline_fallback` | no | A last batch engine that runs on this Mac, tried after `fallback`. |

### `transcriber`

| Key | Meaning |
|---|---|
| `engine` | One of the engines below. |
| `model` | The provider's model name. |
| `mode` | An engine-specific setting, see below. |
| `languages` | A list of BCP-47 tags, such as `["en-US"]` or `["de-DE"]`. `[]` is allowed for Scribe and Gemini and lets them detect the language. See [Languages](#languages). |
| `final_timeout_ms` | Greater than 0. How long to wait after the stop tap for the live engine's final transcript before the saved audio goes to batch. |
| `url` | Local engines only; see below. |

### `fallback` and `offline_fallback`

Each has `engine`, `model` and `mode`, and `url` for local engines. `offline_fallback` must be both local and a batch engine: `local-whisper` or `apple-speech-batch`.

### `cleanup`

| Key | Meaning |
|---|---|
| `engine` | `gemini-generate` or `local-cleanup`. |
| `model` | The model name. |
| `thinking_level` | Optional, for Gemini models. |
| `timeout_ms` | Greater than 0. Past this, the raw transcript is pasted. |
| `url` | `local-cleanup` only. |

## Engines

| Where | Engine | Notes |
|---|---|---|
| Live transcriber | `apple-speech` | On-device, no key |
| | `elevenlabs-scribe-realtime` | Needs an ElevenLabs key |
| | `gemini-live` | Needs a Gemini key |
| Batch transcriber or fallback | `apple-speech-batch` | On-device, no key |
| | `elevenlabs-scribe-batch` | ElevenLabs key |
| | `gemini-batch` | Gemini key |
| | `local-whisper` | A whisper.cpp server on this Mac |
| Cleanup | `gemini-generate` | Gemini key |
| | `local-cleanup` | An OpenAI-compatible server on this Mac |

A mode whose `transcriber` is a batch engine is **batch only**: there are no live words, the take is recorded, and the audio is transcribed once after you stop.

The `mode` field depends on the engine:

- **Apple.** Use `general`.
- **Scribe realtime.** `verbatim` or `no_verbatim`; `no_verbatim` turns on Scribe's own removal of fillers and false starts. **Scribe batch.** `verbatim` only.
- **Gemini live.** `VERBATIM` or `SMART`, in capitals. **Gemini batch.** `verbatim` or `smart`, lower case.

### Languages

`languages` is read like this:

- **Apple** uses the first entry only.
- **Scribe** uses the part before the hyphen of the first entry (`de-DE` becomes `de`, because the API does not accept a region suffix). With `[]`, Scribe detects the language.
- **Gemini** receives the whole list as a hint, not a limit. With `[]`, Gemini detects the language.

A bare language such as `en` is given a region before Apple's recognizer is asked about it: your Mac's region if its language matches (`en` on a British-English Mac is `en-GB`), otherwise the language's usual region (`en` is `en-US`, `de` is `de-DE`). This keeps older configs that name `en` working.

A new install writes your Mac's system language into all four starter modes, so the Apple model that setup downloads is also the one the offline fallbacks use. Saved configs are never rewritten, so an existing file keeps the languages it has. There is no language picker in the app yet: to change a mode's language, edit `languages` in `vizier.jsonc`.

If Apple's on-device speech does not support your system language, Settings › Transcription and the setup guide's Speech model step show **Unsupported**, with a pointer to Scribe and Gemini, which cover many more languages (add a key under Accounts, then choose that mode). Takes in the Apple mode then fail and keep their audio, so you can [Re-run](using.md#re-run) them through a cloud mode later.

A `url` may be given only to a local engine (`local-whisper`, `local-cleanup`, `apple-speech-batch`), and must be an `http` address on a numeric loopback address, `127.0.0.1` or `::1`. `localhost` is refused on purpose, because it goes through name resolution. Vizier will not send audio to a remote server through this field.

## What happens to a take

1. You stop, and the transcriber's final transcript arrives. If it is late (past `final_timeout_ms`) or the stream dropped, the saved audio goes down the batch chain: the transcriber (in a batch-only mode), then `fallback`, then `offline_fallback`.
2. The `cleanup` pass runs, if the mode has one.
3. The filler filter runs, if `remove_fillers` is true.
4. Your replacements run.
5. The text is pasted.

### Cleanup safety checks

A cleanup pass must not rewrite what you said. If a transcript of 12 words or more comes back with fewer than 60% of its words, or any transcript comes back empty, or the result has more than 1.25 times the original word count plus 4, the cleanup result is discarded and the raw text is pasted, with a remark in the strip and in History. A timeout and a failure also paste the raw text.

### The filler filter

`remove_fillers` is plain code, not a model, and never adds or changes words. It removes `um`, `umm`, `uh`, `uhh`, `uhm`, `erm`, and cut-off fragments such as "w-". It removes `er`, `mm` and `mmm` only when punctuated, `hmm` and `mm-hmm` only mid-sentence or before an ellipsis, and "you know", "I mean" and "like" only when commas set them off. It repairs commas and capitals afterward. Its rules are English only, so it runs only when the mode's first language is English (`en` or any `en-` region); in a take in any other language it is skipped, even with `remove_fillers` set. A mode with no language uses the system's for this check. It leaves all-caps words alone.

## Local Whisper (experimental)

This is an experimental, unsupported option for people comfortable with a terminal. It is not in the starter file, the setup guide does not mention it, and the helper script makes assumptions you may need to change.

What it is: a mode whose engine is `local-whisper` sends audio to a [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `whisper-server` running on your Mac, by default at `http://127.0.0.1:8738/v1/audio/transcriptions`. It is a batch engine, so the take is recorded and transcribed after you stop. Add a mode like this to `modes`, then select it:

```jsonc
{
  "id": "local",
  "name": "Local",
  "transcriber": {
    "engine": "local-whisper",
    "model": "large-v3-turbo",
    "mode": "verbatim",
    "languages": ["en"],
    "final_timeout_ms": 4000,
  },
  "remove_fillers": true,
}
```

`scripts/local-models.sh install|status|uninstall` writes a macOS launch agent, `net.praxient.dictum.whisper`, that runs the server. The agent is installed disabled; Vizier starts it only while the active mode uses a local engine. What the script requires, as written:

- A `whisper-server` binary at `/opt/homebrew/bin/whisper-server` (Homebrew on Apple Silicon: `brew install whisper-cpp`). The path is hard-coded in the script.
- The model files `~/.cache/whisper/ggml-large-v3-turbo.bin` and `~/.cache/whisper/ggml-silero-v6.2.0.bin` (a voice-activity model). The script checks that they exist and stops if they do not. It does not download them; this guide does not cover where to get them. They come from the whisper.cpp project's model downloads.
- Port 8738 free. The script refuses to continue if another process holds it.
- Its server arguments are fixed: English (`-l en`), eight threads (`-t 8`), and the VAD model. To change them, edit the script.

`status` checks whether the server answers. `uninstall` removes both launch agents. The server's log goes to `/dev/null`.

`local-cleanup` is a separate, bring-your-own piece: a text-cleanup pass that talks to an OpenAI-compatible chat server you run yourself, by default at `http://127.0.0.1:8747/v1/chat/completions`. Vizier posts `{"model": ..., "messages": [{"role": "user", "content": <transcript>}], "temperature": 0}` and reads `choices[0].message.content`; the server owns its prompt and must not log transcripts. The script can set up a launch agent (`net.praxient.dictum.cleanup`) for it if `VIZIER_CLEANUP_COMMAND` names an executable that starts the server (it gets no arguments, so put flags in a wrapper script) and `VIZIER_CLEANUP_DIR` sets its working directory. A cleanup entry looks like `"cleanup": { "engine": "local-cleanup", "model": "my-cleanup-model", "timeout_ms": 8000 }`, where `model` is the id your server expects.

If a local server is not running, the take fails with a remark that says so, and the audio is saved. Local engines are loopback only; see above.

## Keys

API keys are in the macOS Keychain as generic passwords under the service `net.praxient.dictum`, with the accounts `elevenlabs` and `gemini`. They are read on every take, so a new key works immediately. Add them in Settings › Accounts, or pipe one in:

```bash
printf '%s' "$KEY" | /Applications/Vizier.app/Contents/MacOS/Vizier --store-key elevenlabs
```

The command reads the key from standard input only, and refuses a terminal. Settings › Accounts has a Test key button, which makes a read-only request (ElevenLabs `/v1/user`, Gemini `/v1beta/models`) that does not bill you.

## Limits

- At most 1,000 vocabulary terms in total; more is a config error.
- Batch transcription is capped at one hour of audio. Gemini batch sends audio inline up to 14.5 MB and uploads larger files through Google's Files API, deleting them afterwards.
