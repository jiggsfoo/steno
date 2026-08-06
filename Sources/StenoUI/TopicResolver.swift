import Foundation
// NOTE: `FoundationModels` declares its own `Transcript` (the model's
// conversation history). Unqualified `Transcript` in this file is Steno's, as
// the current module wins name lookup — but qualify anything ambiguous you add.
import FoundationModels

public struct Filing: Sendable, Equatable {
    public let title: String
    public let topic: String?

    public init(title: String, topic: String?) {
        self.title = title
        self.topic = topic
    }
}

/// The model boundary, extracted so `TopicResolver`'s gating logic is testable
/// without Apple Intelligence being available on the machine running the tests.
public protocol FilingSuggester: Sendable {
    func suggest(from text: String, directiveWasSpoken: Bool) async -> Filing?
}

/// Turns a transcript into a title and, only when permitted, a topic.
public struct TopicResolver: Sendable {
    private static let titleWordLimit = 8

    private let suggester: (any FilingSuggester)?

    /// `nil` means no on-device model — Apple Intelligence disabled or
    /// unsupported hardware. Everything still works, just more literally.
    public init(suggester: (any FilingSuggester)?) {
        self.suggester = suggester
    }

    public func resolve(_ transcript: Transcript) async -> Filing {
        let directive = DirectiveParser.parse(transcript.text)
        let suggestion = await suggester?.suggest(from: transcript.text,
                                                  directiveWasSpoken: directive != nil)
        let title = Self.title(suggestedBy: suggestion, orFallingBackTo: transcript.text)

        // The regex GRANTS PERMISSION. Without a directive there is no topic,
        // no matter how confident the model was.
        guard let directive else {
            return Filing(title: title, topic: nil)
        }

        // The model may reword the captured tail into a real folder name; with
        // no model the capture is used literally. Either way it is untrusted
        // text on its way to becoming a path, so `TopicName` gets the last word.
        let candidate = suggestion?.topic ?? directive.capturedTail
        return Filing(title: title, topic: TopicName.sanitised(candidate))
    }

    private static func title(suggestedBy suggestion: Filing?,
                              orFallingBackTo text: String) -> String {
        let suggested = suggestion?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return suggested.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle(from: text)
    }

    /// Used when there is no model, and when the model returns a blank title.
    static func fallbackTitle(from text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(titleWordLimit)
        guard !words.isEmpty else { return "Untitled recording" }
        return words.joined(separator: " ")
    }
}

/// `FoundationModels` wrapper. Returns nil rather than throwing so an
/// unavailable model degrades instead of failing the whole pipeline.
public struct OnDeviceSuggester: FilingSuggester {
    /// `.unavailable` carries a reason — Apple Intelligence off, hardware not
    /// eligible, or the model still downloading. All three are the same answer
    /// here: no model, so `TopicResolver` falls back to the regex capture.
    public init?() {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
    }

    /// What the model is asked to produce.
    @Generable
    struct Suggestion {
        @Guide(description: "A short descriptive title for this recording, at most 8 words. No quotes.")
        var title: String
        @Guide(description: "The exact folder name the speaker asked this to be filed under. Empty string if they did not ask.")
        var topic: String
    }

    public func suggest(from text: String, directiveWasSpoken: Bool) async -> Filing? {
        let excerpt = Self.excerpt(of: text)
        let session = LanguageModelSession(instructions: """
            You label voice recordings. Produce a short title. If, and only if, \
            the speaker explicitly asked for this to be filed somewhere, put \
            that exact folder name in topic. Otherwise leave topic empty.
            """)

        guard let response = try? await session.respond(
            to: excerpt, generating: Suggestion.self) else { return nil }

        let topic = response.content.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        return Filing(title: response.content.title,
                      topic: (directiveWasSpoken && !topic.isEmpty) ? topic : nil)
    }

    /// Only the head and tail are sent. Directives are spoken near an edge, and
    /// a 66-minute transcript would blow the context window.
    static func excerpt(of text: String, edge: Int = 1_500) -> String {
        guard text.count > edge * 2 else { return text }
        return String(text.prefix(edge)) + "\n…\n" + String(text.suffix(edge))
    }
}
