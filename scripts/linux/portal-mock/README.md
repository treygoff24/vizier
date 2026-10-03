# Private portal mock

Activate Swift 6.4, build, then run only the portal tests:

```sh
. ~/.local/share/swiftly/env.sh
testrun dictum l6b-build -- swift build --build-tests -j 16
testrun dictum l6b -- scripts/linux/portal-mock/run.sh swift test --skip-build --parallel --num-workers 8 --filter Portal
```

The runner requires `dbus-run-session`, Python with `venv`, and pip access for
`dbus-next==0.2.3`. It creates the venv in `.build` and starts a private session
bus. Tests are disabled unless `VIZIER_PORTAL_MOCK` is set, require it to match
`DBUS_SESSION_BUS_ADDRESS`, and verify the mock control interface before
requesting consent. No container, libsystemd headers, or manifest changes are
needed on Debian 13. All text and restore tokens are synthetic.

## Protocol and review coverage

The mock replies to SetSelection immediately, acknowledges ownership after a
delay, and emits SelectionTransfer only on an explicit simulated paste request.
It passes a real Unix descriptor and reads back the selected bytes. A separate
attacker peer sends directed signals; tests assert the number actually sent
before checking that they were rejected. Restart releases the portal name and
acquires it on a new connection, so the replacement owner has a new unique name.

Publication returns only after an authenticated SelectionOwnerChanged confirms
`session_is_owner=true`; missing or false acknowledgements fail within two
seconds. Clipboard MIME types are text/plain;charset=utf-8, text/plain,
UTF8_STRING, STRING, and TEXT. Stale or unsupported transfers with a parsed
serial receive SelectionWriteDone(false).

Key delivery uses NotifyKeyboardKeysym first. An explicit UnknownMethod or
NotSupported reply to the first key permits keycode fallback. An ambiguous
failure or a failure after any accepted key permits no retry. Held keys are
released on cancellation and invalidation, and unusable live sessions are
closed. The portal cannot inspect the active layout; physical keycode fallback
still depends on layout. Toggle-only shortcut consent is usable; the probe
reports an unbound cancel shortcut and suggests a compositor binding. Dialog
response timeouts are five minutes.

The transport checks the actual sender locally. Portal matches resolve
GetNameOwner to a unique peer; NameOwnerChanged must come from
org.freedesktop.DBus. Owner changes invalidate consent, and new setup resolves
the replacement peer. Matches have owned native slots removed on cancellation,
including caller-supplied connections. Unknown extension values are skipped;
a malformed signal is discarded without finishing the subscription.

Read/write readiness sources and sd_bus_get_timeout drive sd-bus. No periodic
idle timer remains. The idle regression test samples Linux's per-thread
voluntary context switches over two seconds with two bus connections kept alive.
The old implementation measured 779; restored event-driven runs measured 5-7.
These are scheduler activity measurements, not direct battery measurements.
Reintroducing a 10 ms timer measured 806 and failed the idle assertion.

## Mutation verification

```sh
. ~/.local/share/swiftly/env.sh
testrun dictum l6b-mut --max 1800 -- python3 scripts/linux/portal-mock/mutations.py
```

The sweep runs one matching test per production mutation, restores sources in
`finally`, then rebuilds and runs all twenty portal tests. Logs go to
`.build/portal-mutation-logs/`. SIGTERM is handled to restore the source; SIGKILL
cannot execute cleanup. Do not forcibly kill a sweep while a mutation is active.

Twenty mutations were observed to fail their tests: periodic idle polling;
incorrect boolean encoding; readiness before consent; late Response
subscription; wrong V keysym; swapped toggle/cancel callback; ignored session
closure; ignored clipboard denial; ignored portal restart; missing Registry
diagnosis; omitted ownership wait; unauthenticated signals; requiring cancel
alongside toggle; disabled keysym fallback; omitted key releases; non-CLOEXEC fd
duplication; rejecting unknown extensions; registration reporting busy;
closing the predicted rather than returned request handle; and retained native
match slots. The late-subscription mutation shortens its response timeout only
for the red run.

## Limits and integration

This proves protocol signatures, file-descriptor transfer, sender rejection,
consent-state handling, lifecycle cleanup, and idle scheduling behavior. It does
not prove GNOME/KDE consent UI, installed desktop-file discovery, compositor
key injection, focused-app delivery, physical hotkeys, actual keyboard layout
behavior, restore-token persistence on a desktop, or secure-field protection.

The daemon must retain one RemoteDesktop instance for both clipboard and keys,
and call prepare() and GlobalShortcuts.start() only during setup/startup. Session
restart or denied restoration requires explicit setup; delivery never prepares
sessions. The packaging lane must install net.praxient.vizier.desktop. CLI/daemon
wiring and real-desktop verification remain coordinator work outside these files.

Primary references checked for this review:

- [systemd public ABI](https://raw.githubusercontent.com/systemd/systemd/main/src/systemd/sd-bus.h)
- [sd-bus readiness and absolute monotonic deadlines](https://raw.githubusercontent.com/systemd/systemd/main/man/sd_bus_get_fd.xml)
- [RemoteDesktop](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html)
- [Clipboard](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Clipboard.html)
- [GlobalShortcuts](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html)
- [Registry](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.host.portal.Registry.html)
