import Foundation

/// Writes and regenerates the notes in topic folders.
///
/// Everything this type produces is DERIVED. Delete the whole tree and
/// `rebuild(from:store:)` puts it back from sidecars plus transcripts, exactly
/// as `rebuildIndex()` does for `index.sqlite`. Nothing here is canonical, which
/// is precisely why an AI-guessed topic is allowed to drive it.
public struct Filer: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// `<root>/<Topic>/<YYYY-MM-DD HHmm> <title>.md`
    public func noteURL(for sidecar: Sidecar, topic: String) -> URL {
        root.appendingPathComponent(topic)
            .appendingPathComponent(Self.noteStem(for: sidecar) + ".md")
    }

    @discardableResult
    public func write(for owner: Sidecar, transcript: Transcript) throws -> URL {
        guard let topic = owner.topic.flatMap(TopicName.sanitised) else {
            throw FilerError.noTopic(owner.signature)
        }
        let folder = root.appendingPathComponent(topic)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var destination = noteURL(for: owner, topic: topic)

        // Idempotent by signature. Same recording -> overwrite. DIFFERENT
        // recording at the same path -> the newcomer moves aside rather than
        // destroying the incumbent. `Library` learned this the expensive way:
        // the signature prefix is not decoration.
        if let existing = try? String(contentsOf: destination, encoding: .utf8),
           !existing.contains("signature: \(owner.signature)") {
            let stem = Self.noteStem(for: owner) + " " + String(owner.signature.prefix(8))
            destination = folder.appendingPathComponent(stem + ".md")
        }

        try Self.render(sidecar: owner, transcript: transcript)
            .write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    public func removeNote(for sidecar: Sidecar, topic: String) {
        try? FileManager.default.removeItem(at: noteURL(for: sidecar, topic: topic))
        // Leave the folder even if now empty: the user may have put things in it.
    }

    /// Removes every topic folder this type owns and regenerates them.
    ///
    /// A folder is "owned" when its name matches some sidecar's topic. Anything
    /// else at the root is left alone — dated folders, `.incoming`, and whatever
    /// the user put there.
    public func rebuild(from sidecars: [Sidecar], store: TranscriptStore) throws {
        let topics = Set(sidecars.compactMap { $0.topic.flatMap(TopicName.sanitised) })
        for topic in topics {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(topic))
        }
        for sidecar in sidecars {
            guard sidecar.topic.flatMap(TopicName.sanitised) != nil,
                  let transcript = store.transcript(for: sidecar) else { continue }
            try write(for: sidecar, transcript: transcript)
        }
    }

    static func noteStem(for sidecar: Sidecar) -> String {
        let stamp = sidecar.recordedAt.map(Self.stampFormatter.string(from:)) ?? "undated"
        let title = (sidecar.title ?? "Untitled recording")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(stamp) \(title.isEmpty ? "Untitled recording" : title)"
    }

    /// `signature` in the front matter is what makes writing idempotent — it is
    /// how a rewrite tells "this is my note" from "this is someone else's".
    static func render(sidecar: Sidecar, transcript: Transcript) -> String {
        let recorded = sidecar.recordedAt.map(Library.iso8601.string(from:)) ?? ""
        return """
            ---
            signature: \(sidecar.signature)
            recordedAt: \(recorded)
            audio: ../\(sidecar.relativePath)
            backend: \(transcript.backend)
            ---

            # \(sidecar.title ?? "Untitled recording")

            \(transcript.text)

            """
    }

    // en_US_POSIX for the same reason `Library` uses it: under a non-Gregorian
    // Locale.current the folder layout would become locale-dependent.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()
}

public enum FilerError: Error, Equatable {
    case noTopic(String)
}
