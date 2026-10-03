import Foundation

/// Scribe takes a bare ISO 639 language code. The config carries Apple's locale identifiers
/// ("en_US", "en-GB", "zh-Hant-TW"), so both Scribe adapters derive the code here.
enum ScribeLanguage {
    /// The language part of `identifier` ("en_US" -> "en", "zh-Hant-TW" -> "zh"), or nil when the
    /// identifier is empty or names no language, so the request leaves the field out and Scribe detects it.
    static func code(from identifier: String?) -> String? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespaces), !identifier.isEmpty else { return nil }
        guard let code = Locale(identifier: identifier).language.languageCode?.identifier, !code.isEmpty else { return nil }
        return code
    }
}
