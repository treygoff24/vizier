import Foundation
import Testing
@testable import VizierEngine

/// Fixtures are synthetic words in the shapes of the ElevenLabs speech-to-text reference.
@Suite struct ScribeBatchTests {
    private let config = ScribeBatch.Config(model: "scribe_v2", languages: ["en-US"], vocabulary: ["Zorblex", "quaxil runner"])

    @Test func formFieldsCarryTheModelABareLanguageAndEachKeyterm() {
        let fields = ScribeBatch.formFields(config)
        #expect(fields.map(\.0) == ["model_id", "tag_audio_events", "language_code", "keyterms", "keyterms"])
        #expect(fields.map(\.1) == ["scribe_v2", "false", "en", "Zorblex", "quaxil runner"])
    }

    @Test func noLanguageLeavesTheFieldOut() {
        let bare = ScribeBatch.Config(model: "scribe_v2", languages: [], vocabulary: [])
        #expect(ScribeBatch.formFields(bare).map(\.0) == ["model_id", "tag_audio_events"])
    }

    @Test func keytermsSkipTermsTooLongOrTooWordyAndStopAtOneHundred() {
        let long = String(repeating: "z", count: 50)
        let wordy = "one two three four five six"
        let terms = ScribeBatch.keyterms([" Zorblex ", "", long, wordy, String(repeating: "q", count: 49)] + (0..<150).map { "term\($0)" })
        #expect(terms.count == 100)
        #expect(terms.prefix(3) == ["Zorblex", String(repeating: "q", count: 49), "term0"])
        #expect(!terms.contains(long))
        #expect(!terms.contains(wordy))
    }

    @Test func theBodyIsOnePartPerFieldThenTheFile() {
        let small = ScribeBatch.Config(model: "scribe_v2", languages: ["en"], vocabulary: [])
        let body = ScribeBatch.multipartBody(audio: Data("fLaC".utf8), filename: "t.flac", config: small, boundary: "B")
        let expected = [
            "--B", #"Content-Disposition: form-data; name="model_id""#, "", "scribe_v2",
            "--B", #"Content-Disposition: form-data; name="tag_audio_events""#, "", "false",
            "--B", #"Content-Disposition: form-data; name="language_code""#, "", "en",
            "--B", #"Content-Disposition: form-data; name="file"; filename="t.flac""#, "Content-Type: audio/flac", "", "fLaC",
            "--B--", "",
        ].joined(separator: "\r\n")
        #expect(String(decoding: body, as: UTF8.self) == expected)
    }

    @Test func sendsTheKeyInAHeaderAndReadsTheText() async throws {
        let server = StubServer { _ in (200, [:], Data(#"{"language_code": "eng", "text": " Zorblex the quaxil. ", "words": []}"#.utf8)) }
        let url = try Fixture.flac(seconds: 1)
        let transcriber = ScribeBatchTranscriber(config: config, apiKey: "k-123", perform: { await server.answer($0) })
        let report = try await transcriber.transcribeReporting(url)
        #expect(report.transcript == "Zorblex the quaxil.")
        #expect(report.wordCount == 3)
        #expect(report.route == .scribe)
        #expect(report.truncated == false)
        let requests = await server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url == ScribeBatch.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "k-123")
        #expect(request.url?.absoluteString.contains("k-123") == false)
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.split(separator: "=", maxSplits: 1).last.map(String.init))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = try #require(request.httpBody)
        #expect(body == ScribeBatch.multipartBody(audio: try Data(contentsOf: url), filename: url.lastPathComponent, config: config, boundary: boundary))
    }

    @Test func aFailedRequestThrowsWithTheServersMessage() async throws {
        let url = try Fixture.flac(seconds: 1)
        let objectDetail = StubServer { _ in (401, [:], Data(#"{"detail": {"status": "invalid_api_key", "message": "Invalid API key"}}"#.utf8)) }
        await #expect(throws: BatchError.http(status: 401, message: "invalid_api_key: Invalid API key")) {
            try await ScribeBatchTranscriber(config: config, apiKey: "k", perform: { await objectDetail.answer($0) }).transcribeReporting(url)
        }
        let stringDetail = StubServer { _ in (422, [:], Data(#"{"detail": "file is not audio"}"#.utf8)) }
        await #expect(throws: BatchError.http(status: 422, message: "file is not audio")) {
            try await ScribeBatchTranscriber(config: config, apiKey: "k", perform: { await stringDetail.answer($0) }).transcribeReporting(url)
        }
    }
}

@Suite struct ScribeLanguageTests {
    @Test func everyLocaleShapeReducesToTheBareLanguageCode() {
        for (input, expected) in [("en_US", "en"), ("en-GB", "en"), ("zh-Hant-TW", "zh"), ("fr", "fr")] {
            #expect(ScribeLanguage.code(from: input) == expected, "\(input)")
            #expect(ScribeBatch.Config(model: "m", languages: [input], vocabulary: []).language == expected, "batch \(input)")
            #expect(ScribeRealtime.Setup(model: "m", languages: [input], vocabulary: [], noVerbatim: false).language == expected, "realtime \(input)")
        }
    }

    @Test func emptyOrUnparseableInputLeavesTheLanguageOut() {
        #expect(ScribeLanguage.code(from: nil) == nil)
        #expect(ScribeLanguage.code(from: "") == nil)
        #expect(ScribeLanguage.code(from: "  ") == nil)
    }
}
