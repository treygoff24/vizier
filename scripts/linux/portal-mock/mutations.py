#!/usr/bin/env python3
"""Run under testrun; mutate only this lane's production files, restoring each in finally."""
import signal
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
LOGS = ROOT / '.build' / 'portal-mutation-logs'
BUILD = ['swift', 'build', '--build-tests', '-j', '16']
RUNNER = str(ROOT / 'scripts/linux/portal-mock/run.sh')


def run(command, log):
    with log.open('w') as out:
        result = subprocess.run(command, cwd=ROOT, stdout=out, stderr=subprocess.STDOUT)
    return result.returncode, log.read_text()


def replace(source, old, new):
    assert source.count(old) == 1, f'Expected one mutation target: {old[:100]}'
    return source.replace(old, new)


def late_subscription(source):
    start = source.index('        // Install and acknowledge the match before calling:')
    end = source.index('            return try await withThrowingTaskGroup', start)
    source = source[:start] + '''        var options = options
        options["handle_token"] = .string(token)
        var actualRequest = expected
        do {
            let reply = try await bus.call(interface: interface, member: member, arguments: args + [.dictionary(options)])
            actualRequest = reply.first?.string ?? expected
            guard actualRequest == expected else { throw PortalFailure.invalidResponse }
            try await Task.sleep(for: .milliseconds(100))
            let signals = try await bus.match(path: expected, interface: "org.freedesktop.portal.Request", member: "Response")
            defer { signals.cancel() }
''' + source[end:]
    return replace(source, 'timeout: Duration = .seconds(300)', 'timeout: Duration = .milliseconds(300)')


def skip_acknowledgement(source):
    start = source.index('            try await withThrowingTaskGroup(of: Bool.self)')
    end = source.index('            guard generation == epoch, clipboardEnabled', start)
    return source[:start] + source[end:]


def periodic_idle(source):
    source = replace(source, '    private var failed = false', '    private var failed = false\n    private var mutationPoller: DispatchSourceTimer?')
    return replace(source, '        queue.async { [weak self] in self?.pump() }\n    }\n    public static func open', '''        queue.async { [weak self] in
            guard let self else { return }
            self.pump()
            let poller = DispatchSource.makeTimerSource(queue: self.queue)
            poller.schedule(deadline: .now(), repeating: .milliseconds(10))
            poller.setEventHandler { [weak self] in self?.pump() }
            self.mutationPoller = poller
            poller.resume()
        }
    }
    public static func open''')


MUTATIONS = [
    ('idleConnectionsDoNotWakePeriodically', 'DBusConnection.swift', periodic_idle),
    ('typedTransportRoundTrip', 'DBusConnection.swift', lambda s: replace(s, 'Int32(b ? 1 : 0)', 'Int32(0)')),
    ('presenceDoesNotClaimConsentAndMissingInterfaceIsUnavailable', 'PortalRemoteDesktop.swift',
     lambda s: replace(s, 'available: session != nil && clipboardEnabled && keyboardEnabled', 'available: true')),
    ('responseBeforeReplyClipboardFDAndTokenPersistence', 'PortalClient.swift', late_subscription),
    ('keyOrderingAndAmbiguousFailureNeverThrowsForFallback', 'PortalRemoteDesktop.swift',
     lambda s: replace(s, 'let v: Int32 = keysym ? 0x76 : 47', 'let v: Int32 = keysym ? 0x77 : 47')),
    ('shortcutsRebindAndActivateOnMainActor', 'PortalGlobalShortcuts.swift',
     lambda s: replace(s, 'case "toggle": await onToggle()', 'case "toggle": await onCancel()')),
    ('sessionClosureRevokesDeliveryAndHotkeys', 'PortalRemoteDesktop.swift',
     lambda s: replace(s, 'clipboardEnabled = false; keyboardEnabled = false; text = Data()', 'text = Data()')),
    ('deniedConsentAndDeliveryNeverStartsDialog', 'PortalRemoteDesktop.swift',
     lambda s: replace(s, 'guard result["clipboard_enabled"]?.bool == true else { throw PortalFailure.clipboardDenied }', '// MUTATION: ignore clipboard consent')),
    ('portalRestartInvalidatesAndRegistersAgain', 'PortalRemoteDesktop.swift',
     lambda s: replace(s, 'await invalidate(observation: observation, closeSession: false)', '// MUTATION: do not revoke the vanished session')),
    ('registryAbsenceExplainsGNOMERequirement', 'PortalClient.swift',
     lambda s: replace(s, 'Registry.Register unavailable or rejected; GNOME may reject shortcuts without installed net.praxient.vizier.desktop', 'Identity unknown')),
    ('publicationRequiresOwnershipNotJustMethodReply', 'PortalRemoteDesktop.swift', skip_acknowledgement),
    ('foreignSignalsCannotRevokeActivateOrGrantConsent', 'DBusConnection.swift',
     lambda s: replace(s, 'guard let sender = box.library.getSender(message), String(cString: sender) == box.sender else { return 0 }', '// MUTATION: trust directed signals from any sender')),
    ('toggleOnlyBindingRemainsUsable', 'PortalGlobalShortcuts.swift',
     lambda s: replace(s, 'guard ids.contains("toggle") else', 'guard ids.contains("toggle"), ids.contains("cancel") else')),
    ('explicitKeysymRefusalFallsBackBeforeAnyKeyWasSent', 'PortalRemoteDesktop.swift',
     lambda s: replace(s, 'if index == 0, heldMethod == "NotifyKeyboardKeysym"', 'if index == 1, heldMethod == "NotifyKeyboardKeysym"')),
    ('invalidationDuringChordReleasesKeysAndClosesSession', 'PortalRemoteDesktop.swift',
     lambda s: replace(s, 'let keys = heldKeys.reversed()', 'let keys: [Int32] = []')),
    ('receivedFileDescriptorIsCloseOnExec', 'DBusConnection.swift',
     lambda s: replace(s, 'F_DUPFD_CLOEXEC, 3', 'F_DUPFD, 3')),
    ('futureOptionsDoNotDestroyClipboardSubscription', 'DBusConnection.swift',
     lambda s: replace(s, 'return .unsupported(String(UnicodeScalar(UInt8(bitPattern: type))))', 'throw DBusFailure.malformed')),
    ('concurrentRegistrationWaitsForOneFlight', 'PortalClient.swift',
     lambda s: replace(s, 'if let registration { flight = registration }', 'if registration != nil { throw PortalFailure.busy }')),
    ('unexpectedRequestHandleClosesReturnedDialog', 'PortalClient.swift',
     lambda s: replace(s, 'path: actualRequest, interface: "org.freedesktop.portal.Request", member: "Close"', 'path: expected, interface: "org.freedesktop.portal.Request", member: "Close"')),
    ('cancelledMatchesAreRemovedOnSuppliedConnection', 'DBusConnection.swift',
     lambda s: replace(s, 'box.slot = library.slotUnref(box.slot)', 'signals[id] = box // MUTATION: retain the native match')),
]


def main():
    LOGS.mkdir(parents=True, exist_ok=True)
    for name, filename, mutate in MUTATIONS:
        path = ROOT / 'Sources/VizierCLI/Adapters' / filename
        original = path.read_text()
        try:
            path.write_text(mutate(original))
            rc, _ = run(BUILD, LOGS / f'{name}-build.log')
            if rc:
                raise RuntimeError(f'{name}: mutation did not compile (see build log)')
            command = [RUNNER, 'swift', 'test', '--skip-build', '--parallel', '--num-workers', '8', '--filter', name]
            rc, output = run(command, LOGS / f'{name}-red.log')
            if rc == 0 or name not in output or 'failed' not in output.lower():
                raise RuntimeError(f'{name}: expected an observed test failure, got exit {rc}')
            print(f'RED PROVED: {name}', flush=True)
        finally:
            path.write_text(original)
    rc, _ = run(BUILD, LOGS / 'restored-build.log')
    if rc:
        raise RuntimeError('Restored build failed')
    command = [RUNNER, 'swift', 'test', '--skip-build', '--parallel', '--num-workers', '8', '--filter', 'Portal']
    rc, output = run(command, LOGS / 'restored-green.log')
    print(output, end='', flush=True)
    if rc or f'{len(MUTATIONS)} tests' not in output:
        raise RuntimeError('Restored portal suite did not pass all portal tests')
    print('All twenty mutations failed as expected; restored suite passed.', flush=True)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        main()
    except Exception as error:
        print(error, file=sys.stderr)
        sys.exit(1)
