# Vizier

Instructions for AI coding agents working in this repository. Humans: see `CONTRIBUTING.md`.

## Build and test

```bash
swift build                # the engine library and the app target
swift test                 # Swift Testing; the final line reports the test count
scripts/build-app.sh       # builds build/Vizier.app (gitignored); does not install or launch it
```

Run the tests for what you changed, then the full suite before you finish.
`scripts/install.sh` replaces the installed app and relaunches it. See the reinstall rule below.

## Rules

- **Reinstall rule.** Never run `scripts/install.sh`, and never quit or relaunch an installed copy of Vizier, without asking the person you work for. They may be mid-dictation, and a relaunch kills the take. Building, testing, and committing are always fine.
- **Do not run a second full copy of the app** on a user account that already uses Vizier. It shares that account's Keychain items, hotkey, launch agents, and history. A one-shot command-line flag that exits before app setup is fine.
- **Privacy.** Real dictations, audio, vocabulary, and word replacements never enter commits, tests, logs, or reviewer copies. Do not read the app's data folders (`~/Library/Application Support/Vizier/`, `~/.config/vizier/`, and the same folders under the app's earlier name, `~/Library/Application Support/Dictum/` and `~/.config/dictum/`). Test audio is synthetic: `say -o x.aiff "text"`, then `afconvert`. No transcript text goes into logs.
- **Mutation rule.** Every new test is proved by a mutation: break the code it guards, watch the test fail, restore the code. Report which mutation you used.
- **Never print or commit API keys.** Keys live in the Keychain.
- Commit with explicit file paths, not `git add -A`. Keep subject lines to 72 characters, then a blank line and a body saying why and which tests ran.

## Layout

- `Sources/VizierEngine`: the engine library (capture, transcription, cleanup, config, paste, history).
- `Sources/Vizier`: the menu-bar app (AppKit and SwiftUI).
- `Tests/`: unit tests. `Resources/`: Info.plist, entitlements, bundled font and sounds.
- `DESIGN.md` is the visual design system. `NOTICE` lists third-party code; leave the VoiceInk attribution headers as they are.
