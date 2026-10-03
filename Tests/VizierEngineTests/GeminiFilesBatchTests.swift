import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import VizierEngine

@Suite struct GeminiFilesBatchTests {
    @Test func aTakeAtTheInlineCapIsOneInlineRequest() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let bytes = try Fixture.size(audio)
        let server = Fixture.server()
        let report = try await Fixture.transcriber(server, maxInlineBytes: bytes).transcribeReporting(audio)
        let requests = await server.requests
        #expect(requests.count == 1)
        #expect(requests.first?.url == GeminiBatch.endpoint)
        let input = try #require(try Fixture.json(requests.first?.httpBody).value(forKey: "input") as? [NSDictionary])
        #expect(input.first?["data"] as? String == (try Data(contentsOf: audio)).base64EncodedString())
        #expect(input.first?["uri"] == nil)
        #expect(requests.first?.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(report.route == .inline && report.remoteDeleted == nil && report.transcript == "Zorblex the quaxil.")
    }

    @Test func aTakeOverTheCapIsUploadedTranscribedByReferenceAndDeleted() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let bytes = try Data(contentsOf: audio)
        let server = Fixture.server()
        let report = try await Fixture.transcriber(server, maxInlineBytes: bytes.count - 1).transcribeReporting(audio)
        let requests = await server.requests
        #expect(requests.map { "\($0.httpMethod!) \($0.url!.absoluteString)" } == [
            "POST https://generativelanguage.googleapis.com/upload/v1beta/files",
            "POST \(Fixture.uploadURL)",
            "POST https://generativelanguage.googleapis.com/v1beta/interactions",
            "DELETE https://generativelanguage.googleapis.com/v1beta/files/quaxil-7",
        ])
        guard requests.count == 4 else { return }

        let start = requests[0]
        #expect(start.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Protocol") == "resumable")
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Command") == "start")
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length") == String(bytes.count))
        #expect(start.value(forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type") == "audio/flac")
        #expect(start.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try Fixture.json(start.httpBody) == ["file": ["display_name": "2026-09-25T12-00-00.000Z"]])

        let upload = requests[1]
        #expect(upload.value(forHTTPHeaderField: "X-Goog-Upload-Offset") == "0")
        #expect(upload.value(forHTTPHeaderField: "X-Goog-Upload-Command") == "upload, finalize")
        #expect(upload.httpBody == bytes)

        let expected = try Fixture.json(Data("""
        {"model": "gemini-3.5-transcribe",
         "input": [{"type": "audio", "uri": "https://generativelanguage.googleapis.com/v1beta/files/quaxil-7", "mime_type": "audio/flac"}],
         "generation_config": {"transcription_config": {"mode": "smart", "language_codes": ["en-US"], "custom_vocabulary": ["Zorblex"]}},
         "store": false}
        """.utf8))
        #expect(try Fixture.json(requests[2].httpBody) == expected)
        #expect(requests[2].value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        #expect(requests[3].value(forHTTPHeaderField: "x-goog-api-key") == "test-key")

        #expect(report.route == .files && report.bytes == bytes.count && report.remoteDeleted == true)
        #expect(report.transcript == "Zorblex the quaxil.")
    }

    @Test func aFailedUploadThrowsItsStatusAndTranscribesNothing() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(start: 403)
        await #expect(throws: BatchError.upload(status: 403, message: "INTERNAL: Synthetic failure.")) {
            try await Fixture.transcriber(server, maxInlineBytes: 0).transcribe(audio)
        }
        #expect(await server.requests.map(\.url) == [GeminiFiles.uploadEndpoint])
    }

    @Test func aFailedTranscriptionStillDeletesTheUpload() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(interact: 500)
        await #expect(throws: BatchError.http(status: 500, message: "INTERNAL: Synthetic failure.")) {
            try await Fixture.transcriber(server, maxInlineBytes: 0).transcribe(audio)
        }
        let last = await server.requests.last
        #expect(last?.httpMethod == "DELETE")
        #expect(last?.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/files/quaxil-7")
    }

    @Test func aFailedDeleteStillReturnsTheTranscript() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(delete: 500)
        let report = try await Fixture.transcriber(server, maxInlineBytes: 0).transcribeReporting(audio)
        #expect(report.transcript == "Zorblex the quaxil.")
        #expect(report.remoteDeleted == false)
        #expect(await server.requests.last?.httpMethod == "DELETE")
    }

    /// Silence compresses to 163 KB an hour, far under the inline cap, so this also shows the
    /// length check runs before either route.
    @Test func aTakeOverAnHourIsRefusedBeforeAnyRequest() async throws {
        let audio = try Fixture.flac(seconds: 3_660, silent: true)
        let server = Fixture.server()
        await #expect(throws: BatchError.tooLong(seconds: 3_660)) {
            try await Fixture.transcriber(server, maxInlineBytes: GeminiBatch.maxInlineAudioBytes).transcribe(audio)
        }
        #expect(await server.requests.isEmpty)
    }

    @Test func aFileStillProcessingIsPolledUntilActive() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(uploadedState: "PROCESSING", polledStates: ["PROCESSING", "ACTIVE"])
        let report = try await Fixture.transcriber(server, maxInlineBytes: 0).transcribeReporting(audio)
        #expect(await server.requests.map(\.httpMethod!) == ["POST", "POST", "GET", "GET", "POST", "DELETE"])
        #expect(report.transcript == "Zorblex the quaxil.")
    }

    @Test func aFileThatFailsProcessingThrowsAndIsDeleted() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(uploadedState: "PROCESSING", polledStates: ["FAILED"])
        await #expect(throws: BatchError.fileNotReady(state: "FAILED")) {
            try await Fixture.transcriber(server, maxInlineBytes: 0).transcribe(audio)
        }
        #expect(await server.requests.map(\.httpMethod!) == ["POST", "POST", "GET", "DELETE"])
    }

    static let offHostUploadURLs = [
        "https://uploads.example.com/files?upload_id=zx81",
        "https://generativelanguage.googleapis.com.evil.example/upload/v1beta/files?upload_id=zx81",
        "https://evilgenerativelanguage.googleapis.com/upload/v1beta/files?upload_id=zx81",
        "http://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=zx81",
        "https://user:pw@generativelanguage.googleapis.com/upload/v1beta/files?upload_id=zx81",
        "https://user@generativelanguage.googleapis.com/upload/v1beta/files?upload_id=zx81",
        "https://generativelanguage.googleapis.com:8443/upload/v1beta/files?upload_id=zx81",
        "ftp://generativelanguage.googleapis.com/upload/v1beta/files?upload_id=zx81",
        "/upload/v1beta/files?upload_id=zx81",
    ]

    @Test func onlyAnHTTPSUploadURLOnTheAPIHostIsAccepted() {
        #expect(GeminiFiles.uploadURL(from: Fixture.uploadURL) == URL(string: Fixture.uploadURL))
        #expect(GeminiFiles.uploadURL(from: "https://generativelanguage.googleapis.com:443/upload/v1beta/files?upload_id=zx81") != nil)
        #expect(GeminiFiles.uploadURL(from: nil) == nil)
        for location in Self.offHostUploadURLs {
            #expect(GeminiFiles.uploadURL(from: location) == nil, "\(location)")
        }
    }

    /// The start response names somewhere other than the API's host: the take fails, and neither
    /// the audio nor the key is sent anywhere after the start request.
    @Test func anUploadURLOffTheAPIHostIsRefusedBeforeAnyAudioIsSent() async throws {
        let audio = try Fixture.flac(seconds: 1)
        for location in Self.offHostUploadURLs {
            let server = Fixture.server(uploadLocation: location)
            await #expect(throws: BatchError.upload(status: 200, message: "the X-Goog-Upload-URL is not on the API's host")) {
                try await Fixture.transcriber(server, maxInlineBytes: 0).transcribe(audio)
            }
            #expect(await server.requests.map(\.url) == [GeminiFiles.uploadEndpoint], "\(location)")
        }
    }

    @Test func theKeyGoesOnlyToAnUploadURLOnTheAPIHost() {
        let own = GeminiFiles.uploadRequest(to: URL(string: Fixture.uploadURL)!, bytes: Data(), apiKey: "test-key")
        #expect(own.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
        for location in Self.offHostUploadURLs {
            let request = GeminiFiles.uploadRequest(to: URL(string: location)!, bytes: Data(), apiKey: "test-key")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == nil, "\(location)")
        }
    }

    @Test func fileNamesAndURIsMustBeTheAPIsOwn() {
        let good = GeminiFiles.File(name: "files/quaxil-7", uri: "https://generativelanguage.googleapis.com/v1beta/files/quaxil-7")
        #expect(GeminiFiles.isValid(good))
        for name in ["files/../models", "files/a/b", "files/", "files/UPPER", "files/a?b=1", "files/a%2Fb", "quaxil-7", "models/quaxil-7", "files/" + String(repeating: "a", count: 41)] {
            #expect(!GeminiFiles.isValidName(name), "\(name)")
        }
        for uri in [
            "https://evil.example/v1beta/files/quaxil-7",
            "http://generativelanguage.googleapis.com/v1beta/files/quaxil-7",
            "https://u@generativelanguage.googleapis.com/v1beta/files/quaxil-7",
            "https://generativelanguage.googleapis.com:8443/v1beta/files/quaxil-7",
            "https://generativelanguage.googleapis.com/v1beta/files/other-1",
            "https://generativelanguage.googleapis.com/v1beta/files/quaxil-7?alt=x",
        ] {
            #expect(!GeminiFiles.isValid(GeminiFiles.File(name: good.name, uri: uri)), "\(uri)")
        }
    }

    /// Finalize answers a file whose URI is off the API's host: it is never transcribed, and the
    /// (validly named) file is deleted.
    @Test func anUploadedFileWithAForeignURIIsDeletedNotTranscribed() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(uploadBody: Data(#"{"file": {"name": "files/quaxil-7", "uri": "https://evil.example/files/quaxil-7", "state": "ACTIVE"}}"#.utf8))
        await #expect(throws: BatchError.upload(status: 200, message: "unreadable File in the upload response")) {
            try await Fixture.transcriber(server, maxInlineBytes: 0).transcribe(audio)
        }
        let requests = await server.requests
        #expect(requests.filter { $0.url == GeminiBatch.endpoint }.isEmpty)
        #expect(requests.last?.httpMethod == "DELETE")
        #expect(requests.last?.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/files/quaxil-7")
    }

    /// A malformed name is never turned into a request path, not even to delete it.
    @Test func anUploadedFileWithABadNameIsNeitherUsedNorDeleted() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(uploadBody: Data(#"{"file": {"name": "files/../../v1beta/models", "uri": "https://generativelanguage.googleapis.com/v1beta/files/../../v1beta/models", "state": "ACTIVE"}}"#.utf8))
        await #expect(throws: BatchError.upload(status: 200, message: "unreadable File in the upload response")) {
            try await Fixture.transcriber(server, maxInlineBytes: 0).transcribe(audio)
        }
        #expect(await server.requests.map(\.httpMethod!) == ["POST", "POST"])
    }

    @Test func aFileThatNeverFinishesProcessingGivesUpAfterTheCapAndIsDeleted() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(uploadedState: "PROCESSING", pollsSettleOn: "PROCESSING")
        await #expect(throws: BatchError.fileNotReady(state: "PROCESSING")) {
            try await Fixture.transcriber(server, maxInlineBytes: 0).transcribe(audio)
        }
        let requests = await server.requests
        let polls = requests.filter { $0.httpMethod == "GET" }
        #expect(polls.count == GeminiFiles.maxPolls && GeminiFiles.maxPolls == 120)
        #expect(Set(polls.map(\.url!.absoluteString)) == ["https://generativelanguage.googleapis.com/v1beta/files/quaxil-7"])
        #expect(polls.allSatisfy { $0.value(forHTTPHeaderField: "x-goog-api-key") == "test-key" })
        #expect(requests.last?.httpMethod == "DELETE")
    }

    @Test func aFailedFinalizeThrowsItsStatusAndTranscribesNothing() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(upload: 500)
        await #expect(throws: BatchError.upload(status: 500, message: "INTERNAL: Synthetic failure.")) {
            try await Fixture.transcriber(server, maxInlineBytes: 0).transcribe(audio)
        }
        #expect(await server.requests.map(\.url!.absoluteString) == [GeminiFiles.uploadEndpoint.absoluteString, Fixture.uploadURL])
    }

    /// Finalize said 200 and named the file, but the body is missing `uri`: Google holds audio we
    /// can't use, so it is deleted by name before the error.
    @Test func anUnreadableFinalizeResponseStillDeletesTheNamedFile() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(uploadBody: Data(#"{"file": {"name": "files/orphan-1", "state": "ACTIVE"}}"#.utf8))
        await #expect(throws: BatchError.upload(status: 200, message: "unreadable File in the upload response")) {
            try await Fixture.transcriber(server, maxInlineBytes: 0).transcribe(audio)
        }
        let last = await server.requests.last
        #expect(last?.httpMethod == "DELETE")
        #expect(last?.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/files/orphan-1")
        #expect(await server.requests.filter { $0.url == GeminiBatch.endpoint }.isEmpty)
    }

    /// The take is cancelled while its finalize request is in flight. Like URLSession, the stub
    /// fails any request made from a cancelled task. The finalize still completes, and the file it
    /// created is deleted.
    @Test func aTakeCancelledDuringFinalizeStillDeletesTheUpload() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server()
        let (finalizing, signal) = AsyncStream<Void>.makeStream()
        let transcriber = GeminiBatchTranscriber(
            config: Fixture.config, apiKey: "test-key",
            perform: { request in
                try Task.checkCancellation()
                if request.url?.absoluteString == Fixture.uploadURL {
                    signal.yield()
                    try await Task.sleep(for: .milliseconds(300))
                }
                return await server.answer(request)
            },
            maxInlineBytes: 0, pollInterval: .zero)
        let take = Task { try await transcriber.transcribe(audio) }
        for await _ in finalizing { break }
        take.cancel()
        await #expect(throws: CancellationError.self) { try await take.value }
        let requests = await server.requests
        #expect(requests.map(\.httpMethod!) == ["POST", "POST", "DELETE"])
        #expect(requests.last?.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/files/quaxil-7")
    }

    // A truncated answer on the Files route gets one retry on the same uploaded file.

    private func interactions(_ requests: [URLRequest]) -> Int { requests.filter { $0.url == GeminiBatch.endpoint }.count }
    private func deletes(_ requests: [URLRequest]) -> Int { requests.filter { $0.httpMethod == "DELETE" }.count }

    @Test func aTruncatedAnswerIsRetriedAndACompleteRetryWins() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(answers: [(200, Fixture.answer("incomplete", "Zorblex the the the")), (200, Fixture.answer("completed", "Zorblex the quaxil."))])
        let report = try await Fixture.transcriber(server, maxInlineBytes: 0).transcribeReporting(audio)
        #expect(report.transcript == "Zorblex the quaxil." && report.wordCount == 3)
        #expect(!report.truncated && report.retried && report.remoteDeleted == true)
        let requests = await server.requests
        #expect(interactions(requests) == 2 && deletes(requests) == 1)
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 4)  // one upload start, one upload, two interactions
    }

    @Test func twoTruncatedAnswersKeepTheFirst() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(answers: [(200, Fixture.answer("incomplete", "Zorblex the quaxil. the the")), (200, Fixture.answer("incomplete", "Zorblex qua qua qua qua"))])
        let report = try await Fixture.transcriber(server, maxInlineBytes: 0).transcribeReporting(audio)
        #expect(report.transcript == "Zorblex the quaxil. the the" && report.wordCount == 5)
        #expect(report.truncated && report.retried)
        let requests = await server.requests
        #expect(interactions(requests) == 2 && deletes(requests) == 1)
    }

    @Test func aFailedRetryKeepsTheFirstTruncatedAnswer() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(answers: [(200, Fixture.answer("incomplete", "Zorblex the quaxil. the")), (503, Data())])
        let report = try await Fixture.transcriber(server, maxInlineBytes: 0).transcribeReporting(audio)
        #expect(report.transcript == "Zorblex the quaxil. the" && report.truncated && report.retried)
        #expect(deletes(await server.requests) == 1)
    }

    @Test func aCompleteFirstAnswerIsNotRetried() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server()
        let report = try await Fixture.transcriber(server, maxInlineBytes: 0).transcribeReporting(audio)
        #expect(!report.truncated && !report.retried && report.wordCount == 3)
        #expect(interactions(await server.requests) == 1)
    }

    @Test func aTruncatedInlineAnswerIsKeptAndNotRetried() async throws {
        let audio = try Fixture.flac(seconds: 1)
        let server = Fixture.server(answers: [(200, Fixture.answer("incomplete", "Zorblex the the"))])
        let report = try await Fixture.transcriber(server, maxInlineBytes: GeminiBatch.maxInlineAudioBytes).transcribeReporting(audio)
        #expect(report.route == .inline && report.transcript == "Zorblex the the" && report.truncated && !report.retried)
        #expect(await server.requests.count == 1)
    }
}
