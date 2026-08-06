import AVFoundation
import CoreMedia
import Foundation
import Speech

/// On-device transcription. Free, private, no third-party dependency, and with
/// native long-form support — so unlike the cloud backends there is no upload
/// cap and no chunking. This is the ONLY backend that runs automatically.
public struct SpeechAnalyzerTranscriber: Transcriber {
    public let id = "speechanalyzer"
    public let displayName = "On-device (Apple)"

    public init() {}

    public func isAvailable() async -> Bool {
        SpeechTranscriber.isAvailable
    }

    public func transcribe(audio: URL, locale: Locale) async throws -> TranscriptBody {
        guard let file = try? AVAudioFile(forReading: audio) else {
            throw TranscriberError.audioUnreadable(audio.path)
        }
        // `en_PH` is not one of the 45 locales the model ships for. The SDK maps a
        // request onto its nearest supported neighbour; the resolved locale, not
        // the requested one, is what actually ran and so is what gets recorded.
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.unavailable("On-device transcription in \(locale.identifier)")
        }

        let transcriber = SpeechTranscriber(
            locale: resolved,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange])
        try await Self.installModel(for: transcriber)

        let segments = try await Self.run(transcriber, over: file)
        return Self.body(fromSegments: segments, locale: resolved.identifier)
    }

    /// Model assets are downloaded on demand and are NOT bundled with macOS. On a
    /// fresh Mac the first transcription blocks here on a network fetch.
    private static func installModel(for transcriber: SpeechTranscriber) async throws {
        do {
            let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber])
            try await request?.downloadAndInstall()
        } catch {
            throw TranscriberError.backendFailed("model download: \(error.localizedDescription)")
        }
    }

    /// Results arrive on `transcriber.results` while the analyzer consumes the
    /// file, so the collector has to be running before analysis starts.
    private static func run(
        _ transcriber: SpeechTranscriber, over file: AVAudioFile
    ) async throws -> [Segment] {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var collected: [Segment] = []
            for try await result in transcriber.results {
                if let segment = Self.segment(from: result) { collected.append(segment) }
            }
            return collected
        }

        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collector.value
        } catch {
            collector.cancel()
            throw TranscriberError.backendFailed(error.localizedDescription)
        }
    }

    /// nil for a result carrying no words: it would otherwise widen the joined
    /// transcript by a stray separator. `speaker` is always nil — `SpeechAnalyzer`
    /// does not diarize, and a label that was never measured is worse than none.
    private static func segment(from result: SpeechTranscriber.Result) -> Segment? {
        let text = String(result.text.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Segment(start: result.range.start.seconds,
                       end: result.range.end.seconds,
                       text: text,
                       speaker: nil)
    }

    /// The pure part, and therefore the testable part. Kept separate from the
    /// `Speech` calls above precisely so it can be exercised without a model.
    static func body(fromSegments segments: [Segment], locale: String) -> TranscriptBody {
        TranscriptBody(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            locale: locale,
            backend: "speechanalyzer",
            modelID: "SpeechTranscriber")
    }
}
