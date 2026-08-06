import Foundation

/// Reads and writes the canonical `.transcript` beside each recording.
public struct TranscriptStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `<audio stem>.transcript`, beside the audio.
    ///
    /// Deliberately NOT `.transcript.json`. `Library.scanSidecars()` enumerates
    /// the whole root and decode-attempts everything with `pathExtension ==
    /// "json"`. A transcript is not a sidecar and must not enter that path.
    public static func url(forAudio url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("transcript")
    }

    public func url(for sidecar: Sidecar) -> URL {
        Self.url(forAudio: root.appendingPathComponent(sidecar.relativePath))
    }

    /// nil when absent, undecodable, or carrying a DIFFERENT recording's
    /// signature. Refusing beats displaying: a transcript attached to the wrong
    /// recording is worse than no transcript at all.
    public func transcript(for sidecar: Sidecar) -> Transcript? {
        guard let data = try? Data(contentsOf: url(for: sidecar)),
              let transcript = try? Library.decoder.decode(Transcript.self, from: data),
              transcript.signature == sidecar.signature
        else { return nil }
        return transcript
    }

    /// The queue's definition of "already done". Deliberately the presence of a
    /// VALID transcript file rather than `sidecar.transcribedAt`, so a crash
    /// between the transcript write and the sidecar write never re-spends money.
    public func has(_ sidecar: Sidecar) -> Bool {
        transcript(for: sidecar) != nil
    }

    /// Stamps the sidecar's signature onto the body and installs it atomically.
    @discardableResult
    public func write(_ body: TranscriptBody, for sidecar: Sidecar,
                      at transcribedAt: Date) throws -> Transcript {
        let transcript = Transcript(body: body, sidecar: sidecar, transcribedAt: transcribedAt)
        let destination = url(for: sidecar)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // UUID-suffixed, not a fixed `.part`: the automatic sweep and a
        // manual retry can both be writing THIS sidecar's transcript at
        // once, and a shared staging name means two writers share one
        // inode. `.write(options: .atomic)` on top closes the other half of
        // that race -- without it, `Data.write` is a plain open/truncate/
        // write and two interleaved calls can still tear the staged file
        // before either install ever runs. `.part` stays the trailing
        // extension (`appendingPathExtension` just adds another dot-segment)
        // so `pathExtension` still reads "part" and this file is still
        // skipped by anything scanning for a different suffix.
        let staged = destination.appendingPathExtension("\(UUID().uuidString).part")
        try Library.encoder.encode(transcript).write(to: staged, options: .atomic)
        do {
            try Library.install(staged, at: destination)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return transcript
    }
}
