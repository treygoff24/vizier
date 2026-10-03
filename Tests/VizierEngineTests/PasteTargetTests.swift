import VizierEngine
import Testing

@Suite struct PasteTargetTests {
    private func facts(_ focus: PasteTargetFacts.FocusQuery, app: String? = "com.example.app",
                       regular: Bool = true, windows: Int? = nil) -> PasteTargetFacts {
        PasteTargetFacts(frontmostApp: true, bundleID: app, focus: focus, isRegularApp: regular, windowCount: windows)
    }

    /// A terminal app answers with an AXTextArea whose AXIsEditable is unsupported; that must paste.
    @Test func theTerminalTextAreaWithoutEditableInfoPastes() {
        #expect(PasteDecision.decide(facts(.element(role: "AXTextArea"), app: "com.example.terminal")) == .paste)
        #expect(PasteDecision.decide(facts(.element(role: nil))) == .paste)
    }

    /// With the History window focused, a paste would land in Vizier's own search field.
    @Test func vizierItselfHoldsEvenWithAFocusedTextField() {
        #expect(PasteDecision.decide(facts(.element(role: "AXTextField"), app: "net.praxient.dictum"))
                == .hold(reason: "Vizier itself had focus"))
        #expect(PasteDecision.decide(facts(.noValue, app: "net.praxient.dictum", windows: 1))
                == .hold(reason: "Vizier itself had focus"))
    }

    @Test func noFrontmostAppHolds() {
        let decision = PasteDecision.decide(PasteTargetFacts(frontmostApp: false, bundleID: nil, focus: .element(role: "AXTextArea"), isRegularApp: true, windowCount: nil))
        #expect(decision == .hold(reason: "no frontmost app"))
    }

    /// Safari and Electron apps report no focused element while showing a window.
    @Test func aRegularAppWithAWindowPastesWithoutAFocusedElement() {
        #expect(PasteDecision.decide(facts(.noValue, windows: 1)) == .paste)
    }

    /// Photos timed out the focus query at 300 ms with a window open.
    @Test func aRegularAppWithAWindowPastesWhenTheFocusQueryTimesOut() {
        #expect(PasteDecision.decide(facts(.error(-25204), windows: 1)) == .paste)
    }

    @Test func aRegularAppWhoseWindowsQueryFailedPastes() {
        #expect(PasteDecision.decide(facts(.noValue, windows: nil)) == .paste)
    }

    @Test func aRegularAppWithNoWindowsAndNoFocusHolds() {
        #expect(PasteDecision.decide(facts(.noValue, app: "com.example.app", windows: 0))
                == .hold(reason: "no focused element and no windows in com.example.app"))
    }

    /// A background helper: accessory policy, zero windows, no focused element.
    @Test func aWindowlessBackgroundHelperHolds() {
        #expect(PasteDecision.decide(facts(.noValue, app: "com.example.helper", regular: false, windows: 0))
                == .hold(reason: "no focused element in com.example.helper, a background app"))
    }

    /// Raycast-style launchers are accessory apps with a real focused field.
    @Test func anAccessoryAppWithAFocusedElementPastes() {
        #expect(PasteDecision.decide(facts(.element(role: "AXTextField"), regular: false, windows: nil)) == .paste)
    }

    @Test(arguments: [Int32(-25204), -25211, -25202, -25205])
    func anAccessoryAppWhoseFocusQueryFailsHolds(code: Int32) {
        #expect(PasteDecision.decide(facts(.error(code), app: nil, regular: false, windows: nil))
                == .hold(reason: "focus query failed (\(code)) in an app with no bundle id, a background app"))
    }

    /// Dictate, switch apps before the text lands, and it pasted into the new app.
    @Test func switchingAppsAfterTheStopHolds() {
        var f = facts(.element(role: "AXTextArea"))
        f.frontmostPID = 200
        f.pidAtStop = 100
        #expect(PasteDecision.decide(f) == .hold(reason: PasteDecision.focusMoved))
    }

    @Test func stayingInTheSameAppPastes() {
        var f = facts(.element(role: "AXTextArea"))
        f.frontmostPID = 100
        f.pidAtStop = 100
        #expect(PasteDecision.decide(f) == .paste)
    }

    /// An unknown app at the stop tap must not block a paste.
    @Test func anUnknownAppAtTheStopPastes() {
        var f = facts(.element(role: "AXTextArea"))
        f.frontmostPID = 200
        f.pidAtStop = nil
        #expect(PasteDecision.decide(f) == .paste)
    }

    // Password fields: never type dictated text into one.

    @Test func aFocusedPasswordFieldHolds() {
        #expect(PasteDecision.decide(facts(.element(role: "AXTextField", subrole: "AXSecureTextField"), windows: 1))
                == .hold(reason: PasteDecision.secureField))
        // An accessory launcher with a real field pastes, but not into its password field.
        #expect(PasteDecision.decide(facts(.element(role: "AXTextField", subrole: "AXSecureTextField"), regular: false))
                == .hold(reason: PasteDecision.secureField))
        #expect(PasteDecision.decide(facts(.element(role: "AXTextField", subrole: "AXSearchField"))) == .paste)
    }

    /// Secure event input with a focus that can't be read: a password field the app does not
    /// describe may have focus, so the paste holds.
    @Test func secureEventInputHoldsWhenTheFocusCannotBeRead() {
        for focus: PasteTargetFacts.FocusQuery in [.noValue, .error(-25204)] {
            var f = facts(focus, windows: 1)
            f.secureEventInput = true
            #expect(PasteDecision.decide(f) == .hold(reason: PasteDecision.secureInput), "\(focus)")
        }
    }

    /// A terminal with Secure Keyboard Entry keeps secure input on while its readable text area
    /// has focus: that pastes. A password field still holds.
    @Test func secureEventInputWithAReadableFocusPastes() {
        for focus: PasteTargetFacts.FocusQuery in [.element(role: "AXTextArea"), .element(role: nil), .element(role: "AXTextField", subrole: "AXSearchField")] {
            var f = facts(focus, app: "com.example.terminal", windows: 1)
            f.secureEventInput = true
            #expect(PasteDecision.decide(f) == .paste, "\(focus)")
        }
        var password = facts(.element(role: "AXTextField", subrole: "AXSecureTextField"), windows: 1)
        password.secureEventInput = true
        #expect(PasteDecision.decide(password) == .hold(reason: PasteDecision.secureField))
    }

    /// The last look before the keystroke: focus moved into a password field during the pause,
    /// secure input is on with a focus that can't be read, or the user switched apps.
    @Test func theFinalCheckHoldsForAPasswordFieldUnreadableSecureInputOrAnotherApp() {
        let secure = PasteTargetFacts.FocusQuery.element(role: nil, subrole: "AXSecureTextField")
        #expect(PasteDecision.finalCheck(frontmostPID: 100, pidAtStop: 100, focus: secure, secureEventInput: false)
                == .hold(reason: PasteDecision.secureField))
        for unreadable: PasteTargetFacts.FocusQuery? in [nil, .noValue, .error(-25204)] {
            #expect(PasteDecision.finalCheck(frontmostPID: 100, pidAtStop: 100, focus: unreadable, secureEventInput: true)
                    == .hold(reason: PasteDecision.secureInput), "\(String(describing: unreadable))")
        }
        #expect(PasteDecision.finalCheck(frontmostPID: 100, pidAtStop: 100, focus: .element(role: "AXTextArea"), secureEventInput: true) == .paste)
        #expect(PasteDecision.finalCheck(frontmostPID: 200, pidAtStop: 100, focus: .element(role: nil), secureEventInput: false)
                == .hold(reason: PasteDecision.focusMoved))
    }

    /// Editability and a readable focus are never required: an unreadable focus still pastes.
    @Test func theFinalCheckPastesWhenNothingIsWrong() {
        for focus: PasteTargetFacts.FocusQuery? in [nil, .noValue, .error(-25204), .element(role: nil), .element(role: nil, subrole: "AXSearchField")] {
            #expect(PasteDecision.finalCheck(frontmostPID: 100, pidAtStop: 100, focus: focus, secureEventInput: false) == .paste, "\(String(describing: focus))")
        }
        #expect(PasteDecision.finalCheck(frontmostPID: 100, pidAtStop: nil, focus: nil, secureEventInput: false) == .paste)
    }
}
