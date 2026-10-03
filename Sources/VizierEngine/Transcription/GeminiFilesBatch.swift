import Foundation
import os

/// The Gemini Files API route for takes too large to send inline: upload the FLAC, transcribe it
/// by reference, delete it. Wire format checked against
/// ai.google.dev/gemini-api/docs/files (the REST resumable upload and `DELETE /v1beta/{name}`),
/// ai.google.dev/api/files (the `File` resource, its `State` enum, and `media.upload`'s
/// `{"file": File}` response), and ai.google.dev/api/interactions-api (`AudioContent.uri`).
/// Unlike the Interactions API, the `File` resource comes back camelCase.
public enum GeminiFiles {
    public static let uploadEndpoint = URL(string: "https://generativelanguage.googleapis.com/upload/v1beta/files")!
    static let apiBase = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!

    /// How many times to re-read a file still `PROCESSING` before giving up on it.
    static let maxPolls = 120

    /// The first request of a resumable upload: metadata only. The upload URL comes back in the
    /// `X-Goog-Upload-URL` response header.
    public static func startRequest(byteCount: Int, mimeType: String, displayName: String, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: uploadEndpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        request.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.setValue(String(byteCount), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        request.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": displayName]], options: [.sortedKeys])
        return request
    }

    /// The API's own host. Upload URLs and file URIs that name anything else are refused.
    static let apiHost = "generativelanguage.googleapis.com"

    /// True only for https on the API's own host, with no user, password, or port other than
    /// 443. The upload URL comes from a response header, so it is checked before any audio (or
    /// the key) is sent to it.
    public static func isAPIURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https"
            && parts.host?.lowercased() == apiHost
            && parts.user == nil && parts.password == nil
            && (parts.port == nil || parts.port == 443)
    }

    /// The upload URL from the start response's `X-Goog-Upload-URL`, or nil when it is missing,
    /// unparseable, or anywhere but the API's own host.
    public static func uploadURL(from location: String?) -> URL? {
        guard let location, let url = URL(string: location), isAPIURL(url) else { return nil }
        return url
    }

    /// A file's resource name: `files/` and an ID of 1 to 40 lowercase letters, digits, and dashes
    /// (ai.google.dev/api/files). The name becomes a request path, so anything else (a `..`, a
    /// slash, a query) is refused rather than sent along with the key.
    public static func isValidName(_ name: String) -> Bool {
        guard name.hasPrefix("files/") else { return false }
        let id = name.dropFirst("files/".count)
        return (1...40).contains(id.count) && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// A `File` as returned is used only when its name is valid and its URI is on the API's own
    /// host and ends with that name.
    public static func isValid(_ file: File) -> Bool {
        guard isValidName(file.name), let uri = URL(string: file.uri), isAPIURL(uri) else { return false }
        return uri.path(percentEncoded: true).hasSuffix("/" + file.name) && uri.query == nil && uri.fragment == nil
    }

    /// Thrown for a `File` that fails `isValid`.
    public struct InvalidFile: Error, Equatable {}

    /// The second request: every byte at offset 0, finalizing the upload. URLSession sets
    /// `Content-Length` from the body itself (it reserves that header). The docs' curl sends no
    /// key here; the upload URL carries its own session. The route refuses any upload URL off the
    /// API's host before calling this; as a second guard the key goes along only when `isAPIURL`.
    public static func uploadRequest(to url: URL, bytes: Data, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        if isAPIURL(url) {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        request.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        request.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        request.httpBody = bytes
        return request
    }

    /// `files.get` and `files.delete` both address `/v1beta/{name}`, with `name` like `files/abc-123`.
    public static func fileRequest(name: String, method: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: apiBase.appending(path: name), timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    /// The parts of a `File` this route reads.
    public struct File: Decodable, Equatable, Sendable {
        public var name: String
        public var uri: String
        public var mimeType: String?
        /// `STATE_UNSPECIFIED`, `PROCESSING`, `ACTIVE`, or `FAILED`.
        public var state: String?
    }

    /// `media.upload` answers `{"file": File}`.
    public static func uploadedFile(from body: Data) throws -> File {
        struct Created: Decodable { var file: File }
        let file = try JSONDecoder().decode(Created.self, from: body).file
        guard isValid(file) else { throw InvalidFile() }
        return file
    }

    /// The file's name from an upload response too broken to read whole, so it can still be
    /// deleted. Nil when the name is not a valid file name.
    static func uploadedName(from body: Data) -> String? {
        struct Named: Decodable { struct Name: Decodable { var name: String }; var file: Name }
        guard let name = try? JSONDecoder().decode(Named.self, from: body).file.name, isValidName(name) else { return nil }
        return name
    }

    /// `files.get` answers the bare `File`.
    public static func file(from body: Data) throws -> File {
        let file = try JSONDecoder().decode(File.self, from: body)
        guard isValid(file) else { throw InvalidFile() }
        return file
    }

    struct Route {
        let config: GeminiBatch.Config
        let apiKey: String
        let perform: GeminiBatchTranscriber.Perform
        let pollInterval: Duration
        let log: Logger

        func transcribe(_ bytes: Data, displayName: String) async throws -> BatchReport {
            let clock = ContinuousClock()
            let started = clock.now
            let uploaded = try await upload(bytes, displayName: displayName)
            let result: BatchTranscript
            var retried = false
            let uploadSeconds: Double
            let transcribed: ContinuousClock.Instant
            do {
                let file = try await waitUntilActive(uploaded)
                uploadSeconds = (clock.now - started).seconds
                log.notice("batch files: \(bytes.count) bytes uploaded as \(file.name, privacy: .private) in \(uploadSeconds, format: .fixed(precision: 1)) s")
                transcribed = clock.now
                let first = try await interact(file)
                if first.truncated {
                    retried = true
                    result = await retry(file, after: first)
                } else {
                    result = first
                }
            } catch {
                await delete(uploaded)
                throw error
            }
            let transcriptionSeconds = (clock.now - transcribed).seconds
            let deleted = await delete(uploaded)
            return BatchReport(
                route: .files, bytes: bytes.count, uploadSeconds: uploadSeconds, transcriptionSeconds: transcriptionSeconds,
                remoteDeleted: deleted, result: result, retried: retried)
        }

        /// On this route `incomplete` is common (live probes: 5 of 10 file-route
        /// interactions ended there; inline, 0 of 5), so a truncated answer gets one more try on the
        /// same uploaded file. A second truncation or a failed retry keeps the first answer: the loop
        /// is at the tail, so its prefix is as good as any.
        private func retry(_ file: File, after first: BatchTranscript) async -> BatchTranscript {
            do {
                let second = try await interact(file)
                log.notice("batch files: incomplete with \(first.wordCount) words, retried: \(second.truncated ? "incomplete again" : "completed", privacy: .public) with \(second.wordCount) words")
                return second.truncated ? first : second
            } catch {
                log.error("batch files: incomplete with \(first.wordCount) words, retry failed: \(String(describing: error), privacy: .private)")
                return first
            }
        }

        private func upload(_ bytes: Data, displayName: String) async throws -> File {
            let start = try GeminiFiles.startRequest(byteCount: bytes.count, mimeType: "audio/flac", displayName: displayName, apiKey: apiKey)
            let (startBody, startResponse) = try await perform(start)
            let startStatus = (startResponse as? HTTPURLResponse)?.statusCode ?? 0
            guard startStatus == 200 else {
                throw BatchError.upload(status: startStatus, message: GeminiBatch.errorMessage(from: startBody))
            }
            let location = (startResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Goog-Upload-URL")
            guard location != nil else {
                throw BatchError.upload(status: startStatus, message: "no X-Goog-Upload-URL in the response")
            }
            // The audio goes only to the API's own host over https; nothing has been created yet,
            // so there is nothing to delete.
            guard let url = GeminiFiles.uploadURL(from: location) else {
                throw BatchError.upload(status: startStatus, message: "the X-Goog-Upload-URL is not on the API's host")
            }
            // Once this request finalizes, Google holds the audio. It runs in its own task so a
            // cancelled take still gets the response back and can delete what it created.
            let finalize = GeminiFiles.uploadRequest(to: url, bytes: bytes, apiKey: apiKey)
            let perform = perform
            let (body, response) = try await Task { try await perform(finalize) }.value
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw BatchError.upload(status: status, message: GeminiBatch.errorMessage(from: body)) }
            do {
                return try GeminiFiles.uploadedFile(from: body)
            } catch {
                if let name = GeminiFiles.uploadedName(from: body) {
                    await delete(name: name)
                }
                throw BatchError.upload(status: status, message: "unreadable File in the upload response")
            }
        }

        /// Audio is usually ACTIVE as soon as the upload finishes; a `PROCESSING` file is re-read
        /// until it is. A file with no state is tried as is.
        private func waitUntilActive(_ uploaded: File) async throws -> File {
            var file = uploaded
            var polls = 0
            while file.state == "PROCESSING", polls < GeminiFiles.maxPolls {
                try await Task.sleep(for: pollInterval)
                polls += 1
                let (body, response) = try await perform(GeminiFiles.fileRequest(name: file.name, method: "GET", apiKey: apiKey))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw BatchError.upload(status: status, message: GeminiBatch.errorMessage(from: body)) }
                file = try GeminiFiles.file(from: body)
            }
            if let state = file.state, state == "PROCESSING" || state == "FAILED" {
                throw BatchError.fileNotReady(state: state)
            }
            return file
        }

        private func interact(_ file: File) async throws -> BatchTranscript {
            // An hour of audio takes longer to transcribe than the inline route's 17 minutes.
            var request = URLRequest(url: GeminiBatch.endpoint, timeoutInterval: 600)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try GeminiBatch.requestBody(fileURI: file.uri, mimeType: "audio/flac", config: config)
            let (body, response) = try await perform(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw BatchError.http(status: status, message: GeminiBatch.errorMessage(from: body)) }
            return try GeminiBatch.transcript(from: body)
        }

        /// Google deletes uploads after 48 hours anyway, so a failed delete is logged, not thrown.
        /// It runs in its own task so a cancelled take still removes its audio from Google.
        @discardableResult
        private func delete(_ file: File) async -> Bool {
            await delete(name: file.name)
        }

        @discardableResult
        private func delete(name: String) async -> Bool {
            let request = GeminiFiles.fileRequest(name: name, method: "DELETE", apiKey: apiKey)
            let perform = perform
            let log = log
            return await Task {
                do {
                    let (body, response) = try await perform(request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else {
                        log.error("batch files: delete of \(name, privacy: .private) failed, HTTP \(status): \(GeminiBatch.errorMessage(from: body), privacy: .private)")
                        return false
                    }
                    return true
                } catch {
                    log.error("batch files: delete of \(name, privacy: .private) failed: \(String(describing: error), privacy: .private)")
                    return false
                }
            }.value
        }
    }
}
