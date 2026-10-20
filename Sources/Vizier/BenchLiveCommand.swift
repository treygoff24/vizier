import VizierEngine
import Foundation

/// `Vizier --bench-live <manifest.jsonl> <results.jsonl> [--engines e:m:mode,...] [--parallel N]`
/// replays recorded takes through live engines as if spoken: 100 ms chunks at real-time pace,
/// then `finish()` at the end of the audio, which stands in for the stop tap. It records each
/// engine's text and the milliseconds from that stop to the final, the number a take's paste
/// waits on. Every engine streams the same clip at once, so they hear it under the same network.
///
/// The manifest has one `{"id": ..., "wav": <path>}` per line, 16 kHz mono 16-bit WAV. Vocabulary
/// comes from the user's config, as in a real take; keys come from the Keychain, so run the
/// signed bundle (build/Vizier.app). Results, which hold transcripts, go to the results file
/// (created 0600), never to stdout. It exits before the app starts, so it never touches the
/// running Vizier's hotkey or history.
nonisolated enum BenchLiveCommand {
    struct Engine: Sendable {
        var engine: String
        var model: String
        var mode: String
    }

    static let defaultEngines = [
        Engine(engine: "soniox-realtime", model: "stt-rt-v5", mode: "verbatim"),
        Engine(engine: "elevenlabs-scribe-realtime", model: "scribe_v2_realtime", mode: "verbatim"),
        Engine(engine: "gemini-live", model: "gemini-3.5-transcribe-live", mode: "VERBATIM"),
    ]

    struct Clip: Decodable, Sendable {
        var id: String
        var wav: String
    }

    struct Result: Encodable, Sendable {
        var id: String
        var engine: String
        var model: String
        var audio_s: Double
        var scribe_timings: [String: Int]?
        var final_ms: Int?
        var text: String?
        var error: String?
    }

    static func run(_ arguments: [String]) -> Int32? {
        guard let flag = arguments.firstIndex(of: "--bench-live") else { return nil }
        let rest = Array(arguments.dropFirst(flag + 1))
        let positional = positionals(rest)
        guard positional.count == 2 else {
            return fail("usage: Vizier --bench-live <manifest.jsonl> <results.jsonl> [--engines engine:model:mode,...] [--parallel N]", code: 64)
        }
        var engines = defaultEngines
        if let i = rest.firstIndex(of: "--engines"), rest.indices.contains(i + 1) {
            engines = rest[i + 1].split(separator: ",").compactMap { spec in
                let parts = spec.split(separator: ":").map(String.init)
                return parts.count == 3 ? Engine(engine: parts[0], model: parts[1], mode: parts[2]) : nil
            }
            guard !engines.isEmpty else { return fail("--engines wants engine:model:mode, comma-separated", code: 64) }
        }
        var parallel = 4
        if let i = rest.firstIndex(of: "--parallel"), rest.indices.contains(i + 1), let n = Int(rest[i + 1]), n > 0 { parallel = n }

        let clips: [Clip]
        do {
            let text = try String(contentsOf: URL(filePath: positional[0]), encoding: .utf8)
            clips = try text.split(separator: "\n").map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
        } catch {
            return fail("cannot read the manifest: \(error)", code: 66)
        }
        let load = ConfigStore.standard.load()
        if !load.errors.isEmpty { return fail("the config has errors; fix them first", code: 78) }
        let vocabulary = load.config.vocabulary
        let chosen = engines

        var keys: [String: String] = [:]
        for engine in chosen {
            guard let account = Engines.keyAccount(for: engine.engine) else { continue }
            guard let key = (try? Keychain.read(account.account)) ?? nil else {
                return fail("no \(account.name) key in the keychain (Vizier --store-key \(account.account))", code: 77)
            }
            keys[engine.engine] = key
        }

        let output = URL(filePath: positional[1])
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: output)
        else { return fail("cannot create \(output.path)", code: 73) }

        print("bench: \(clips.count) clips x \(chosen.count) engines, \(parallel) clips at a time, \(vocabulary.count) vocabulary terms")
        let done = DispatchSemaphore(value: 0)
        let writer = Writer(handle: handle)
        let keyMap = keys
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < clips.count else { return }
                    let clip = clips[next]
                    next += 1
                    group.addTask { await bench(clip, engines: chosen, keys: keyMap, vocabulary: vocabulary, writer: writer) }
                }
                for _ in 0..<parallel { add() }
                while await group.next() != nil { add() }
            }
            done.signal()
        }
        done.wait()
        try? handle.close()
        print("bench: wrote \(writer.count) results to \(output.path)")
        return 0
    }

    private static func positionals(_ rest: [String]) -> [String] {
        var out: [String] = []
        var skip = false
        for arg in rest {
            if skip { skip = false; continue }
            if arg == "--engines" || arg == "--parallel" { skip = true; continue }
            if arg.hasPrefix("--") { continue }
            out.append(arg)
        }
        return out
    }

    private static func bench(_ clip: Clip, engines: [Engine], keys: [String: String], vocabulary: [String], writer: Writer) async {
        let pcm: Data
        do {
            let samples = try WAVFile.samples(URL(filePath: clip.wav))
            pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        } catch {
            for engine in engines {
                writer.write(Result(id: clip.id, engine: engine.engine, model: engine.model, audio_s: 0, error: "unreadable wav: \(error)"))
            }
            return
        }
        let seconds = Double(pcm.count) / 32_000
        await withTaskGroup(of: Result.self) { group in
            for engine in engines {
                group.addTask { await stream(pcm, seconds: seconds, clip: clip, engine: engine, key: keys[engine.engine], vocabulary: vocabulary) }
            }
            for await result in group {
                writer.write(result)
                let outcome = result.final_ms.map { "\($0) ms" } ?? "failed"
                print("\(clip.id) \(result.engine.padding(toLength: 27, withPad: " ", startingAt: 0)) \(String(format: "%5.1f", seconds)) s audio -> \(outcome)")
            }
        }
    }

    private static func stream(_ pcm: Data, seconds: Double, clip: Clip, engine: Engine, key: String?, vocabulary: [String]) async -> Result {
        var result = Result(id: clip.id, engine: engine.engine, model: engine.model, audio_s: seconds)
        let spec = VizierConfig.Transcriber(engine: engine.engine, model: engine.model, mode: engine.mode, languages: ["en-US"], finalTimeoutMs: 15_000)
        guard let transcriber = benchOnly(spec, vocabulary: vocabulary, key: key) ?? Engines.live(spec, vocabulary: vocabulary, key: key) else {
            result.error = "no transcriber for \(engine.engine)"
            return result
        }
        transcriber.start { _ in }
        let clock = ContinuousClock()
        let started = clock.now
        let chunk = TakeRecorder.chunkBytes
        var offset = 0
        var index = 0
        while offset < pcm.count {
            let end = min(offset + chunk, pcm.count)
            transcriber.send(pcm.subdata(in: offset..<end))
            offset = end
            index += 1
            // The recorder hands over a chunk once 100 ms of audio has arrived.
            try? await clock.sleep(until: started + .milliseconds(100 * index))
        }
        let stopped = clock.now
        do {
            result.text = try await transcriber.finish()
            result.final_ms = Int((clock.now - stopped) / .milliseconds(1))
        } catch {
            result.error = String(describing: error)
        }
        if let scribe = transcriber as? ScribeRealtimeTranscriber {
            result.scribe_timings = await scribe.diagnostics()
        }
        return result
    }

    /// Engine variants that exist only to be benched, to see whether context helps accuracy:
    /// `soniox-realtime-context` is Soniox with `general` context describing dictation, and
    /// `assemblyai-realtime-prompt` is AssemblyAI with a `prompt` saying the same.
    private static func benchOnly(_ spec: VizierConfig.Transcriber, vocabulary: [String], key: String?) -> (any LiveTranscriber)? {
        guard let key else { return nil }
        if spec.engine == "assemblyai-realtime-prompt" {
            let prompt = "One person dictating with a push-to-talk app about software development: messages, notes, and instructions to AI coding agents, apps, builds and tests."
            let setup = AssemblyAIRealtime.Setup(model: spec.model, vocabulary: vocabulary, prompt: prompt)
            return AssemblyAIRealtimeTranscriber(setup: setup, apiKey: key, finalTimeoutMs: spec.finalTimeoutMs)
        }
        guard spec.engine == "soniox-realtime-context" else { return nil }
        let general = [
            SonioxRealtime.GeneralItem(key: "setting", value: "One person dictating with a push-to-talk app: messages, notes, and instructions to AI coding agents"),
            SonioxRealtime.GeneralItem(key: "domain", value: "Software development"),
            SonioxRealtime.GeneralItem(key: "topic", value: "Building apps, AI agents, coding tools, git, builds and tests"),
        ]
        let setup = SonioxRealtime.Setup(model: spec.model, languages: spec.languages, vocabulary: vocabulary, general: general)
        return SonioxRealtimeTranscriber(setup: setup, apiKey: key, finalTimeoutMs: spec.finalTimeoutMs)
    }

    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private let handle: FileHandle
        private(set) var count = 0
        init(handle: FileHandle) { self.handle = handle }
        func write(_ result: Result) {
            guard let data = try? JSONEncoder().encode(result) else { return }
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
