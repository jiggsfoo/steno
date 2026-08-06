import Foundation

public struct Directive: Sendable, Equatable {
    /// The phrase that matched, kept for the diagnostic log.
    public let matchedPhrase: String
    /// Everything between the phrase and the next sentence end. Used verbatim
    /// as the topic ONLY when `FoundationModels` is unavailable.
    public let capturedTail: String
}

/// Decides whether a filing directive was spoken. Deliberately NOT the thing
/// that decides the folder name.
///
/// This is the guard that stops a recording which merely mentions groceries
/// from being filed under Grocery List. The model downstream is free to
/// interpret; it is not free to invent an instruction that was never given.
public enum DirectiveParser {
    /// EXPLICIT FILING VERBS ONLY. `put` and `stick` are deliberately absent.
    ///
    /// They were in this list until the Task 4 quality gate ran it against 3
    /// hours of real recordings, where `put (this|that|it) into` matched
    /// "put it into the payment method" and "put it into a sprayer" — both
    /// buried in real client calls, both of which would have filed that call
    /// under a topic nobody asked for. Twelve directive-shaped phrases turned
    /// up in that corpus and not one was a real directive.
    ///
    /// The prefilter's entire value is in what it REFUSES. Recall is the
    /// cheap side of this trade: an unfiled recording is visible and fixed by
    /// editing one sidecar field, while a misfiled client call is the failure
    /// the whole design was built to avoid. If a phrasing you use is missed,
    /// change the phrasing before widening the grammar.
    private static let patterns = [
        #"\bfile\s+(?:this|that|it)\s+under\s+(.+)"#,
        #"\bfile\s+(?:this|that|it)\s+(?:in|to|into)\s+(.+)"#,
        #"\bfiling\s+(?:this|that|it)\s+under\s+(.+)"#,
        #"\bsave\s+(?:this|that|it)\s+(?:under|in|to|into)\s+(.+)"#,
    ]

    public static func parse(_ text: String) -> Directive? {
        var best: (range: Range<String.Index>, tail: String, phrase: String)?

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]) else { continue }
            let full = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: full),
                  let matchRange = Range(match.range, in: text),
                  let tailRange = Range(match.range(at: 1), in: text) else { continue }

            let tail = trimToSentence(String(text[tailRange]))
            guard !tail.isEmpty else { continue }

            // Earliest directive in the recording wins.
            if best == nil || matchRange.lowerBound < best!.range.lowerBound {
                best = (matchRange, tail, String(text[matchRange]))
            }
        }

        guard let best else { return nil }
        return Directive(matchedPhrase: best.phrase, capturedTail: best.tail)
    }

    /// Spoken directives arrive with punctuation as often as without, so stop at
    /// the first sentence end if there is one and take the whole tail if not.
    private static func trimToSentence(_ tail: String) -> String {
        let stop = tail.firstIndex { ".!?\n".contains($0) }
        let head = stop.map { String(tail[tail.startIndex..<$0]) } ?? tail
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
