@testable import VizierEngine
import Foundation
import Testing
@testable import Vizier

@Suite struct ModePickerTests {
    private let store: ConfigStore

    init() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vizier-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = ConfigStore(directory: dir)
        try store.writeStarterFilesIfMissing()
    }

    private func text() throws -> String { try String(contentsOf: store.settingsURL, encoding: .utf8) }

    @Test func choosingAModeWritesOnlyThatValueAndReadsBack() throws {
        let picker = ModePickerModel(config: store)
        let original = try text()
        let other = try #require(picker.modes.first { $0.id != picker.activeModeID })
        picker.select(other.id)
        #expect(picker.activeModeID == other.id)
        #expect(picker.note == nil)
        // The file on disk, loaded fresh, agrees, and everything else in it is byte for byte as it was.
        #expect(store.load().config.settings.mode == other.id)
        let edited = try text()
        #expect(edited != original)
        let changed = zip(original.split(separator: "\n", omittingEmptySubsequences: false), edited.split(separator: "\n", omittingEmptySubsequences: false))
            .filter { $0 != $1 }
        #expect(changed.count == 1)
        #expect(changed.first?.1.contains(SettingsEditor.quoted(other.id)) == true)
        #expect(original.split(separator: "\n", omittingEmptySubsequences: false).count == edited.split(separator: "\n", omittingEmptySubsequences: false).count)
        let reread = ModePickerModel(config: store)
        #expect(reread.activeModeID == other.id)
    }

    @Test func aFileEditedSinceItWasReadKeepsTheEditAndStillTakesTheChoice() throws {
        let picker = ModePickerModel(config: store)
        let other = try #require(picker.modes.first { $0.id != picker.activeModeID })
        let note = "// a note an agent left\n"
        try Data((try text() + note).utf8).write(to: store.settingsURL)
        picker.select(other.id)
        #expect(picker.activeModeID == other.id)
        #expect(picker.note == nil)
        #expect(try text().hasSuffix(note))
        #expect(store.load().config.settings.mode == other.id)
    }

    @Test func aFileThatNoLongerParsesIsLeftAloneAndTheNoteSaysWhy() throws {
        let picker = ModePickerModel(config: store)
        let other = try #require(picker.modes.first { $0.id != picker.activeModeID })
        let before = picker.activeModeID
        let broken = "{ this is not settings"
        try Data(broken.utf8).write(to: store.settingsURL)
        picker.select(other.id)
        #expect(try text() == broken)
        #expect(picker.activeModeID == before)
        #expect(picker.note?.hasPrefix("Could not switch") == true)
    }

    @Test func aMissingFileShowsNoModesAndAReason() throws {
        try FileManager.default.removeItem(at: store.settingsURL)
        let picker = ModePickerModel(config: store)
        #expect(picker.modes.isEmpty)
        #expect(picker.note != nil)
    }
}

@Suite struct WordsFilesTests {
    @Test func openingEitherFileWritesTheStarterFirstAndOpensItsPath() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vizier-words-\(UUID().uuidString)", directoryHint: .isDirectory)
        let config = ConfigStore(directory: dir)
        let opener = FakeFileOpener()
        let words = WordsFiles(config: config, opener: opener)
        words.openVocabulary()
        words.openReplacements()
        #expect(opener.opened == [config.vocabularyURL, config.replacementsURL])
        #expect(FileManager.default.fileExists(atPath: config.vocabularyURL.path))
        #expect(FileManager.default.fileExists(atPath: config.replacementsURL.path))
    }
}

@Suite struct AccountKeyTests {
    private func model(store: InMemoryKeyStore = InMemoryKeyStore(), result: KeyTestResult = .passed, saved: String? = nil) -> AccountKeyModel {
        AccountKeyModel(provider: .elevenLabs, store: store, tester: RecordingTester(result: result), readSaved: { _ in saved })
    }

    final class RecordingTester: KeyTesting, @unchecked Sendable {
        let result: KeyTestResult
        private(set) var keys: [String] = []
        init(result: KeyTestResult) { self.result = result }
        func test(_ provider: Engines.KeyAccount, key: String) async -> KeyTestResult { keys.append(key); return result }
    }

    @Test func savingStoresTheTrimmedKeyUnderTheEnginesAccountAndClearsTheField() {
        let store = InMemoryKeyStore()
        let model = model(store: store)
        #expect(!model.canSave)
        model.draft = "  sk-secret-123 \n"
        model.save()
        #expect(store.keys == ["elevenlabs": "sk-secret-123"])
        #expect(model.draft == "")
        #expect(model.hasSavedKey)
    }

    @Test func aFailedSaveKeepsTheDraftAndSaysSo() {
        let store = InMemoryKeyStore()
        store.failure = Keychain.Failure(status: -25293)
        let model = model(store: store)
        model.draft = "abc"
        model.save()
        #expect(model.draft == "abc")
        #expect(!model.hasSavedKey)
        #expect(model.saveError?.hasPrefix("Could not save") == true)
    }

    @Test func testingChecksTheTypedKeyBeforeAnythingIsSaved() async {
        let tester = RecordingTester(result: .rejected)
        let model = AccountKeyModel(provider: .gemini, store: InMemoryKeyStore(), tester: tester, readSaved: { _ in "saved-one" })
        model.draft = "typed-one"
        await model.runTest()
        #expect(tester.keys == ["typed-one"])
        #expect(model.test == .finished(.rejected))
    }

    @Test func withNothingTypedTestingChecksTheSavedKey() async {
        let tester = RecordingTester(result: .passed)
        let store = InMemoryKeyStore(keys: ["gemini": "saved-one"])
        let model = AccountKeyModel(provider: .gemini, store: store, tester: tester, readSaved: { store.keys[$0] })
        await model.runTest()
        #expect(tester.keys == ["saved-one"])
        #expect(model.test == .finished(.passed))
    }

    @Test func withNoKeyAtAllTestingIsUnavailable() async {
        let tester = RecordingTester(result: .passed)
        let model = AccountKeyModel(provider: .gemini, store: InMemoryKeyStore(), tester: tester, readSaved: { _ in nil })
        #expect(!model.canTest)
        await model.runTest()
        #expect(tester.keys.isEmpty)
        #expect(model.test == .idle)
    }

    /// A tester whose answers are held until the test releases them, in any order.
    final class GatedTester: KeyTesting, @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [(key: String, resume: CheckedContinuation<KeyTestResult, Never>)] = []
        var pending: Int { lock.withLock { waiting.count } }
        func test(_ provider: Engines.KeyAccount, key: String) async -> KeyTestResult {
            await withCheckedContinuation { continuation in lock.withLock { waiting.append((key, continuation)) } }
        }
        func release(key: String, with result: KeyTestResult) {
            let entry = lock.withLock { () -> CheckedContinuation<KeyTestResult, Never>? in
                guard let index = waiting.firstIndex(where: { $0.key == key }) else { return nil }
                return waiting.remove(at: index).resume
            }
            entry?.resume(returning: result)
        }
    }

    private func settle(_ tester: GatedTester, pending: Int) async {
        for _ in 0..<200 where tester.pending < pending { await Task.yield() }
        #expect(tester.pending == pending) // precondition: the calls really are in flight
    }

    @Test func aTestFinishingAfterTheKeyWasEditedDoesNotShowItsResult() async {
        let tester = GatedTester()
        let model = AccountKeyModel(provider: .gemini, store: InMemoryKeyStore(), tester: tester, readSaved: { _ in nil })
        model.draft = "old-key"
        let running = Task { await model.runTest() }
        await settle(tester, pending: 1)
        #expect(model.test == .testing)
        model.draft = "new-key"
        #expect(model.test == .idle)
        tester.release(key: "old-key", with: .passed)
        await running.value
        #expect(model.test == .idle)
    }

    @Test func twoTestsFinishingOutOfOrderLeaveTheNewestResult() async {
        let tester = GatedTester()
        let model = AccountKeyModel(provider: .gemini, store: InMemoryKeyStore(), tester: tester, readSaved: { _ in nil })
        model.draft = "first"
        let older = Task { await model.runTest() }
        await settle(tester, pending: 1)
        model.draft = "second"
        let newer = Task { await model.runTest() }
        await settle(tester, pending: 2)
        tester.release(key: "second", with: .passed)
        await newer.value
        #expect(model.test == .finished(.passed))
        tester.release(key: "first", with: .rejected) // the stale answer arrives last
        await older.value
        #expect(model.test == .finished(.passed))
    }

    @Test func savingWhileATestIsRunningDropsItsResult() async {
        let tester = GatedTester()
        let model = AccountKeyModel(provider: .gemini, store: InMemoryKeyStore(), tester: tester, readSaved: { _ in nil })
        model.draft = "key"
        let running = Task { await model.runTest() }
        await settle(tester, pending: 1)
        model.save()
        tester.release(key: "key", with: .rejected)
        await running.value
        #expect(model.test == .idle)
    }

    @Test func aSavedKeyIsNeverPutBackInTheField() {
        let model = AccountKeyModel(provider: .gemini, store: InMemoryKeyStore(keys: ["gemini": "saved-one"]), tester: FakeKeyTester(), readSaved: { _ in "saved-one" })
        #expect(model.hasSavedKey)
        #expect(model.draft == "")
    }
}

@Suite struct NetworkKeyTesterTests {
    @Test func elevenLabsAsksForTheUserWithTheKeyInItsHeader() throws {
        let request = try #require(NetworkKeyTester.request(for: .elevenLabs, key: "k1"))
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/user")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "k1")
    }

    @Test func geminiListsModelsAndTheKeyNeverEntersTheURL() throws {
        let request = try #require(NetworkKeyTester.request(for: .gemini, key: "k2"))
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "generativelanguage.googleapis.com")
        #expect(request.url?.path == "/v1beta/models")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "k2")
        #expect(request.url?.absoluteString.contains("k2") == false)
    }

    @Test func statusCodesMapToPassRejectedOrUnreachable() {
        #expect(NetworkKeyTester.result(forStatus: 200) == .passed)
        for rejected in [400, 401, 403] { #expect(NetworkKeyTester.result(forStatus: rejected) == .rejected) }
        #expect(NetworkKeyTester.result(forStatus: 429) == .unreachable("the service answered 429"))
        #expect(NetworkKeyTester.result(forStatus: 503) == .unreachable("the service answered 503"))
    }

    @Test func elevenLabsTellsAKeyWithoutUserReadApartFromABadKey() {
        let missing = Data(#"{"detail":{"status":"missing_permissions","message":"user_read"}}"#.utf8)
        #expect(NetworkKeyTester.result(forStatus: 403, provider: .elevenLabs) == .lacksPermission)
        #expect(NetworkKeyTester.result(forStatus: 401, body: missing, provider: .elevenLabs) == .lacksPermission)
        #expect(NetworkKeyTester.result(forStatus: 401, body: Data(#"{"detail":{"status":"invalid_api_key"}}"#.utf8), provider: .elevenLabs) == .rejected)
        #expect(NetworkKeyTester.result(forStatus: 401, provider: .elevenLabs) == .rejected)
        // Gemini has no such case: a refusal is a refusal.
        #expect(NetworkKeyTester.result(forStatus: 403, provider: .gemini) == .rejected)
        #expect(KeyTestResult.lacksPermission.message.contains("Transcription may still work"))
    }

    @Test func aTestSendsTheRequestAndReadsTheStatus() async {
        let seen = LockedBox<URLRequest?>(nil)
        let ok = NetworkKeyTester(fetch: { request in
            seen.value = request
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(await ok.test(.elevenLabs, key: " k3 \n") == .passed)
        #expect(seen.value?.value(forHTTPHeaderField: "xi-api-key") == "k3")
        let rejected = NetworkKeyTester(fetch: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        #expect(await rejected.test(.elevenLabs, key: "bad") == .rejected)
        let offline = NetworkKeyTester(fetch: { _ in throw URLError(.notConnectedToInternet) })
        if case .unreachable = await offline.test(.gemini, key: "k") {} else { Issue.record("a network error is unreachable, not rejected") }
        // An empty key never reaches the network.
        let never = NetworkKeyTester(fetch: { _ in Issue.record("no request for an empty key"); throw URLError(.cancelled) })
        #expect(await never.test(.gemini, key: "  ") == .rejected)
    }
}

nonisolated final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite struct SpeechModelModelTests {
    @Test func refreshReadsTheSourcesStatus() async {
        for (status, expected) in [(SpeechModelStatus.installed, SpeechModelModel.State.installed), (.notInstalled, .notInstalled), (.unsupportedLocale, .unsupported)] {
            let model = SpeechModelModel(source: FakeSpeechModelSource(status: status))
            #expect(model.state == .checking)
            await model.refresh()
            #expect(model.state == expected)
        }
    }

    @Test func aDownloadEndsInstalledAndTheSourceIsAskedOnce() async {
        let source = FakeSpeechModelSource(status: .notInstalled)
        let model = SpeechModelModel(source: source)
        await model.refresh()
        await model.download()
        #expect(model.state == .installed)
        #expect(source.installCount == 1)
        await model.download() // already installed: nothing to do
        #expect(source.installCount == 1)
    }

    @Test func aFailedDownloadShowsTheFailureAndCanBeRetried() async {
        struct Boom: Error, CustomStringConvertible { var description: String { "no network" } }
        let source = FakeSpeechModelSource(status: .notInstalled, installError: Boom())
        let model = SpeechModelModel(source: source)
        await model.refresh()
        await model.download()
        #expect(model.state == .failed("no network"))
        await model.download()
        #expect(source.installCount == 2)
    }

    @Test func aProgressReportThatArrivesAfterTheDownloadEndedDoesNotUndoIt() async throws {
        struct LateProgress: SpeechModelSource {
            func preferredLocale() -> Locale { Locale(identifier: "en_US") }
            func status(for locale: Locale) async -> SpeechModelStatus { .notInstalled }
            func install(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(40))
                    progress(0.9)
                }
            }
        }
        let model = SpeechModelModel(source: LateProgress())
        await model.refresh()
        await model.download()
        #expect(model.state == .installed)
        try await Task.sleep(for: .milliseconds(150)) // the late report has been delivered by now
        #expect(model.state == .installed)
    }

    @Test func aDownloadAfterTheLanguageChangedFetchesNothingAndShowsTheNewLanguage() async {
        let source = LanguageSource(language: { "en_US" }, installed: [])
        let model = SpeechModelModel(source: source)
        await model.refresh()
        #expect(model.locale.identifier == "en_US" && model.state == .notInstalled)
        // The active mode moves to French while the pane still shows English.
        source.language = { "fr_FR" }
        await model.download()
        #expect(source.installed.isEmpty)
        #expect(model.locale.identifier == "fr_FR")
        #expect(model.state == .notInstalled)
        // The button now stands for French, and fetches French.
        await model.download()
        #expect(source.installed == ["fr_FR"])
        #expect(model.state == .installed)
    }

    @Test func theLanguageIsNamedInWords() {
        let model = SpeechModelModel(source: FakeSpeechModelSource(status: .installed, locale: Locale(identifier: "en_US")))
        #expect(model.languageName.contains("English"))
    }
}

@Suite struct OnboardingModelTests {
    private func make(mic: PermissionState = .notAsked, accessibility: Bool = false, speech: SpeechModelModel.State = .notInstalled) -> (OnboardingModel, FakePermissions, AppPreferences) {
        let probe = FakePermissions(mic: mic, accessibility: accessibility)
        let name = "vizier-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let preferences = AppPreferences(defaults: defaults)
        let model = OnboardingModel(
            permissions: PermissionsModel(probe: probe),
            speech: SpeechModelModel(source: FakeSpeechModelSource(status: .notInstalled), state: speech),
            preferences: preferences, accounts: [])
        return (model, probe, preferences)
    }

    @Test func theWalkRunsWelcomeToPracticeAndBack() {
        let (model, _, _) = make()
        #expect(model.step == .welcome && model.isFirst)
        var seen: [OnboardingModel.Step] = [model.step]
        while !model.isLast { model.next(); seen.append(model.step) }
        #expect(seen == [.welcome, .microphone, .accessibility, .speechModel, .hotkey, .accuracy, .practice])
        model.back()
        #expect(model.step == .accuracy)
    }

    @Test func aStepIsSatisfiedOnlyWhenItsPermissionOrModelIsInPlace() {
        let (model, probe, _) = make()
        model.step = .microphone
        #expect(!model.isSatisfied)
        probe.micState = .granted
        model.permissions.refresh()
        #expect(model.isSatisfied)
        model.step = .accessibility
        #expect(!model.isSatisfied)
        probe.accessibility = true
        model.permissions.refresh() // the step polls; the grant shows up without a click
        #expect(model.isSatisfied)
        model.step = .speechModel
        #expect(!model.isSatisfied)
    }

    @Test func aGrantSeenWhileTheAccessibilityStepShowsBringsTheWindowBackOnce() {
        let (model, probe, _) = make(mic: .granted)
        var calls = 0
        model.onAccessibilityGranted = { calls += 1 }
        model.step = .accessibility
        model.pollPermissions()
        #expect(calls == 0) // nothing changed yet
        probe.accessibility = true
        model.pollPermissions()
        #expect(calls == 1 && model.isSatisfied)
        model.pollPermissions()
        #expect(calls == 1) // only the change, not every poll after it

        let (other, otherProbe, _) = make(mic: .granted)
        var otherCalls = 0
        other.onAccessibilityGranted = { otherCalls += 1 }
        other.step = .hotkey
        otherProbe.accessibility = true
        other.pollPermissions()
        #expect(otherCalls == 0) // a grant on another step pulls nothing forward
        #expect(other.permissions.accessibility)
    }

    @Test func theSpeechStepIsSatisfiedByAnInstalledModelOrAnUnsupportedLanguage() {
        for state: SpeechModelModel.State in [.installed, .unsupported] {
            let (model, _, _) = make(speech: state)
            model.step = .speechModel
            #expect(model.isSatisfied)
        }
        let (downloading, _, _) = make(speech: .downloading(0.5))
        downloading.step = .speechModel
        #expect(!downloading.isSatisfied)
    }

    @Test func finishingMarksOnboardingDoneAndAsksTheWindowToClose() {
        let (model, _, preferences) = make()
        var closed = 0
        model.onFinish = { closed += 1 }
        #expect(!preferences.onboardingDone)
        model.finish()
        #expect(preferences.onboardingDone)
        #expect(closed == 1)
    }

    private func armed(_ model: OnboardingModel) -> Box<((String) -> Void)?> {
        let box = Box<((String) -> Void)?>(nil)
        model.setPracticeSink = { box.value = $0 }
        return box
    }
    final class Box<T> { var value: T; init(_ value: T) { self.value = value } }

    @Test func thePracticeSinkIsArmedOnlyWhileThePracticeStepShows() {
        let (model, _, _) = make()
        let sink = armed(model)
        model.step = .accuracy
        #expect(sink.value == nil)
        model.step = .practice
        #expect(sink.value != nil)
        model.back()
        #expect(sink.value == nil)
    }

    @Test func aPracticeTakeFillsTheResultAndOnlyThenIsTheStepSatisfied() throws {
        let (model, _, _) = make()
        let sink = armed(model)
        model.step = .practice
        #expect(!model.isSatisfied && model.practiceResult == nil)
        let deliver = try #require(sink.value)
        deliver("Hello there.")
        #expect(model.practiceResult == "Hello there.")
        #expect(model.isSatisfied)
    }

    @Test func leavingAndReturningToPracticeClearsTheOldResult() throws {
        let (model, _, _) = make()
        let sink = armed(model)
        model.step = .practice
        let deliver = try #require(sink.value)
        deliver("one")
        model.back()
        model.next()
        #expect(model.practiceResult == nil)
    }

    @Test func finishingOrClosingTheWindowDisarmsThePracticeSink() {
        let (finishing, _, _) = make()
        let first = armed(finishing)
        finishing.step = .practice
        finishing.finish()
        #expect(first.value == nil)
        let (closing, _, _) = make()
        let second = armed(closing)
        closing.step = .practice
        #expect(second.value != nil) // precondition: it was armed
        closing.windowClosed()
        #expect(second.value == nil)
    }

    @Test func onlyEarlierUseNotPermissionsMarksAnExistingUser() {
        #expect(!OnboardingPolicy.isExistingUser(takeCount: nil))
        #expect(!OnboardingPolicy.isExistingUser(takeCount: 0))
        #expect(OnboardingPolicy.isExistingUser(takeCount: 1))
        #expect(OnboardingPolicy.shouldOfferAtLaunch(onboardingDone: false, takeCount: 0))
        #expect(!OnboardingPolicy.shouldOfferAtLaunch(onboardingDone: false, takeCount: 12))
        #expect(!OnboardingPolicy.shouldOfferAtLaunch(onboardingDone: true, takeCount: 0))
    }

    @Test func nextOnTheLastStepFinishes() {
        let (model, _, preferences) = make()
        model.step = .practice
        model.next()
        #expect(preferences.onboardingDone)
    }

    @Test func microphoneRequestUpdatesTheStateAndADenialIsShown() async {
        let granting = FakePermissions(mic: .notAsked, micGrantsOnRequest: true)
        let permissions = PermissionsModel(probe: granting)
        await permissions.requestMicrophone()
        #expect(permissions.microphone == .granted)
        let denying = PermissionsModel(probe: FakePermissions(mic: .notAsked, micGrantsOnRequest: false))
        await denying.requestMicrophone()
        #expect(denying.microphone == .denied)
        #expect(!denying.allGranted)
    }

    @Test func thePermissionLinksGoToTheRightPanes() {
        #expect(PermissionPane.accessibility.url.absoluteString.hasSuffix("Privacy_Accessibility"))
        #expect(PermissionPane.microphone.url.absoluteString.hasSuffix("Privacy_Microphone"))
    }
}

@Suite struct SettingsModelTests {
    @Test func switchingToAModeInAnotherLanguageShowsThatLanguagesModel() async throws {
        let name = "vizier-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let dir = FileManager.default.temporaryDirectory.appending(path: "vizier-sm-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = ConfigStore(directory: dir)
        try config.writeStarterFilesIfMissing()
        // The starter modes, all in English, except Scribe in French.
        let parts = ConfigStore.starterSettings(language: "en_US").components(separatedBy: "\"id\": \"scribe\"")
        try #require(parts.count == 2)
        let french = parts[1].replacing("[\"en_US\"]", with: "[\"fr_FR\"]", maxReplacements: 1)
        try Data((parts[0] + "\"id\": \"scribe\"" + french).utf8).write(to: config.settingsURL)
        let source = LanguageSource(language: { Engines.speechModelLocale(config.load().config).identifier }, installed: ["en_US"])
        let model = SettingsModel(
            preferences: AppPreferences(defaults: defaults), config: config, speech: SpeechModelModel(source: source),
            accounts: [], loginItem: FakeLoginItem(state: .off))
        await model.refresh()
        #expect(model.modePicker.activeModeID == "apple")
        #expect(model.speechModel.locale.identifier == "en_US" && model.speechModel.state == .installed)
        await model.selectMode("scribe")
        #expect(model.modePicker.activeModeID == "scribe")
        #expect(model.speechModel.locale.identifier == "fr_FR")
        #expect(model.speechModel.state == .notInstalled)
    }

    @Test func openAtLoginReadsBackTheStateTheSystemEndedUpIn() {
        let name = "vizier-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let config = ConfigStore(directory: FileManager.default.temporaryDirectory.appending(path: "vizier-sm-\(UUID().uuidString)"))
        let login = FakeLoginItem(state: .off)
        let model = SettingsModel(
            preferences: AppPreferences(defaults: defaults), config: config, speech: SpeechModelModel(source: FakeSpeechModelSource(status: .installed)),
            accounts: [], loginItem: login)
        model.setOpenAtLogin(true)
        #expect(login.requests == [true])
        #expect(model.loginState == .on)
        let notInstalled = FakeLoginItem(state: .notInstalled)
        let other = SettingsModel(
            preferences: AppPreferences(defaults: defaults), config: config, speech: SpeechModelModel(source: FakeSpeechModelSource(status: .installed)),
            accounts: [], loginItem: notInstalled)
        other.setOpenAtLogin(true)
        #expect(other.loginState == .notInstalled)
    }
}

/// A speech source whose language comes from a closure (the saved active mode's, as the live
/// source reads it, or a value a test changes), with a model present for the languages listed.
final class LanguageSource: SpeechModelSource, @unchecked Sendable {
    private let lock = NSLock()
    private var languageValue: @Sendable () -> String
    private var present: Set<String>
    private var installs: [String] = []

    init(language: @escaping @Sendable () -> String, installed: Set<String>) {
        languageValue = language
        present = installed
    }

    var language: @Sendable () -> String {
        get { lock.withLock { languageValue } }
        set { lock.withLock { languageValue = newValue } }
    }

    /// The languages `install` was asked for, in order.
    var installed: [String] { lock.withLock { installs } }

    func preferredLocale() -> Locale { Locale(identifier: language()) }
    func status(for locale: Locale) async -> SpeechModelStatus {
        lock.withLock { present.contains(locale.identifier) } ? .installed : .notInstalled
    }
    func install(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock {
            installs.append(locale.identifier)
            present.insert(locale.identifier)
        }
    }
}
