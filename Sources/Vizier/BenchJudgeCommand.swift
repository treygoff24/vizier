import VizierEngine
import Foundation

/// `Vizier --bench-judge <manifest.jsonl> <results.jsonl> <references.jsonl> [--model m] [--parallel N]`
/// writes a reference transcript for each benched clip: a general Gemini model hears the audio
/// and reads every engine's text, shuffled and unlabeled, and writes what was actually said.
/// Real takes have no answer key, and scoring against the history's own transcript would favor
/// the engine that wrote it. The judge sees the user's vocabulary, as the engines did.
///
/// Uses the Gemini key from the Keychain, so run the signed bundle. References go to a file
/// created 0600, never to stdout.
nonisolated enum BenchJudgeCommand {
    struct Clip: Decodable, Sendable {
        var id: String
        var wav: String
    }

    struct Result: Decodable, Sendable {
        var id: String
        var engine: String
        var text: String?
    }

    struct Reference: Encodable, Sendable {
        var id: String
        var model: String
        var reference: String?
        var error: String?
    }

    static func run(_ arguments: [String]) -> Int32? {
        guard let flag = arguments.firstIndex(of: "--bench-judge") else { return nil }
        let rest = Array(arguments.dropFirst(flag + 1))
        var positional: [String] = []
        var model = "gemini-3.1-pro-preview"
        var parallel = 4
        var blind = false
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--model" where i + 1 < rest.count: model = rest[i + 1]; i += 2
            case "--parallel" where i + 1 < rest.count: parallel = max(1, Int(rest[i + 1]) ?? 4); i += 2
            case "--blind": blind = true; i += 1
            default: positional.append(rest[i]); i += 1
            }
        }
        guard positional.count == 3 else {
            return fail("usage: Vizier --bench-judge <manifest.jsonl> <results.jsonl> <references.jsonl> [--model m] [--parallel N]", code: 64)
        }
        let clips: [Clip]
        var texts: [String: [String]] = [:]
        do {
            clips = try lines(positional[0]).map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
            for line in try lines(positional[1]) {
                let result = try JSONDecoder().decode(Result.self, from: Data(line.utf8))
                if let text = result.text, !text.isEmpty { texts[result.id, default: []].append(text) }
            }
        } catch {
            return fail("cannot read the inputs: \(error)", code: 66)
        }
        guard let key = (try? Keychain.read("gemini")) ?? nil else { return fail("no Gemini key in the keychain", code: 77) }
        let load = ConfigStore.standard.load()
        let vocabulary = load.errors.isEmpty ? load.config.vocabulary : []

        let output = URL(filePath: positional[2])
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: output)
        else { return fail("cannot create \(output.path)", code: 73) }
        let writer = Writer(handle: handle)
        // Blind: the judge hears only the audio, so it cannot side with a majority of engines.
        let candidates = blind ? [:] : texts
        let judgeModel = model
        let width = parallel
        print("judge: \(clips.count) clips with \(judgeModel), \(parallel) at a time")
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < clips.count else { return }
                    let clip = clips[next]
                    next += 1
                    group.addTask {
                        let reference = await judge(clip, candidates: candidates[clip.id] ?? [], vocabulary: vocabulary, model: judgeModel, key: key)
                        writer.write(reference)
                        print("\(clip.id) -> \(reference.error ?? "ok")")
                    }
                }
                for _ in 0..<width { add() }
                while await group.next() != nil { add() }
            }
            done.signal()
        }
        done.wait()
        try? handle.close()
        print("judge: wrote \(writer.count) references to \(output.path)")
        return 0
    }

    private static func lines(_ path: String) throws -> [String] {
        try String(contentsOf: URL(filePath: path), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    static func prompt(candidates: [String], vocabulary: [String]) -> String {
        var text = """
        You are writing the ground-truth transcript for a speech-recognition benchmark. The audio is one \
        person dictating into a push-to-talk dictation app, mostly about software development.

        Listen to the whole recording.\(candidates.isEmpty ? "" : candidateNote)

        Write exactly what was said, word for word, with the punctuation and capitalization a careful \
        human transcriber would use. Keep false starts and repeated words; leave out filler sounds \
        (um, uh, er, hmm). Write numbers the way the speaker would want them typed. Spell names and \
        terms as in the vocabulary list when the speaker says them.

        """
        if !vocabulary.isEmpty { text += "\nVocabulary: \(vocabulary.joined(separator: ", "))\n" }
        for (index, candidate) in candidates.enumerated() {
            text += "\nCandidate \(index + 1):\n\(candidate)\n"
        }
        text += "\nAnswer with JSON only: {\"reference\": \"<the transcript>\"}"
        return text
    }

    static let candidateNote = """
         Below are transcripts from several speech-recognition systems, in \
        random order; any of them may be wrong anywhere. The audio is the only authority: where they \
        disagree, decide from what you hear, and where they all agree but the audio says otherwise, \
        follow the audio.
        """

    /// The candidates in an order fixed by the clip id, so no engine always comes first.
    static func shuffled(_ candidates: [String], seed: String) -> [String] {
        var state = seed.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        var items = candidates
        for i in stride(from: items.count - 1, to: 0, by: -1) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            items.swapAt(i, Int(state >> 33) % (i + 1))
        }
        return items
    }

    private static func judge(_ clip: Clip, candidates: [String], vocabulary: [String], model: String, key: String) async -> Reference {
        var reference = Reference(id: clip.id, model: model)
        guard let audio = try? Data(contentsOf: URL(filePath: clip.wav)) else {
            reference.error = "unreadable wav"
            return reference
        }
        let body: [String: Any] = [
            "contents": [["parts": [
                ["inline_data": ["mime_type": "audio/wav", "data": audio.base64EncodedString()]],
                ["text": prompt(candidates: shuffled(candidates, seed: clip.id), vocabulary: vocabulary)],
            ]]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": ["type": "OBJECT", "properties": ["reference": ["type": "STRING"]], "required": ["reference"]],
            ],
        ]
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        for attempt in 1...3 {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    reference.error = "HTTP \(status): \(GeminiBatch.errorMessage(from: data))"
                    if status == 429 || status >= 500 { try? await Task.sleep(for: .seconds(5 * attempt)); continue }
                    return reference
                }
                let text = try answerText(data)
                let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                guard let answer = parsed?["reference"] as? String else {
                    reference.error = "no reference in the answer (finish \(finishReason(data)), keys \(parsed.map { Array($0.keys).sorted() } ?? []))"
                    continue
                }
                reference.reference = answer
                reference.error = nil
                return reference
            } catch {
                reference.error = String(describing: error)
            }
        }
        return reference
    }

    private static func finishReason(_ data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidates = object?["candidates"] as? [[String: Any]] ?? []
        return candidates.first?["finishReason"] as? String ?? "none"
    }

    private static func answerText(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let candidates = object?["candidates"] as? [[String: Any]] ?? []
        let content = candidates.first?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]] ?? []
        return parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
    }

    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private(set) var count = 0
        init(handle: FileHandle) { self.handle = handle }
        func write(_ reference: Reference) {
            guard let data = try? JSONEncoder().encode(reference) else { return }
            lock.withLock {
                handle.write(data + Data("\n".utf8))
                count += 1
            }
        }
    }

    private static func fail(_ message: String, code: Int32) -> Int32 {
        FileHandle.standardError.write(Data("Vizier: \(message)\n".utf8))
        return code
    }
}
