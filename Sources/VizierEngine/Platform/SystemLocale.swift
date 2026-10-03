import Foundation

/// The language Vizier assumes when a config names none. On macOS it is Apple's speech model answer
/// (`AppleSpeechModel.preferredLocale()`, unchanged); elsewhere it is read from the environment the
/// way a POSIX program sees it, and a C, POSIX or missing locale names no language at all.
enum SystemLocale {
    static func preferred() -> Locale {
        #if canImport(Speech)
        AppleSpeechModel.preferredLocale()
        #else
        fromEnvironment(ProcessInfo.processInfo.environment)
        #endif
    }

    /// `LC_ALL` if set and non-empty, else `LANG`: `en_US.UTF-8` is `en_US`, `de_DE.UTF-8@euro` is
    /// `de_DE`. `C`, `POSIX` (with or without a codeset, so `C.UTF-8` too), an empty value and an
    /// unset one resolve to the root locale, whose identifier is empty and which has no language.
    /// Platform-neutral so the parsing is tested wherever the tests run.
    static func fromEnvironment(_ environment: [String: String]) -> Locale {
        let value = [environment["LC_ALL"], environment["LANG"]].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let name = String(value.prefix { $0 != "." && $0 != "@" })
        guard !name.isEmpty, name != "C", name != "POSIX" else { return Locale(identifier: "") }
        return Locale(identifier: name)
    }
}
