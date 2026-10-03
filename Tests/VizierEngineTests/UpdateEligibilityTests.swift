#if canImport(Security)
import Foundation
import Testing

@testable import VizierEngine

@Suite("UpdateEligibility")
struct UpdateEligibilityTests {
    @Test("the requirement is Apple's Developer ID Application requirement, exactly")
    func requirementText() {
        #expect(
            UpdateEligibility.developerIDRequirement
                == "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
        )
    }

    @Test("the test runner itself is not Developer ID signed and may not run the updater")
    func testRunnerRefused() {
        #expect(!UpdateEligibility.currentProcessMayRunUpdater())
    }

    @Test("a validly ad-hoc signed binary is refused")
    func adHocRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vizier-adhoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("adhoc")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        #expect(try codesign(["--force", "--sign", "-", binary.path]) == 0)

        // Preconditions: the copy carries a valid ad-hoc signature, so a refusal is about the
        // requirement and not about a broken or missing signature.
        #expect(try codesign(["--verify", "--strict", binary.path]) == 0)
        #expect(try codesignDisplay(binary).contains("Signature=adhoc"))

        #expect(!UpdateEligibility.code(at: binary))
    }

    @Test("an Apple platform binary meets Apple's anchor but not the Developer ID requirement")
    func appleSignedNotDeveloperID() {
        let tool = URL(fileURLWithPath: "/usr/bin/true")
        #expect(UpdateEligibility.code(at: tool, satisfies: "anchor apple"))
        #expect(!UpdateEligibility.code(at: tool))
    }

    @Test("a requirement that does not compile refuses")
    func malformedRequirement() {
        #expect(!UpdateEligibility.code(at: URL(fileURLWithPath: "/usr/bin/true"), satisfies: "anchor apple and ("))
    }

    private func codesign(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func codesignDisplay(_ url: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--display", "--verbose=2", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
