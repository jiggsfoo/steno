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

    /// Everything still owed work, cheapest check first: the in-memory attempt
    /// count before the disk read+decode `store.has(sidecar)` performs. A
    /// capped sidecar is excluded without ever touching disk.
    ///
    /// `sidecar.transcribedAt == nil` also admits a sidecar THAT HAS a valid
    /// transcript: `run` writes the transcript before the caller persists the
    /// sidecar, so a crash in between leaves a transcript on disk describing a
    /// sidecar that never learned about it. Without this, `!store.has(sidecar)`
    /// alone reads that state as "already done" -- title, topic, transcribedAt,
    /// and the topic-folder note are then never written, permanently, because
    /// nothing ever revisits it again. `run`'s own step 1 already skips
    /// re-transcribing when a transcript exists, so this only pays for the
    /// cheap steps (filing, note) a second time, never the transcription itself.
    public func pending(from sidecars: [Sidecar]) -> [Sidecar] {
        sidecars.filter { sidecar in
            guard (sidecar.transcriptionAttempts ?? 0) < maxAttempts else { return false }
            return !store.has(sidecar) || sidecar.transcribedAt == nil
        }
    }

    /// Automatic-sweep entry point — launch and post-sync. Respects
    /// `transcriptionAttempts`'s cap, so a permanently undecodable recording
    /// stops being retried forever. The CALLER persists the returned sidecar
    /// and updates the index — this actor owns no `Library`.
    public func process(_ sidecar: Sidecar) async -> Sidecar {
        await run(sidecar, respectingCap: true)
    }

    /// User-initiated "Transcribe Again". Per `Sidecar.transcriptionAttempts`'s
    /// own documented contract — "Bounds automatic retry... Manual retry
    /// ignores it" — this deliberately crosses the cap `process` enforces.
    ///
    /// Attempts are reset before the shared work starts, so a retry that
    /// fails again counts from zero instead of inheriting an already-spent
    /// budget; a retry that succeeds is already left clean by the normal
    /// success path in `run`, which clears the field outright.
    public func retry(_ sidecar: Sidecar) async -> Sidecar {
        var reset = sidecar
        reset.transcriptionAttempts = nil
        return await run(reset, respectingCap: false)
    }

    /// Transcribes, files, and returns the updated sidecar. Shared by
    /// `process` and `retry` so the money-protection logic exists in exactly
    /// one place; the two entry points differ in whether the attempt cap
    /// applies AND in whether an existing transcript is reused.
    ///
    /// Write order is the inverse of `Library.commit`'s. There the expensive
    /// thing is the download, so audio goes first. Here it is transcription, and
    /// the already-done check is the transcript FILE, so a crash between steps
    /// only ever repeats free work.
    ///
    /// `process` skips re-transcribing when a transcript already exists — that
    /// is what makes the automatic sweep idempotent. `retry` is the deliberate,
    /// user-initiated "do this again, maybe with a different backend" path, so
    /// it must NEVER take that skip; it always calls the transcriber. The
    /// caller therefore does not need to (and must not) delete the old
    /// transcript first: `store.write` installs via `Library.install`, which
    /// atomically REPLACES an existing file at that path rather than requiring
    /// it be gone first, so the old transcript stays valid and readable right
    /// up to the instant the new one lands — no window where a crash or a
    /// failed backend call leaves neither on disk.
    private func run(_ sidecar: Sidecar, respectingCap: Bool) async -> Sidecar {
        var updated = sidecar

        // 1. Transcript. `respectingCap` doubles as "is this `process`, not
        // `retry`" here — see the doc comment above for why `retry` must
        // never take this reuse branch.
        let transcript: Transcript
        if respectingCap, let existing = store.transcript(for: sidecar) {
            transcript = existing
        } else {
            // The cap protects the AUTOMATIC sweeps from re-spending on a
            // recording that keeps failing — it is not meant to block a
            // deliberate, human-initiated retry. `retry` passes
            // `respectingCap: false` to cross it on purpose, matching
            // `Sidecar.transcriptionAttempts`'s own contract.
            if respectingCap {
                guard (sidecar.transcriptionAttempts ?? 0) < maxAttempts else {
                    return sidecar
                }
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
        //
        // The note's FILENAME embeds the title, not just the topic -- see
        // `Filer.noteStem(for:)`, `"<stamp> <title>.md"`. Removing only when
        // the TOPIC changed therefore missed the far more common case: a
        // re-run that keeps the same topic but produces a different title
        // (re-transcribing almost always retitles) writes a new file at a new
        // path and leaves the old one behind, orphaned -- two notes then
        // claim the same recording via identical `signature:` front matter.
        // Removing unconditionally whenever a previous topic existed, before
        // writing the new note, closes that: `removeNote` locates by
        // front-matter signature, not by recomputing a path, so it finds the
        // old note (wherever its title put it) regardless of whether the
        // topic is about to change, stay the same, or go away entirely.
        if let previousTopic {
            filer.removeNote(for: sidecar, topic: previousTopic)
        }
        if filing.topic != nil {
            _ = try? filer.write(for: updated, transcript: transcript)
        }

        return updated
    }
}
