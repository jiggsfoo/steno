import Foundation

/// Turns a model-generated string into a folder name, or refuses.
///
/// This is the only place in spec 2 where untrusted text becomes a filesystem
/// path, so it REJECTS rather than repairs. Repairing invites the class of bug
/// where `../../etc` quietly becomes `etc` and lands somewhere surprising;
/// refusing means the recording is simply not filed, which is a failure the
/// user can see and correct.
public enum TopicName {
    private static let maxLength = 60

    /// Names the library already owns. A topic folder sits at the library root
    /// beside these, so a collision is indistinguishable from the real thing.
    ///
    /// `LibrarySidebar.unfiled` is in here for a related but distinct reason,
    /// worth spelling out: it is not a folder at all. It is the heading the
    /// sidebar files every UNTOPICED recording under
    /// (`sidecar.topic ?? unfiled`), so a recording genuinely filed under a
    /// topic of that name merges into the "no topic" group and becomes
    /// indistinguishable from the recordings that have no topic — the same
    /// class of collision as `undated`, one level up in the UI instead of on
    /// disk. Referenced rather than respelled as a second literal, so the two
    /// cannot drift.
    ///
    /// Matched case-INSENSITIVELY: `sanitised` lowercases before this lookup,
    /// so every entry here must be lowercase. That is the right comparison for
    /// all three. A folder called "Undated" collides with `undated` on a
    /// case-insensitive volume, which is the macOS default; and the sidebar
    /// groups on the topic string itself, where "unfiled" and "Unfiled" would
    /// merely produce two adjacent headings that both look like the sentinel.
    private static let reserved: Set<String> = [
        "undated",
        ".incoming",
        LibrarySidebar.unfiled.lowercased(),
    ]

    public static func sanitised(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty,
              trimmed.count <= maxLength,
              !trimmed.hasPrefix("."),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(":"),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !reserved.contains(trimmed.lowercased()),
              !isDateShaped(trimmed)
        else { return nil }

        return trimmed
    }

    /// `Library.destinationURL` writes `yyyy-MM-dd` folders at the same level.
    private static func isDateShaped(_ name: String) -> Bool {
        name.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil
    }
}
