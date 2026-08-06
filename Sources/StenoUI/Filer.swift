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
        // the signature prefix is not decoration. Checked against the FRONT
        // MATTER only, not the whole file — the transcript body is dictated
        // speech and must never be able to forge a match.
        if let existing = try? String(contentsOf: destination, encoding: .utf8),
           !Self.frontMatter(of: existing).contains("signature: \(owner.signature)") {
            let stem = Self.noteStem(for: owner) + " " + String(owner.signature.prefix(8))
            destination = folder.appendingPathComponent(stem + ".md")
        }

        try Self.render(sidecar: owner, transcript: transcript)
            .write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    /// `noteURL(for:topic:)` only ever computes the UNSUFFIXED path, but
    /// `write` may have persisted this sidecar's note under a signature-suffixed
    /// name if it once collided with another recording at that path. Locating
    /// by front-matter signature — the same identity `write` already uses to
    /// tell "mine" from "someone else's" — finds it either way, instead of
    /// silently no-op'ing on a suffixed note and orphaning it.
    public func removeNote(for sidecar: Sidecar, topic: String) {
        // Every WRITE path re-sanitises an untrusted topic string before it
        // becomes part of a filesystem path (see `write(for:transcript:)`
        // above and `TopicName`'s own doc comment on why this is the one real
        // security surface here); this delete path took `topic` on faith.
        // Re-sanitising and refusing to act on a rejected topic closes that.
        guard let topic = TopicName.sanitised(topic) else { return }
        let folder = root.appendingPathComponent(topic)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return }

        for name in names where name.hasSuffix(".md") {
            let url = folder.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  Self.frontMatter(of: text).contains("signature: \(sidecar.signature)")
            else { continue }
            try? FileManager.default.removeItem(at: url)
            return
        }
        // No note found for this sidecar — nothing to do. Leave the folder even
        // if now empty: the user may have put other things in it.
    }

    /// Removes every NOTE this type owns inside a topic folder it owns, and
    /// regenerates them.
    ///
    /// A folder is "owned" when its name matches some sidecar's topic. Anything
    /// else at the root is left alone — dated folders, `.incoming`, and whatever
    /// the user put there. Critically, the same restraint applies INSIDE an
    /// owned folder: a topic folder sits at the library root, in Finder, where
    /// a person can and does drop their own files — `removeNote`'s doc comment
    /// says exactly this. Deleting the whole folder tree, as this once did,
    /// destroyed anything a user had put there. Only `.md` files whose front
    /// matter carries a `signature:` belonging to one of the passed-in
    /// sidecars are removed; every other file — a user's own, or an unrelated
    /// note with no matching signature — is left untouched.
    public func rebuild(from sidecars: [Sidecar], store: TranscriptStore) throws {
        let signatures = Set(sidecars.map(\.signature))
        let topics = Set(sidecars.compactMap { $0.topic.flatMap(TopicName.sanitised) })
        for topic in topics {
            let folder = root.appendingPathComponent(topic)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
            else { continue }
            for name in names where name.hasSuffix(".md") {
                let url = folder.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let signature = Self.signature(inFrontMatter: Self.frontMatter(of: text)),
                      signatures.contains(signature)
                else { continue }
                try? FileManager.default.removeItem(at: url)
            }
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
        // Value-type format style, not a formatter instance: no shared mutable
        // state, so nothing here needs a concurrency escape hatch.
        let recorded = sidecar.recordedAt?.ISO8601Format() ?? ""
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

    /// The text strictly between the two `---` fences `render` writes at the
    /// top of every note, or the whole string if the fences aren't there. Every
    /// identity check (the collision guard, `removeNote`) matches against this
    /// slice rather than the full file, so a transcript that happens to
    /// contain the literal substring "signature: ..." can never be mistaken
    /// for the note's own front matter.
    private static func frontMatter(of text: String) -> Substring {
        guard text.hasPrefix("---\n") else { return Substring(text) }
        let afterOpeningFence = text.index(text.startIndex, offsetBy: 4)
        guard let closingFence = text.range(
            of: "\n---\n", range: afterOpeningFence..<text.endIndex)
        else { return Substring(text) }
        return text[afterOpeningFence..<closingFence.lowerBound]
    }

    /// The value of the `signature:` line inside a front-matter slice, or nil
    /// if there isn't one. `rebuild` uses this to decide whether a note found
    /// on disk is one this type owns, rather than doing an O(sidecars) substring
    /// `contains` check per file that could in principle match a signature
    /// that is merely a substring of another.
    private static func signature(inFrontMatter frontMatter: Substring) -> String? {
        for line in frontMatter.split(separator: "\n") {
            if line.hasPrefix("signature: ") {
                return String(line.dropFirst("signature: ".count))
            }
        }
        return nil
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
