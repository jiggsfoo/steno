import Foundation

public struct QueueProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int
}

/// Serialised transcription and filing.
///
/// The work list is DERIVED, never persisted. "What needs transcribing" is
/// computed by asking `TranscriptStore` what lacks a valid transcript, so there
/// is no job file to go stale or corrupt — the same reasoning that makes
/// `index.sqlite` disposable.
public actor TranscriptionQueue {
    /// PINNED, not `Locale.current`.
    ///
    /// `en_PH` is not a supported `SpeechTranscriber` locale, and
    /// `supportedLocale(equivalentTo:)` resolved it to a DIFFERENT English
    /// variant on each run during the Task 4 gate — `en_AU`, `en_US`, and
    /// `en_SG` were all observed. That makes both the acoustic model and the
    /// `locale` recorded in every transcript vary run to run, which is not
    /// something a provenance field is allowed to do. Explicit locales resolve
    /// to themselves, so pinning removes the non-determinism outright.
    /// Variants agreed 94–99.7% on real audio, so the pin costs almost nothing.
    public static let locale = Locale(identifier: "en_US")

    private let root: URL
    private let store: TranscriptStore
    private let filer: Filer
    private let resolver: TopicResolver
    private let transcriber: any Transcriber
    private let maxAttempts: Int

    public init(root: URL, store: TranscriptStore, filer: Filer,
                resolver: TopicResolver, transcriber: any Transcriber,
                maxAttempts: Int = 3) {
        self.root = root
        self.store = store
        self.filer = filer
        self.resolver = resolver
        self.transcriber = transcriber
        self.maxAttempts = maxAttempts
    }

    /// Everything still owed work, cheapest check first.
    public func pending(from sidecars: [Sidecar]) -> [Sidecar] {
        sidecars.filter { sidecar in
            guard !store.has(sidecar) else { return false }
            return (sidecar.transcriptionAttempts ?? 0) < maxAttempts
        }
    }

    /// Transcribes, files, and returns the updated sidecar. The CALLER persists
    /// it and updates the index — this actor owns no `Library`.
    ///
    /// Write order is the inverse of `Library.commit`'s. There the expensive
    /// thing is the download, so audio goes first. Here it is transcription, and
    /// the already-done check is the transcript FILE, so a crash between steps
    /// only ever repeats free work.
    public func process(_ sidecar: Sidecar) async -> Sidecar {
        var updated = sidecar

        // 1. Transcript — skipped entirely when one already exists.
        let transcript: Transcript
        if let existing = store.transcript(for: sidecar) {
            transcript = existing
        } else {
            // The cap must be enforced HERE, not only in `pending`. `pending`
            // is a convenience for callers building a work list; `process` is
            // the actual spending gate, and it is called directly by the
            // caller as well (e.g. a crash-recovery pass, or a manual retry
            // loop). Without this guard a sidecar that already exhausted its
            // attempts would keep paying for the transcriber on every direct
            // `process` call — exactly the unbounded re-spend the cap exists
            // to prevent.
            guard (sidecar.transcriptionAttempts ?? 0) < maxAttempts else {
                return sidecar
            }

            let audio = root.appendingPathComponent(sidecar.relativePath)
            do {
                let body = try await transcriber.transcribe(
                    audio: audio, locale: Self.locale)
                transcript = try store.write(body, for: sidecar, at: Date())
            } catch {
                updated.transcriptionAttempts = (sidecar.transcriptionAttempts ?? 0) + 1
                return updated
            }
        }

        // 2. Sidecar fields.
        let filing = await resolver.resolve(transcript)
        let previousTopic = sidecar.topic
        updated.title = filing.title
        updated.topic = filing.topic
        updated.transcribedAt = transcript.transcribedAt
        updated.transcriptBackend = transcript.backend
        updated.transcriptionAttempts = nil

        // 3. Note. Regenerable, so a failure here is not worth failing the run.
        if let previousTopic, previousTopic != filing.topic {
            filer.removeNote(for: sidecar, topic: previousTopic)
        }
        if filing.topic != nil {
            _ = try? filer.write(for: updated, transcript: transcript)
        }

        return updated
    }
}
