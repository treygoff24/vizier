import Darwin
import Foundation
import Testing
@testable import Vizier
@testable import VizierEngine

/// The launch gate in `main`: another running copy stops the launch before the migration runs,
/// and a migration outcome that needs the user stops it before anything is opened or created.
@Suite struct StartupGateTests {
    private let me: pid_t = 500
    private let dictum = StartupGate.RunningCopy(pid: 400, name: "Dictum", path: "/Users/someone/Applications/Dictum.app")
    private let moved = UserDataMigration.Outcome.moved(from: "Library/Application Support/Dictum", to: "Library/Application Support/Vizier")

    /// Runs the gate with a scripted list of running copies (one answer per lookup, the last one
    /// repeating) and a migration that records that it ran.
    private func gate(_ lookups: [[StartupGate.RunningCopy]], migration: [UserDataMigration.Outcome] = []) -> (StartupGate.Stop?, migrated: Bool, pauses: Int) {
        var answers = lookups
        var migrated = false
        var pauses = 0
        let stop = StartupGate.check(
            ownPID: me,
            runningCopies: { answers.count > 1 ? answers.removeFirst() : answers[0] },
            pause: { pauses += 1 },
            migrate: { migrated = true; return migration })
        return (stop, migrated, pauses)
    }

    @Test func anotherRunningCopyStopsTheLaunchBeforeTheMigrationRuns() {
        let (stop, migrated, _) = gate([[dictum]], migration: [moved])
        #expect(stop == .anotherCopyRunning(dictum))
        #expect(!migrated)
    }

    @Test func thisProcessAloneIsNoOtherCopy() {
        let (stop, migrated, pauses) = gate([[StartupGate.RunningCopy(pid: me, name: "Vizier", path: nil)]], migration: [moved])
        #expect(stop == nil)
        #expect(migrated)
        #expect(pauses == 0)
    }

    @Test func aCopyThatQuitsWithinTheLookupsLetsTheLaunchGoOn() {
        // An update's relaunch: the old process is still listed for a moment, then gone.
        let (stop, migrated, pauses) = gate([[dictum], [dictum], []])
        #expect(stop == nil)
        #expect(migrated)
        #expect(pauses == 2)
    }

    @Test func aCopyStillThereAfterEveryLookupCounts() {
        let (stop, migrated, pauses) = gate([[dictum]])
        #expect(stop == .anotherCopyRunning(dictum))
        #expect(!migrated)
        #expect(pauses == StartupGate.lookups - 1)
    }

    @Test func nothingToMoveOrAFinishedMoveLetsTheLaunchGoOn() {
        #expect(gate([[]], migration: []).0 == nil)
        #expect(gate([[]], migration: [moved, .moved(from: ".config/dictum", to: ".config/vizier")]).0 == nil)
        #expect(gate([[]], migration: [.oldEmpty(old: ".config/dictum", new: ".config/vizier")]).0 == nil)
    }

    @Test func aFailedOrConflictingMoveStopsTheLaunchWithOnlyTheProblemsListed() {
        let failed = UserDataMigration.Outcome.failed(from: ".config/vizier/dictum.jsonc", to: ".config/vizier/vizier.jsonc", errno: EACCES)
        #expect(gate([[]], migration: [moved, failed]).0 == .migrationNeedsAttention([failed]))
        let both = UserDataMigration.Outcome.bothPresent(old: "Library/Application Support/Dictum", new: "Library/Application Support/Vizier")
        #expect(gate([[]], migration: [both]).0 == .migrationNeedsAttention([both]))
    }

    @Test func theMessagesNameTheOtherCopyAndTheFoldersInvolved() {
        let home = "/Users/someone"
        let running = StartupGate.message(for: .anotherCopyRunning(dictum), home: home)
        #expect(running.body.contains("Dictum (~/Applications/Dictum.app)"))
        #expect(running.body.contains("Quit the other copy"))
        #expect(running.items.isEmpty)

        let stuck = StartupGate.message(for: .migrationNeedsAttention([
            .bothPresent(old: "Library/Application Support/Dictum", new: "Library/Application Support/Vizier"),
            .failed(from: ".config/dictum", to: ".config/vizier", errno: EACCES),
        ]), home: home)
        #expect(stuck.body.contains("Both ~/Library/Application Support/Dictum and ~/Library/Application Support/Vizier exist"))
        #expect(stuck.body.contains("~/.config/dictum could not be renamed to ~/.config/vizier (Permission denied)"))
        #expect(stuck.items == [
            "/Users/someone/Library/Application Support/Dictum", "/Users/someone/Library/Application Support/Vizier",
            "/Users/someone/.config/dictum",
        ])
    }
}
