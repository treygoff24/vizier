<!--
Thanks for the pull request. Read CONTRIBUTING.md (and CLAUDE.md if you are an AI agent) first.
Fill in every section; write "n/a" with a reason where one does not apply.
A PR that leaves out the test evidence or the privacy check may be closed without review.
-->

## What changed and why

<!-- One or two paragraphs. The problem first, then the change. Link the issue: "Fixes #123". For anything larger than a small fix, open an issue first and wait for a reply before writing code. -->

Fixes #

## Tests

<!-- Run `swift test` on your Mac (macOS 26 or later, Apple Silicon). Paste the exact command and the final line it prints, which reports the count. -->

- Command: `swift test`
- Result (final line, with the test count):
- Targeted run while developing (for example `swift test --filter RerunTests`), if any:

## Mutation proof for new tests

<!-- Every new or changed test must be proved: break the code it guards, run the test, watch it fail, restore the code. Name the test and the mutation for each. "No new tests" needs a reason (docs-only, comment-only, or a change no test can reach). -->

| Test | Mutation I made (file, what I broke) | Failure I saw |
|---|---|---|
| | | |

## User-visible changes

<!-- Screenshots for any UI change, made with `--render-ui <folder>` or `--preview-surfaces <folder>` (see docs/building.md). Those flags use made-up data. Write "none" for a change users cannot see. -->

## Privacy check

- [ ] No real dictations, transcripts, audio, vocabulary or word replacements in the diff, the tests, the screenshots, the PR text or the logs I pasted. Test audio is synthetic (`say`, then `afconvert`).
- [ ] No API keys, tokens or personal file paths anywhere in this PR.
- [ ] No transcript text is logged. Anything user-derived in a new log line is marked `privacy: .private`.
- [ ] If the change adds network traffic, stored data or a permission, I said so above and updated docs/privacy.md.

## Checklist

- [ ] Docs updated if behavior changed (the page that owns the topic in `docs/`).
- [ ] Commits use explicit file paths (no `git add -A`), subject lines are 72 characters or fewer, and the body says why.
- [ ] I did not run `scripts/install.sh` or relaunch an installed Vizier on a machine that someone uses.
- [ ] I did not change the bundle id, Keychain service or logging subsystem (`net.praxient.dictum` stays; see CONTRIBUTING.md on forks).
- [ ] I did not edit another project's attribution headers (the VoiceInk headers stay as they are; see NOTICE).

## AI assistance

<!-- Be plain about it; AI-assisted pull requests are welcome when a person stands behind them. -->

- [ ] No AI tool wrote any part of this change.
- [ ] An AI tool wrote or helped write this change. Tool and model:
- A person has read the whole diff and takes responsibility for it: yes / no
- What I ran myself, as opposed to what the AI told me it ran:
