// Copied from VoiceInk v2.20 (https://github.com/Beingpax/VoiceInk, tag v2.20):
//   VoiceInk/Infrastructure/SystemIntegration/Lifecycle/UserSessionInputPolicy.swift
// VoiceInk is licensed under the GNU General Public License v3.0.

import CoreGraphics
import Foundation

/// Defines whether the current macOS user session is safe to receive global shortcuts.
enum UserSessionInputPolicy {
    // CGSession has no public constant for this long-standing WindowServer property.
    private static let screenIsLockedKey = "CGSSessionScreenIsLocked"

    static var allowsShortcutHandling: Bool {
        guard let properties = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }

        return allowsShortcutHandling(sessionProperties: properties)
    }

    static func allowsShortcutHandling(sessionProperties: [String: Any]) -> Bool {
        guard booleanValue(sessionProperties[kCGSessionOnConsoleKey as String]) == true else {
            return false
        }

        guard booleanValue(sessionProperties[kCGSessionLoginDoneKey as String]) == true else {
            return false
        }

        if booleanValue(sessionProperties[screenIsLockedKey]) == true {
            return false
        }

        return true
    }

    private static func booleanValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }

        return (value as? NSNumber)?.boolValue
    }
}
