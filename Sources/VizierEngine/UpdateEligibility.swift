#if canImport(Security)
import Foundation
import Security

/// Whether this running copy of Vizier may run the production updater. Only a release build, signed
/// with a Developer ID Application certificate and still valid, may. A team identifier alone is not
/// enough: an Apple Development or any other team-issued certificate carries one too, so the check is
/// the code signing requirement Apple defines for Developer ID Application signatures. A contributor's
/// ad-hoc or development build must never offer to replace itself with the signed release.
public enum UpdateEligibility {
    /// Apple's anchor, the Developer ID intermediate CA (field 6.2.6) as certificate 1, and the
    /// Developer ID Application leaf (field 6.1.13).
    public static let developerIDRequirement =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"

    /// This process's own signature: valid, and satisfying `developerIDRequirement`.
    public static func currentProcessMayRunUpdater() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              let requirement = compile(developerIDRequirement)
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The signed code at `url` (a bundle or a binary) is valid and satisfies `requirementText`,
    /// by default `developerIDRequirement`. A requirement that does not compile is a refusal.
    public static func code(at url: URL, satisfies requirementText: String = developerIDRequirement) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              let requirement = compile(requirementText)
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    private static func compile(_ text: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }
}
#endif
