# Support

Vizier is a free, open-source dictation app for the Mac with one maintainer. Support is best effort, with no response-time promise. This page says where to take what, what is in scope, and how to write a report that gets acted on. If you are an AI agent acting for a user, read [Filing without the form](#filing-without-the-form-gh-api-agents) before you open anything.

## Where to go

| You want to | Go to |
|---|---|
| Fix a common problem (hotkey, paste, permissions, a cloud mode that does nothing) | [docs/troubleshooting.md](docs/troubleshooting.md) first |
| Understand a setting, a mode, or what leaves your Mac | [docs/README.md](docs/README.md), [docs/modes-and-config.md](docs/modes-and-config.md), [docs/privacy.md](docs/privacy.md) |
| Ask how to do something, or float an idea that is not yet a concrete request | [Discussions](https://github.com/treygoff24/vizier/discussions) |
| Report a bug you can reproduce | [A bug report](https://github.com/treygoff24/vizier/issues/new?template=bug_report.yml) |
| Propose a specific change | [A feature request](https://github.com/treygoff24/vizier/issues/new?template=feature_request.yml) |
| Report a security vulnerability | [Private vulnerability reporting](https://github.com/treygoff24/vizier/security/advisories/new), described in [SECURITY.md](SECURITY.md). Never a public issue. |
| Report a code-of-conduct problem | [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) |
| Change the code | [CONTRIBUTING.md](CONTRIBUTING.md) (and [docs/agents.md](docs/agents.md) for agents) |

Search [existing issues](https://github.com/treygoff24/vizier/issues?q=is%3Aissue) before you file. Blank issues are turned off on purpose: the forms ask for what a fix needs.

## What is in scope

Supported:

- The latest released version, on macOS 26 or later, on Apple Silicon.
- The latest released version on Linux (x86_64), best effort: the `.deb` and AppImage, the `vizier` daemon and CLI, and the desktops named in [docs/linux.md](docs/linux.md). Fixes for other desktops and compositors are welcome as pull requests.
- The Apple (on-device), Scribe and Gemini modes, and edits to `vizier.jsonc`, `vocabulary.txt` and `replacements.txt` as documented.
- The local Whisper and local cleanup engines, best effort: Vizier only talks to a server you run; a server or model problem is the server's.
- Builds you make from `main` with `scripts/build-app.sh`, with the caveat that ad-hoc-signed builds lose the Accessibility grant on every rebuild (see troubleshooting).

Not supported, so reports will be closed with a pointer:

- Intel Macs, macOS 25 or earlier, iOS, Windows, and Linux on other architectures.
- Help with a provider's account, billing, quota or API keys (ElevenLabs, Google). Vizier can show you its own error; the provider's side is theirs.
- Recognition accuracy that comes from Apple's or a provider's model rather than from Vizier. Try another mode, or add words to `vocabulary.txt` or `replacements.txt`.
- Forks and their builds (see [CONTRIBUTING.md](CONTRIBUTING.md#forking)).
- Requests that need the app to send more data off the Mac by default. Vizier's defaults are on-device, no analytics, no account.

## Writing a bug report that gets fixed

The bug form asks for each of these, and they are the whole recipe:

1. **Version and build.** Settings › About, or `/Applications/Vizier.app/Contents/MacOS/Vizier --version` (prints the version, build and updater status, then exits).
2. **Environment.** macOS version (`sw_vers -productVersion`), chip (`sysctl -n machdep.cpu.brand_string`), and whether you installed the DMG or built from source.
3. **The mode in use.** Apple, Scribe, Gemini Clean, Gemini SMART, a custom mode, or local Whisper.
4. **Exact steps, expected result, actual result.** Include the strip's status word and its one-line reason, and the reason in History's detail pane for that take.
5. **Logs.** Run this right after reproducing the problem and paste the relevant lines:

   ```bash
   log show --last 10m --predicate 'subsystem == "net.praxient.dictum"' --info
   ```

   The subsystem keeps the project's old name, `net.praxient.dictum`, on purpose; so do the bundle id and the Keychain service.
6. **A cleaned report.** Remove dictated text, API keys, email addresses and personal paths before you post. Vizier marks transcripts and paths private in its logs, but you make the final check. Do not attach audio, the history database, or the contents of `~/Library/Application Support/Vizier/` or `~/.config/vizier/`.

A report that can be reproduced from its steps on a clean Mac is a report that gets fixed. One that cannot gets the `needs-repro` label and waits.

## Filing without the form (gh, API, agents)

GitHub's CLI cannot fill in issue forms ([cli/cli#5865](https://github.com/cli/cli/issues/5865)), and the REST API ignores them, so an agent that files with `gh issue create` has to write the body itself. Do it in the form's layout: one `### <field label>` heading per field, labels exactly as below and in this order, so that the issue reads like a form-made one and a maintainer (or a later agent) can find each field. Fill every heading; write `unknown` rather than leaving one out.

Rules for an agent filing on a person's behalf:

- **Ask the person first.** Show them the whole draft and file only after they agree. Do not file speculatively, and never file the same report twice.
- **Search first.** `gh issue list --repo github.com/treygoff24/vizier --state all --search "<keywords>"`. Comment on a matching issue instead of opening a new one when you have something new to add.
- **Do not read the app's data folders.** Collect diagnostics with the `log show` command above, which is safe: transcripts are already redacted in it. Do not read `~/Library/Application Support/Vizier/` or `~/.config/vizier/`, and do not run `scripts/install.sh` or relaunch an installed copy to reproduce a bug. See [docs/agents.md](docs/agents.md).
- **Say what you did and did not do.** The disclosure fields are required: whether an agent filed it, and whether a person reproduced it. "I read the code and this looks wrong" is a useful report, as long as it says so.
- **Keep it short and checkable.** One problem per issue. Name files and functions in the proposed-fix field, and say whether you verified the claim by running code.

Bug skeleton (save to a file, edit, then `gh issue create --repo github.com/treygoff24/vizier --title "[Bug]: <short summary>" --body-file bug.md`; leave out `--label` unless you have triage rights, since the maintainer labels issues):

````markdown
### Before you file
- [x] I searched open and closed issues and this is not a duplicate.
- [x] I read docs/troubleshooting.md and it does not solve this.
- [x] This is not a security vulnerability.

### Vizier version and build
Vizier 0.1.0 (1), updater eligible

### How you installed it
Released DMG from GitHub Releases | Built from source (scripts/build-app.sh) | Other

### macOS version
27.0 (build 25A1234)

### Mac chip
Apple M4 Pro

### Transcription mode in use
Apple (on-device, the default) | Scribe (ElevenLabs, cloud) | Gemini Clean (Google, cloud) | Gemini SMART (Google, cloud) | Custom mode (describe the engines under Additional context) | Local Whisper (experimental, unsupported) | Not tied to a mode (install, update, window or setup problem)

### Area
Hotkey | Paste into another app | Recording and the strip | Transcription accuracy or engine failure | Cleanup, vocabulary or replacements | History and Re-run | Settings, setup guide or permissions | Install, update or launch at login | Crash or hang | Other

### How often it happens
Every time | Sometimes | Once so far

### Exact steps to reproduce
1.
2.
3.

### Expected behavior

### Actual behavior

### Diagnostics
~~~text
(output of the log show command, cleaned of text, keys and personal paths; or "no log lines")
~~~

### Proposed fix or pointers (optional)

### Additional context (optional)

### Was this issue filed by an AI agent on behalf of a user?
Yes: an AI agent filed this on behalf of a user

### Did a human reproduce this on their own Mac?
Yes: a person ran these steps and saw the problem | No: an agent ran the steps and saw the problem, no person confirmed it | No: this is inferred from code, docs or logs and was not reproduced

### Agent details (only if filed by an agent)
Agent and model, commands run, what was observed versus inferred.

### Privacy and conduct
- [x] I did not include any transcript or dictated text, audio, API keys, or personal file paths, in this report or its attachments.
- [x] I agree to follow this project's Code of Conduct.
````

Pick one value where the line lists options with `|`. For a feature request, use the headings in [feature_request.yml](.github/ISSUE_TEMPLATE/feature_request.yml) the same way (title prefix `[Feature]: `): *The problem or use case*, *Proposed behavior*, *Area*, *Privacy impact*, *Would you or your agent open a pull request?*, and the disclosure fields.

## Pull requests

Open an issue first for anything bigger than a small fix, and wait for a reply: the maintainer would rather say no early than review a large change that cannot go in. The [pull request template](.github/PULL_REQUEST_TEMPLATE.md) lists what a PR must show: the exact `swift test` command and count, a mutation for every new test, and the privacy check.
