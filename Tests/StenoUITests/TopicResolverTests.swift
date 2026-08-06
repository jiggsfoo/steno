import Foundation
import Testing
@testable import StenoUI

private struct StubSuggester: FilingSuggester {
    var filing: Filing?
    func suggest(from text: String, directiveWasSpoken: Bool) async -> Filing? { filing }
}

/// Records what the resolver told the model boundary. An actor because
/// `FilingSuggester` is `Sendable` and `suggest` is non-mutating, matching
/// `FakeDevice`'s approach to the same problem.
private actor SpyRecorder {
    private(set) var directiveWasSpoken: Bool?
    private(set) var text: String?

    func record(text: String, directiveWasSpoken: Bool) {
        self.text = text
        self.directiveWasSpoken = directiveWasSpoken
    }
}

private struct SpySuggester: FilingSuggester {
    let recorder: SpyRecorder
    var filing: Filing?

    func suggest(from text: String, directiveWasSpoken: Bool) async -> Filing? {
        await recorder.record(text: text, directiveWasSpoken: directiveWasSpoken)
        return filing
    }
}

private func transcript(_ text: String) -> Transcript {
    Transcript(signature: "sig", text: text, segments: [], locale: "en_PH",
               backend: "speechanalyzer", modelID: "SpeechTranscriber",
               transcribedAt: Date(timeIntervalSince1970: 0), audioDurationSeconds: 60)
}

/// THE guard. Even when the model returns a confident topic, no directive in
/// the audio means no filing. The model may interpret; it may not invent an
/// instruction that was never given.
@Test func aModelTopicIsDiscardedWhenNoDirectiveWasSpoken() async {
    let suggester = StubSuggester(filing: Filing(title: "Shopping", topic: "Grocery List"))
    let resolver = TopicResolver(suggester: suggester)

    let filing = await resolver.resolve(transcript("I should buy groceries later."))

    #expect(filing.topic == nil)
    #expect(filing.title == "Shopping")
}

@Test func aModelTopicIsKeptWhenADirectiveWasSpoken() async {
    let suggester = StubSuggester(filing: Filing(title: "Shopping", topic: "Grocery List"))
    let resolver = TopicResolver(suggester: suggester)

    let filing = await resolver.resolve(transcript("File this under Grocery List."))

    #expect(filing.topic == "Grocery List")
}

/// Model output is untrusted text on its way to becoming a path.
@Test func anUnsafeModelTopicIsRejectedEvenWithADirective() async {
    let suggester = StubSuggester(filing: Filing(title: "T", topic: "../../etc"))
    let resolver = TopicResolver(suggester: suggester)

    let filing = await resolver.resolve(transcript("File this under whatever."))

    #expect(filing.topic == nil)
}

/// Apple Intelligence off, or unsupported hardware. Filing still works, just
/// more literally.
@Test func withNoSuggesterTheRegexCaptureBecomesTheTopic() async {
    let resolver = TopicResolver(suggester: nil)

    let filing = await resolver.resolve(transcript("File this under Grocery List. Then we talked."))

    #expect(filing.topic == "Grocery List")
}

@Test func withNoSuggesterTheTitleFallsBackToOpeningWords() async {
    let resolver = TopicResolver(suggester: nil)

    let filing = await resolver.resolve(
        transcript("Right so the supplier called about the delayed shipment and we agreed to push"))

    #expect(filing.title == "Right so the supplier called about the delayed")
}

@Test func fallbackTitleIsCappedAtEightWords() {
    let title = TopicResolver.fallbackTitle(from: "one two three four five six seven eight nine ten")

    #expect(title == "one two three four five six seven eight")
}

@Test func anEmptyTranscriptStillProducesAUsableTitle() async {
    let resolver = TopicResolver(suggester: nil)

    let filing = await resolver.resolve(transcript(""))

    #expect(filing.title == "Untitled recording")
    #expect(filing.topic == nil)
}

/// A model that returns a blank title must not produce a blank filename.
@Test func aBlankModelTitleFallsBackToTheOpeningWords() async {
    let suggester = StubSuggester(filing: Filing(title: "   ", topic: nil))
    let resolver = TopicResolver(suggester: suggester)

    let filing = await resolver.resolve(transcript("one two three four five six seven eight nine"))

    #expect(filing.title == "one two three four five six seven eight")
}

/// `OnDeviceSuggester` re-applies the gate on its own side, so it has to be
/// told the truth. A resolver that always said `false` would still pass every
/// test above, because the gate it enforces itself would mask the lie.
@Test func theSuggesterIsToldWhetherADirectiveWasSpoken() async {
    let spoken = SpyRecorder()
    _ = await TopicResolver(suggester: SpySuggester(recorder: spoken, filing: nil))
        .resolve(transcript("File this under Grocery List."))
    #expect(await spoken.directiveWasSpoken == true)

    let silent = SpyRecorder()
    _ = await TopicResolver(suggester: SpySuggester(recorder: silent, filing: nil))
        .resolve(transcript("I should buy groceries later."))
    #expect(await silent.directiveWasSpoken == false)
}

/// A 66-minute recording is ~55,000 characters and will not fit a context
/// window. Directives are spoken near an edge, so head+tail is what goes.
@Test func aLongTranscriptIsSentToTheModelAsHeadAndTailOnly() {
    let text = String(repeating: "a", count: 200) + String(repeating: "b", count: 200)
    let excerpt = OnDeviceSuggester.excerpt(of: text, edge: 100)

    #expect(excerpt.hasPrefix(String(repeating: "a", count: 100)))
    #expect(excerpt.hasSuffix(String(repeating: "b", count: 100)))
    #expect(excerpt.count < text.count)
}

@Test func aShortTranscriptIsSentToTheModelWhole() {
    let text = "File this under Grocery List."

    #expect(OnDeviceSuggester.excerpt(of: text, edge: 100) == text)
}
