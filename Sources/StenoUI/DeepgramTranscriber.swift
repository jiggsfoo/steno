import Foundation

/// Cloud transcription, run only on explicit request for one recording.
///
/// Chosen over Whisper-family APIs because it adds a CAPABILITY rather than
/// accuracy: speaker diarization, which no on-device option provides. It also
/// accepts hour-long files directly, so there is no 25 MB cap to chunk around.
public struct DeepgramTranscriber: Transcriber {
    public static let keychainAccount = "deepgram-api-key"

    public let id = "deepgram"
    public let displayName = "Deepgram Nova-3 (cloud)"

    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func isAvailable() async -> Bool {
        Keychain.string(for: Self.keychainAccount) != nil
    }

    public func transcribe(audio: URL, locale: Locale) async throws -> TranscriptBody {
        guard let key = Keychain.string(for: Self.keychainAccount) else {
            throw TranscriberError.missingCredential("Deepgram")
        }
        guard let file = try? Data(contentsOf: audio) else {
            throw TranscriberError.audioUnreadable(audio.path)
        }

        let request = try Self.request(for: audio, apiKey: key)
        let (data, response) = try await session.upload(for: request, from: file)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriberError.backendFailed("no HTTP response")
        }
        guard http.statusCode == 200 else {
            throw Self.error(forStatus: http.statusCode)
        }

        return try Self.body(fromResponse: data, locale: locale.identifier)
    }

    /// A revoked or mistyped key comes back as 401, not a transport failure.
    /// `.missingCredential` already carries the right copy ("Add one in
    /// Settings") — collapsing it into `.backendFailed` would tell the user
    /// to retry a call that will never succeed until the key itself is
    /// fixed. Every other non-200 status stays a generic backend failure;
    /// no case is added for 429 or 5xx since nothing consumes them
    /// differently yet.
    static func error(forStatus status: Int) -> TranscriberError {
        switch status {
        case 401:
            return .missingCredential("Deepgram")
        default:
            return .backendFailed("HTTP \(status)")
        }
    }

    /// The key travels in the Authorization header, never the URL — query
    /// strings end up in logs and proxies.
    static func request(for audio: URL, apiKey: String) throws -> URLRequest {
        guard !apiKey.isEmpty else {
            throw TranscriberError.missingCredential("Deepgram")
        }
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Throws rather than returning empty text: a silently blank transcript
    /// would be written to disk and treated as done, and re-running it costs
    /// money the user already spent.
    ///
    /// Only `results.utterances[]` is decoded — verified against a real
    /// captured response, which also carries `results.channels[].alternatives`
    /// (word-level detail Deepgram uses for the transcript we don't need
    /// twice) and a `metadata` block. Both are ignored: `Decodable` skips
    /// unmodeled keys, so no `CodingKeys` restriction is needed to drop them.
    static func body(fromResponse data: Data, locale: String) throws -> TranscriptBody {
        struct Response: Decodable {
            struct Results: Decodable {
                struct Utterance: Decodable {
                    let start: Double
                    let end: Double
                    let transcript: String
                    let speaker: Int?
                }
                let utterances: [Utterance]?
            }
            let results: Results
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let utterances = decoded.results.utterances, !utterances.isEmpty else {
            throw TranscriberError.backendFailed("no utterances in response")
        }

        let segments = utterances.map {
            Segment(start: $0.start, end: $0.end, text: $0.transcript, speaker: $0.speaker)
        }
        return TranscriptBody(text: segments.map(\.text).joined(separator: " "),
                              segments: segments,
                              locale: locale,
                              backend: "deepgram",
                              modelID: "nova-3")
    }
}
