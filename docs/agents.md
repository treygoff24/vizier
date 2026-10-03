# Working in this repository (for AI agents)

Read [CLAUDE.md](../CLAUDE.md) first: it is the short rule list, and it wins over anything here. This page adds the working detail. [architecture](architecture.md) explains how a take flows through the code, and the repo map is in the [README](../README.md#for-ai-agents).

`AGENTS.md` only points to `CLAUDE.md`.

## Before you change anything

- Vizier is somebody's dictation tool, and the machine you are on may be running it. Building, testing and committing are safe. `scripts/install.sh`, quitting an installed Vizier, and launching a second full copy of the app are not: they can kill a take in progress, and a second copy shares the account's hotkey, Keychain items, launch agents and history. A one-shot flag that exits before the app starts up (`--version`, for example) is fine.
- Do not read `~/Library/Application Support/Vizier/` or `~/.config/vizier/`. They hold a person's real transcripts, audio, vocabulary and replacements, and none of that may reach a commit, a test, a log, an issue or a pasted message.
- Do not print or commit API keys. They live in the Keychain, service `net.praxient.dictum`.

## Build and test

```bash
swift build
swift test                                  # the last line reports the count
swift test --filter RerunTests              # one suite
scripts/build-app.sh                        # build/Vizier.app, gitignored, ad hoc signed
build/Vizier.app/Contents/MacOS/Vizier --version
```

Run the tests for what you changed while you work, and the full suite before you finish.

- Tests are Swift Testing. Engine tests are in `Tests/VizierEngineTests/`, app tests in `Tests/VizierTests/`.
- Tests must not touch the real Keychain or a person's data folders. App tests inject `InMemoryKeyStore`. Keep it that way, and keep `RealDataGuard` in front of any command that writes sample data.
- Audio fixtures are synthetic: `say -o x.aiff "some text"`, then `afconvert` to the format you need.
- **Prove new tests by breaking the code.** Make a change that should make the test fail, run it, watch it fail, restore the code, and say which mutation you used when you report. A test you have never seen fail is unproven.
- To see UI changes without the installed app, use `--render-ui <folder>` and `--preview-surfaces <folder>`, which use made-up data. See [building](building.md#looking-at-the-ui-with-made-up-data).

## Committing

- Stage by explicit path (`git add path/to/file`). Never `git add -A` or `git add .`.
- Subject line of 72 characters or fewer, then a blank line, then a body in whole sentences saying why, and which tests you ran.
- Do not amend, force-push or skip hooks.

## Where to make common changes

| Change | Where |
|---|---|
| Add a config key or change validation | The types and `parseSettings` in `Sources/VizierEngine/Config/VizierConfig.swift`; update the starter file text in the same file; tests in `ConfigStoreTests`; then [modes-and-config](modes-and-config.md) |
| Add a transcription engine | Add its name to the right list in `ConfigStore` (live, batch, cleanup, local), write the adapter in `Transcription/` or `Cleanup/`, build it in `Config/Engines.swift`, add tests, and document the engine and its privacy cost in [modes-and-config](modes-and-config.md) and [privacy](privacy.md) |
| Change what a take says about itself | The `Remark` strings in `Sources/Vizier/TakeController.swift`; the status table in [troubleshooting](troubleshooting.md) lists them |
| Change the text pipeline | `Cleanup/TextCleanup.swift` (safety checks), `Cleanup/FillerFilter.swift`, `Replacements/`. Tests exist for each; the order of steps is set in `TakeController` and `Rerun` and must stay the same in both |
| Change the hotkey choices | `HotkeyModifier` in `VizierEngine/Hotkey/RightCommandKey.swift`, and the shortcut files in `Sources/Vizier/Hotkey/` |
| Change paste behaviour | `Paste/PasteTarget.swift`, `Paste/PasteText.swift` and `Sources/Vizier/Paste/Paster.swift` |
| Change history storage | `Takes/HistoryStore.swift` (SQLite). Existing users have a database on disk, so plan for a schema change to open their old file |
| Change a window's look | The view in `Sources/Vizier/`, and the tokens in `Board.swift` and [DESIGN.md](../DESIGN.md) |
| Bump the version | `VERSION`. `BUILD_NUMBER` must only go up |

## Things that look odd and are deliberate

- The hotkey is a toggle on key-down, not hold-to-talk.
- Pasted text is left on the clipboard; the previous contents are not restored.
- No take is ever deleted by the app, cancelled ones included.
- A broken config file never stops dictation: the last good config runs and the alert lights.
- The cleanup pass is distrusted: it can be discarded for dropping or adding words.
- Gemini and Scribe take different `mode` spellings (`VERBATIM` live, `verbatim` batch). That follows each provider's API.
- Files adapted from VoiceInk keep their attribution headers. Leave them as they are, and see [NOTICE](../NOTICE).

## Filing issues as an agent

Read [SUPPORT.md](../SUPPORT.md) first. It has the scope, the field list and a copy-paste skeleton. The short version:

- **Ask the person you work for before you file**, show them the whole draft, and file once. Search existing issues first (`gh issue list --repo github.com/treygoff24/vizier --state all --search "<keywords>"`) and comment on a match instead of opening a duplicate.
- **`gh issue create` cannot fill in issue forms.** Write the body yourself with one `### <field label>` heading per field of [bug_report.yml](../.github/ISSUE_TEMPLATE/bug_report.yml) or [feature_request.yml](../.github/ISSUE_TEMPLATE/feature_request.yml), labels exactly as written there, and use the title prefix `[Bug]: ` or `[Feature]: `.
- **Collect diagnostics only with** `log show --last 10m --predicate 'subsystem == "net.praxient.dictum"' --info` (the log subsystem keeps the app's original bundle id). Do not read `~/Library/Application Support/Vizier/` or `~/.config/vizier/`, and do not run `scripts/install.sh` or relaunch an installed copy to reproduce. Remove dictated text, keys and personal paths from what you paste.
- **Disclose.** Say that an agent filed the issue, whether a person reproduced it, and which claims you observed by running code and which you inferred from reading it.
- **Pull requests:** follow the [template](../.github/PULL_REQUEST_TEMPLATE.md): the `swift test` command and final count, one mutation per new test, the privacy checklist, and your AI-assistance disclosure.

## Documentation

Docs live in `docs/`, one topic per file, with no duplication between them. The README summarizes, and the page for a topic explains it; when you change behaviour, change the page that owns it. Keep the text plain: no marketing language, and no names, paths or dates specific to one person's setup. Do not put real dictation text in examples.
