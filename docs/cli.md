# Linux CLI and daemon

`vizier daemon` runs in the foreground. Operational commands prefer the daemon. If it is down or the runtime directory is unavailable, config path/get, history
and last read local storage; config set remains daemon-only. Version and help are local. `--json` works before or after any command; otherwise
output is human readable. Bare `vizier`, `vizier --help`, `vizier help <command>`
and `vizier <command> --help` explain the next invocation without connecting.
JSON help is a normal success envelope with `result.help`. `vizier --version` and
`vizier version --json` report `{version:"0.1.0",protocol:1}` in result.
`--limit=5` and `--before=<cursor>` are accepted alongside space-separated forms.

```bash
vizier daemon
vizier doctor --json
vizier status --json
vizier start
vizier stop                 # acceptance only; transcription continues
vizier status
vizier last
vizier history --limit 5 --json
vizier history --limit 5 --text --before 2026-10-03T20:00:00.000Z --json
vizier config get --json
vizier config set mode local
```

The daemon runs the engine's real take session (`LinuxRuntime`): `pw-record` capture
(`parec` when only it is installed), the secret chain below, desktop notifications, sounds,
the focused-app probe and the paste route for the desktop it was started in. Crash recovery
of earlier takes runs first; until it finishes, take commands are refused with
`startup_not_ready`. `CLI.run(..., makeControl:)` still lets a test or another host supply
its own `TakeControl`.

```bash
vizier setup                # probe this desktop, consent steps, config, autostart unit, binds
vizier setup --autostart    # also: systemctl --user enable --now vizier.service
printf %s "$KEY" | vizier key set gemini --stdin
vizier key status           # where each key resolves from; never prints it
```

## Linux session: keys, feedback, hotkey, setup

**Keys (`vizier key set|status|delete <elevenlabs|gemini>`).** Client-only commands (no
daemon needed). The key is never an argument: `set` reads stdin (a hidden prompt on a terminal,
or a pipe; input is read in bounded byte reads, at most 4 KiB, must be valid UTF-8, and the key
is at most 512 bytes and one token). A read error is reported as `read_failed`, never taken for
an empty input. A command-line key is refused and the error does not echo it. Resolution order: environment variable (`VIZIER_ELEVENLABS_API_KEY`,
`VIZIER_GEMINI_API_KEY`) then Secret Service through `secret-tool` (attributes
`service net.praxient.vizier account <name>`, value on stdin) then
`$XDG_CONFIG_HOME/vizier/keys.json` (0600 in a 0700 folder). The folder is opened without
following a symlink, must be yours and is set to 0700; the file is opened relative to it
without following a symlink and must be a regular file of yours with mode 0600 (a wider mode,
a symlink or another kind of file is refused). Before reading, the Secret Service is asked over
D-Bus (`SearchItems`, never a value) whether the key's item exists and whether its keyring is
locked: no item is an absent key, a locked item is a backend failure, since `secret-tool lookup`
exits 1 for both. A backend that fails (locked keyring) does not hide a key stored further
down the chain; if nothing answers, the failure is reported. Backend errors and the helper's
stderr are never shown: messages name the operation and the exit status only.

**The daemon's keys are a snapshot.** The take session reads keys from memory, never from a
backend, so a stalled keyring cannot block the main actor. The snapshot is refreshed off the main
actor at daemon start (waited for about 3 s at most before the socket is published), every
60 s, and when `vizier key set|delete` succeeds: the client then sends the running daemon the
command `keys_changed` (args `{}`, result `{"refreshing":boolean}`, which returns at once and
starts a background re-read; a daemon that is down is ignored). A take that starts before the
first read finishes reports its key as unavailable. `set` stores in Secret Service
when it takes the key, else in the file, and says which. `--json` results:
`set` `{"key","storedIn":"secret-service"|"file","note"?}`; `status`
`{"keys":[{"key","name","resolvedFrom":null|"environment"|"secret-service"|"file","presentIn":[...],"errors":[...],"environmentVariable"}],"secretService":{"available":bool},"file":path}`;
`delete` `{"key","deleted":true,"note"?}`. Errors: `empty_key`, `invalid_key`, `tty_unsafe`,
`key_store_failed`, `key_delete_failed`, `read_failed`.

**Notifications.** One desktop notification (org.freedesktop.Notifications over the session
bus, replaced in place; `notify-send` when the bus is unreachable; nothing otherwise) goes
from recording to finalizing to the outcome. It carries the phase, the mode name and the
take's remark, never transcript text or the destination app. Updates go through a
one-slot queue: if the service is slow, only the latest state is delivered. At shutdown what is
still queued is abandoned when the shutdown deadline passes.

**Sounds.** `start`, `stop`, `problem`, `cancel` WAVs play through `pw-play`, else `paplay`,
else `aplay`, as detached children. They are found at `$VIZIER_SOUNDS_DIR`,
`../share/vizier/sounds` beside the binary, `$XDG_DATA_HOME` / `$XDG_DATA_DIRS` entries'
`vizier/sounds`, or the repository's `Resources/Sounds` when run from `.build`.
`VIZIER_SOUNDS=off` silences them.

**Environment the daemon reads besides the XDG paths:** `VIZIER_RECORDER_COMMAND` (an argv
replacing `pw-record`, split on spaces and tabs only: there is no quoting, escaping or shell
expansion, so quote characters and `$VAR` stay literal and an argument cannot contain a space;
use a wrapper script for anything more. It must write raw 16 kHz mono s16le to stdout),
`VIZIER_YDOTOOL=1` (adds `ydotool` as a paste fallback), `VIZIER_SOUNDS`,
`VIZIER_SOUNDS_DIR`. The desktop is read from `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`,
`WAYLAND_DISPLAY`, `DISPLAY`; under systemd the user manager must have them (see
`Resources/linux/README.md`).

**Hotkey.** On GNOME, KDE and Hyprland the daemon starts the GlobalShortcuts portal at
launch (Ctrl+Alt+Space toggles, Ctrl+Alt+Backspace cancels; the consent dialog, if any,
appears the first time; `vizier setup` does it ahead). Elsewhere nothing is registered:
bind `vizier toggle` and `vizier cancel` in the compositor (`vizier setup` prints the
lines). A refused toggle (while finalizing) is dropped; the take's notification says where it is.
On GNOME and KDE the RemoteDesktop portal paste route goes first when its consent exists;
the X11/wlroots tools are the fallback.

**`vizier setup [--autostart] [--no-portal] [--json]`.** Runs the probes, does the portal
consent steps (RemoteDesktop, GlobalShortcuts; skipped by `--no-portal`), writes the starter
config if missing, installs `$XDG_CONFIG_HOME/systemd/user/vizier.service` (`ExecStart=<abs
path> daemon`, `Restart=on-failure`, `TimeoutStopSec=15`), enables it only with `--autostart`
(otherwise prints `systemctl --user enable --now vizier.service`), and lists compositor binds
for the detected desktop (every compositor when unknown). Result:
`{"desktop":{display,family,currentDesktop},"checks":[Check],"paste":{"clipboard":[names],"keys":[names]},"portal":null|{...},"hotkey":{"route":"portal"|"compositor-bind"},"keys":[...],"config":{path,note,errors},"autostart":{unit,installed,enabled,command,error?},"binds":[{desktop,file,lines}],"healthy":bool}`.
Check names: `desktop`, `capture`, `clipboard`, `paste`, `hotkey`, `keys`, `local_whisper` /
`local_cleanup`, `sounds`, `notifications`. `healthy` is false (exit 5) when the desktop,
capture or clipboard check fails. `warn` marks something that degrades but does not stop
dictation (no paste keys: the text stays on the clipboard; no hotkey portal; a local server
that is not running yet). Nothing in setup has run on a real desktop yet.

## Socket and framing

The published path is `$XDG_RUNTIME_DIR/vizier/vizier.sock`. The runtime root must
be absolute, owned by the current UID, and mode 0700. The daemon creates its
`vizier` directory as 0700, refusing directory symlinks and unsafe existing
permissions. It never falls back to `/tmp`. The full socket path must fit the
Linux `sockaddr_un` limit (107 UTF-8 bytes). Socket mode is 0600. Both server and
client check `SO_PEERCRED` against the current UID. Linux descriptor-relative
operations and an anchored `/proc/self/fd` path prevent following a substituted
runtime child directory.

A user-owned 0600 regular `daemon.lock` file carries an exclusive nonblocking
`flock` for the daemon's entire life. Only its holder removes a stale, user-owned
socket; symlinks and regular files at the socket path are refused. The lock file
stays after shutdown; removing it would allow two processes to lock different
inodes. Shutdown removes only the socket inode this daemon created. Startup prepares
`vizier.sock.new`, makes it 0600 and listens under the lock, initializes storage
and the take session, then publishes it with renameat and starts readiness sources.
Only a ready socket is visible at the public path. Stale `.new` sockets are
removed only under the lock. `daemon --json` emits a ready envelope with
`result:{ready:true,socket:absolute-path}`, then a stopped envelope at exit.

Wire format is UTF-8 NDJSON, one JSON object per LF-terminated line:

```json
{"v":1,"id":17,"cmd":"status","args":{}}
{"v":1,"id":17,"ok":true,"result":{"daemon":"running","phase":"idle","seconds":0,"mode":"local"}}
{"v":1,"id":17,"ok":false,"error":{"code":"not_recording","message":"Take command refused: not_recording.","next":"vizier start"}}
```

`v` and `id` are integers; `cmd` is a string; `args` is an object and is required.
Replies echo `id`. A successful reply has `result` and no `error`; a failed reply
has `error` and no `result`. `result` is always an object. `error` always contains
string `code`, `message` and `next` (an actionable command).

The request cap is 65,536 bytes excluding LF. Oversized requests produce
`request_too_large` and close the connection. Malformed requests use reply ID -1;
a decoded unsupported version echoes its ID with `bad_version`. There is one
in-flight request per connection: the daemon sends a complete reply before
applying the next line. Split lines and joined lines are reassembled in order.
Clients may reuse a connection; there is no automatic command retry. Dropped
clients cannot kill the daemon; SIGPIPE is ignored and writes use MSG_NOSIGNAL.
There are at most 128 connections, with a 30-second inactivity deadline checked
by a one-second timer. At capacity, a new connection receives an ID -1
`daemon_busy` refusal (exit 4), then closes; no command was accepted. The CLI
uses five-second send/receive timeouts and a 16 MiB reply cap. A lost reply means
command acceptance is unknown: inspect `vizier status` before retrying a mutation.

## Request and result schemas

Empty args means exactly `{}`; unknown argument names are rejected before applying
a take command. Optional properties encoded by Swift may be absent rather than
null. Times are UTC ISO 8601 strings; history timestamps include milliseconds.

| Command | `args` | `result` |
|---|---|---|
| `ping` | `{}` | `{"pong":true}` |
| `status` | `{}` | TakeStatus plus `"daemon":"running"` |
| `toggle` | `{}` | TakeStatus after acceptance |
| `start` | `{}` | TakeStatus after acceptance |
| `stop` | `{}` | TakeStatus after acceptance; finalizing can continue |
| `cancel` | `{}` | TakeStatus after acceptance; preserved audio belongs to the session |
| `last` | `{}` | `{"take":HistoryEntryWithText}` or `{"take":null}` |
| `history` | `{"limit"?:integer,"before"?:cursor-or-ISO8601,"text"?:boolean}` | `{"takes":[HistoryEntry],"before":opaque-cursor-or-null}` |
| `config` path | `{"action":"path"}` | `{"path":absolute-settings-file}` |
| `config` get | `{"action":"get"}` | `{"path":absolute-settings-file,"settings":Settings}` |
| `config` set | `{"action":"set","mode":mode-id}` | `{"path":absolute-settings-file,"mode":mode-id}` |
| `doctor` | `{}` | `{"healthy":boolean,"checks":[Check]}` |
| `keys_changed` | `{}` | `{"refreshing":boolean}`; sent by `vizier key set\|delete`, see Keys |

TakeStatus is the engine's Codable shape:

```text
{phase: "idle"|"arming"|"recording"|"finalizing",
 takeID?: string, seconds: number, mode: string,
 lastEnding?: {takeID: string, result: TakeResult, remark?: string, endedAt: ISO8601}}
```

TakeResult uses Swift's enum encoding: `{"pasted":{}}`, `{"held":{}}`,
`{"failed":{}}`, `{"cancelled":{}}`, or
`{"rerouted":{"_0":"batch"|"rawText"}}`. Status carries neither audio nor text.

HistoryEntry is `{id:string, startedAt:ISO8601, stoppedAt:ISO8601-or-null,
outcome:string, mode:string}`. Outcomes are the engine's persisted TakeOutcome
values (including in-progress outcomes). Only explicit `text:true` adds
`text:string-or-null` containing final text. `last` always includes that field
from the newest ended take (pasted/rerouted/held/failed/cancelled); a later rerun does not
replace its original final text. In human mode `last` prints text only; no takes
or no final text produces empty output with exit 0.

History defaults to limit 20, accepts 1..100, and sorts by start time descending,
then ID descending. `result.before` is an opaque `<milliseconds>:<id>` cursor;
pass it unchanged to --before for an exclusive page boundary. Equal timestamps
use the ID tie-breaker, so no rows are skipped. Null means no rows. Legacy ISO
8601 --before values remain supported as exclusive time-only boundaries. The
engine search API keeps its old before: Date? argument and adds cursor: String?
with a default of nil, preserving the Mac callers.

Settings is the existing `VizierConfig.Settings` Codable object: `{mode:string,
modes:[Mode]}`. Mode contains id, name, transcriber, optional fallback, cleanup,
removeFillers and offlineFallback. `config get` excludes vocabulary and
replacements. `config set mode <id>` accepts only a defined mode, uses
ConfigStore's validated settings snapshot and comment-preserving SettingsEditor
path, and refuses a stale snapshot. It does not rewrite the settings file from
scratch. The take session reloads config according to its existing policy.

Check is `{name:string,status:"ok"|"warn"|"fail",detail:string,fix:string}`. The
checks are `runtime_dir`, `socket`, `config`, `history`, `libcurl`, `pw_record` (ok with
`parec` alone), `desktop_entry` (`warn` when `net.praxient.vizier.desktop`, which the GNOME and
KDE portals identify Vizier by, is in neither `$XDG_DATA_HOME/applications` nor an
`$XDG_DATA_DIRS` folder; the fix is `vizier setup`), `local_whisper` and `local_cleanup` (one per local server a mode uses:
a TCP connect to its loopback URL; `fail` when the active mode's own engine is down, `warn`
for a fallback or another mode; the fix names `whisper-server`, the `ggml-<model>.bin` file
and the download command), and `take_session`. Successful checks have fix:"". The session check fails when the
bootstrap control is in use and after an observed startup_not_ready refusal (recovery).
With a down daemon, that check reports daemon down. Startup readiness is otherwise
not exposed by TakeStatus; integration can refine that information later.
The library check initializes FoundationNetworking and uses the mapped libcurl's
`dlopen(RTLD_NOLOAD)` and `curl_version_info`, rather than the `curl` executable.
Versions below 8.11 fail the live-engine floor check; batch engines remain
available. Presence of pw-record does not prove microphone or desktop operation.
All checks are offline; config/history checks do not edit settings or history rows (SQLite may create its WAL index). When the daemon
is down or its socket is unsafe, doctor falls back to local checks so it can
explain the recovery path; help is also local. The in-daemon socket check validates
permissions, and the successful request itself proves daemon reachability.

## Exit and error contract

| Exit | Meaning |
|---|---|
| 0 | Success, including empty history/last |
| 1 | Storage, runtime, protocol-reply or other operational error |
| 2 | Usage, unknown command/argument, malformed/versioned/oversized request |
| 3 | Daemon not running; next is `vizier daemon` |
| 4 | State refusal or single-instance refusal |
| 5 | Doctor completed and one or more checks failed |

Client JSON stdout is exactly one envelope; daemon JSON streams ready and stopped envelopes. Human failures go to stderr. JSON
failures also produce a short stderr diagnostic; stdout remains parseable.
No styling is emitted, so pipes, NO_COLOR, CI and non-TTY use the same bytes.

| Error code | Meaning / next command |
|---|---|
| `already_recording` | start refused; `vizier stop` |
| `not_recording` | stop/cancel refused; `vizier start` |
| `busy_finalizing` | take still being delivered; `vizier status` |
| `startup_not_ready` | session startup incomplete (crash recovery running); `vizier doctor` |
| `shutting_down` | new command refused; `vizier daemon` |
| `daemon_busy` | connection cap reached; no command accepted; `vizier status` |
| `already_running` | lifetime lock held; `vizier status` |
| `daemon_not_running` | no listener; `vizier daemon` |
| `runtime_dir_unavailable` | unset/relative/unowned/unsafe runtime directory; unset/relative/unowned paths suggest `export XDG_RUNTIME_DIR=/run/user/$(id -u)`; a wrong mode suggests `chmod 700 "$XDG_RUNTIME_DIR"` |
| `socket_path_too_long` | path exceeds Unix limit; `vizier doctor` |
| `unsafe_socket`, `unsafe_lock`, `peer_refused` | unsafe local endpoint/lock/UID; `vizier doctor` |
| `socket_error` | socket operation failed; `vizier doctor`, or `vizier status` if acceptance is unknown |
| `invalid_reply` | version/ID/envelope/size mismatch; `vizier doctor` or `vizier history --limit 1` |
| `usage`, `unknown_command`, `invalid_args` | syntax/argument refused; corrected invocation or command help |
| `invalid_request`, `bad_version`, `request_too_large` | wire contract refused; `vizier --help` |
| `unknown_mode` | mode absent from settings; `vizier config get` |
| `storage_error`, `internal_error` | local read/write/bootstrap failed; `vizier doctor` |

Daemon sources run on Dispatch's main queue and enter MainActor explicitly.
Read sources service the listener and connections; write sources exist only while
replies are pending. A one-second timer enforces inactivity; there is no idle I/O
polling. Descriptors close after their sources have completed cancellation, so a
reused descriptor cannot lose a new readiness registration.

SIGINT and SIGTERM refuse new commands with shutting_down, stop listening, await
`TakeControl.quiesce(until: now + 5 seconds)`, and flush queued replies for up to
one second. Quiescence preserves and delivers an active take rather than cancelling
it. A fixed `audio_save_incomplete` stderr code records a missed deadline without
text. The owned socket is unlinked and flock is released last. A second signal
during draining forces exit. The systemd TimeoutStopSec must exceed six seconds
(`vizier setup` writes 15).

## Focused verification and mutation evidence

The Linux Swift Testing suite has 19 test functions (30 parameterized executions), plus a history cursor regression.
All use synthetic data and private temporary runtime roots. The targeted run uses
`testrun dictum l5 -- swift test --filter VizierCLITests --parallel --num-workers 8`.
Swift 6.4 requires `--parallel` alongside `--num-workers`.

Each test was observed failing under the following production-code mutations,
then the original code was restored. Detailed local logs and machine-readable
results live in `.build/l5-mutations/` and are not shipping assets.

| Test | Mutation that made it fail |
|---|---|
| roundTripPermissionsAndCommands | ping returns false; additionally invert peer UID comparison |
| runtimeRefusals (8 cases) | change runtime refusal code; change long-path refusal code; additionally bypass 0700 checks |
| secondDaemonCannotUnlinkLiveSocket | bypass lifetime flock acquisition |
| staleSocketReplacedAndUnsafePathRefused | skip stale socket unlink |
| splitAndJoinedLines | discard all buffered data after the first line |
| oversizeBadVersionMalformedAndDroppedClient | change oversize error code; additionally accept v=2 |
| stateRefusalMapping (4 cases) | replace TakeCommandError's raw code with an unrelated code |
| daemonDownExitsAndHelp | change daemon-down exit 3 to exit 1 |
| doctorJSONShape | rename the libcurl check; additionally bypass config parsing |
| historyPrivacyPaginationLastAndConfig | always include transcript text; additionally omit rerouted outcomes from last and truncate cursor milliseconds |
| shutdownQuiescesAndReleasesLock | bypass the session quiesce call |
| unsafeSocketAndLockPermissions | accept sockets with unsafe permissions |
| unknownArgumentsAreNotApplied | bypass unknown-argument validation |
| signalShutdown (SIGTERM/SIGINT) | change ready:true to false |

The independent owner test supplies a valid 0700 stat with a different UID; dropping
the owner guard now fails it. Capacity/deadline tests use a one-connection limit
and a 0.2-second idle deadline. New mutation proofs and before/after measurements
are retained locally in `.build/l5-review/`.

| Review regression | Mutation |
|---|---|
| runtimeOwnerBranchIsIndependentOfMode | remove UID validation |
| capacityAndIdleDeadline | remove capacity refusal; remove idle eviction |
| publicationWaitsForInitialization | publish during start before initialization |
| quiesceHoldsLockAndFlushesReply | bypass quiesce; bypass reply drain |
| localReadsAndCLIRecovery | disable local reads, version alias, equals flags or human ending |
| doctorJSONShape | treat unavailable bootstrap as a ready take session |
| historyCursorPagesEqualMillisecondsWithoutSkipping | remove equal-time tie handling |
| historyPrivacyPaginationLastAndConfig | omit the cursor in the history query |

Three three-second idle observations on a Linux debug build measured 6–7 CPU
ticks (2.0–2.3% of a core) and 1,375–1,378 thread context switches/s before the
change; afterward, zero measured CPU ticks and about two context switches/s.
CPU sampling has 10 ms resolution; zero does not mean literally no CPU use.
Thread context switches are a scheduling/wakeup proxy, not hardware wakeups.
The event-driven implementation schedules one inactivity timer per second.
No claim is made about macOS, real-desktop latency, or energy consumption.

Different-user SO_PEERCRED integration still needs a privileged harness. Synchronous
storage/doctor work on MainActor remains the acknowledged review note; it was not
expanded in this fix. The CLI's embedded version must be updated with VERSION at
release time.
