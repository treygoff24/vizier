import VizierEngine
import Foundation

/// The saved keys. The real store is the login keychain under Vizier's service; tests and
/// `--render-ui` inject `InMemoryKeyStore`, so nothing under test ever touches the real Keychain.
protocol KeyStoring {
    func hasKey(account: String) -> Bool
    func save(_ key: String, account: String) throws
}

struct KeychainKeyStore: KeyStoring {
    func hasKey(account: String) -> Bool {
        ((try? Keychain.read(account)) ?? nil)?.isEmpty == false
    }

    func save(_ key: String, account: String) throws {
        try Keychain.store(key, account: account)
    }
}

final class InMemoryKeyStore: KeyStoring {
    private(set) var keys: [String: String]
    var failure: (any Error)?

    init(keys: [String: String] = [:]) { self.keys = keys }

    func hasKey(account: String) -> Bool { keys[account]?.isEmpty == false }
    func save(_ key: String, account: String) throws {
        if let failure { throw failure }
        keys[account] = key
    }
}

enum KeyTestResult: Equatable {
    case passed
    case rejected
    /// The service answered, but this key may not be allowed to make the check (ElevenLabs'
    /// /v1/user needs the User Read permission, which a transcription-only key may not have).
    case lacksPermission
    case unreachable(String)

    var message: String {
        switch self {
        case .passed: "The service accepted this key."
        case .rejected: "The service turned this key down. Check that you copied all of it."
        case .lacksPermission: "The service answered but wouldn’t confirm the key: it may lack the User Read permission. Transcription may still work."
        case .unreachable(let why): "Couldn’t check the key: \(why)"
        }
    }
}

/// One cheap authenticated call per provider, to tell the user whether a key works.
protocol KeyTesting {
    func test(_ provider: Engines.KeyAccount, key: String) async -> KeyTestResult
}

/// ElevenLabs: `GET /v1/user` with the `xi-api-key` header. Gemini: `GET /v1beta/models` with the
/// `x-goog-api-key` header (the key never goes into a URL, where logs would keep it). Neither call
/// bills anything.
struct NetworkKeyTester: KeyTesting {
    /// No cookies, no cache, no redirects, like the transcription engines' session: URLSession
    /// copies `xi-api-key` and `x-goog-api-key` onto a redirected request, so following a 3xx
    /// could hand the key to whatever `Location` names. A refused redirect comes back as its 3xx
    /// status, which `result(forStatus:)` reports as unreachable.
    static let urlSession = URLSession(configuration: .ephemeral, delegate: RefuseRedirects(), delegateQueue: nil)

    var fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await NetworkKeyTester.urlSession.data(for: $0) }

    static func request(for provider: Engines.KeyAccount, key: String) -> URLRequest? {
        var request: URLRequest
        switch provider {
        case .elevenLabs:
            request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .gemini:
            request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default:
            return nil
        }
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        return request
    }

    /// 2xx works. A bad key is a 401 (ElevenLabs) or a 400 API_KEY_INVALID (Gemini). ElevenLabs
    /// answers a valid key that lacks User Read with a 403, or with a 401 whose body says
    /// `missing_permissions`; that is "lacks permission", not "rejected". Anything else is a
    /// problem on the way there.
    static func result(forStatus status: Int, body: Data = Data(), provider: Engines.KeyAccount = .gemini) -> KeyTestResult {
        let missingPermission = provider == .elevenLabs
            && (status == 403 || (status == 401 && String(decoding: body, as: UTF8.self).contains("missing_permissions")))
        if missingPermission { return .lacksPermission }
        switch status {
        case 200..<300: return .passed
        case 400, 401, 403: return .rejected
        default: return .unreachable("the service answered \(status)")
        }
    }

    func test(_ provider: Engines.KeyAccount, key: String) async -> KeyTestResult {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let request = Self.request(for: provider, key: trimmed) else { return .rejected }
        do {
            let (body, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse else { return .unreachable("no answer") }
            return Self.result(forStatus: http.statusCode, body: body, provider: provider)
        } catch {
            return .unreachable((error as? URLError)?.localizedDescription ?? "network error")
        }
    }
}

struct FakeKeyTester: KeyTesting {
    var result: KeyTestResult = .passed
    func test(_ provider: Engines.KeyAccount, key: String) async -> KeyTestResult { result }
}

/// One provider's key field. The typed key lives only in `draft` until saved; a saved key is never
/// read back into the UI, only reported as saved. Testing checks the typed key when there is one,
/// and the saved key otherwise.
@Observable
final class AccountKeyModel: Identifiable {
    enum TestState: Equatable {
        case idle, testing, finished(KeyTestResult)
    }

    let provider: Engines.KeyAccount
    var draft = "" {
        // A result belongs to the key it was run for: editing the field ends it.
        didSet { if draft != oldValue { invalidateTest() } }
    }
    private(set) var hasSavedKey: Bool
    private(set) var test: TestState = .idle
    private(set) var saveError: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let store: any KeyStoring
    @ObservationIgnored private let tester: any KeyTesting
    @ObservationIgnored private let readSaved: (String) -> String?

    var id: String { provider.account }

    /// `readSaved` fetches the stored key only to test it; it never reaches the UI.
    init(provider: Engines.KeyAccount, store: any KeyStoring, tester: any KeyTesting, readSaved: @escaping (String) -> String? = { try? Keychain.read($0) }) {
        self.provider = provider
        self.store = store
        self.tester = tester
        self.readSaved = readSaved
        hasSavedKey = store.hasKey(account: provider.account)
    }

    var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSave: Bool { !trimmedDraft.isEmpty }
    var canTest: Bool { test != .testing && (canSave || hasSavedKey) }

    func save() {
        guard canSave else { return }
        do {
            try store.save(trimmedDraft, account: provider.account)
            draft = ""
            hasSavedKey = true
            saveError = nil
            invalidateTest()
        } catch {
            saveError = "Could not save the key to the Keychain: \(error)"
        }
    }

    func runTest() async {
        guard canTest else { return }
        let key = canSave ? trimmedDraft : (readSaved(provider.account) ?? "")
        generation += 1
        let mine = generation
        test = .testing
        let result = await tester.test(provider, key: key)
        // A slower, older test must not overwrite the state for a newer or edited key.
        guard mine == generation else { return }
        test = .finished(result)
    }

    private func invalidateTest() {
        generation += 1
        test = .idle
    }
}
