import Foundation
import Testing
@testable import StenoUI

private struct StubSuggester: FilingSuggester {
    var filing: Filing?
    func suggest(from text: String, directive: Directive?) async -> Filing? { filing }
}

/// Records what the resolver told the model boundary. An actor because
/// `FilingSuggester` is `Sendable` and `suggest` is non-mutating, matching
/// `FakeDevice`'s approach to the same problem.
private actor SpyRecorder {
    private(set) var directive: Directive?
    private(set) var text: String?

    func record(text: String, directive: Directive?) {
        self.text = text
        self.directive = directive
    }
}

private struct SpySuggester: FilingSuggester {
    let recorder: SpyRecorder
    var filing: Filing?

    func suggest(from text: String, directive: Directive?) async -> Filing? {
        await recorder.record(text: text, directive: directive)
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
    // Proves `resolve` ran the directive path to completion and the topic was
    // rejected there, rather than returning early at the permission gate.
    #expect(filing.title == "T")
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

/// Silence transcribes to whitespace as readily as to nothing at all.
@Test func aWhitespaceOnlyTranscriptStillProducesAUsableTitle() async {
    let filing = await TopicResolver(suggester: nil).resolve(transcript("   "))

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

/// `OnDeviceSuggester` re-applies the gate on its own side and builds its
/// prompt from the directive, so it has to be handed the real one. A resolver
/// that always passed `nil` would still pass every test above, because the gate
/// the suggester enforces itself would mask the lie.
@Test func theSuggesterIsGivenTheDirectiveItself() async {
    let spoken = SpyRecorder()
    _ = await TopicResolver(suggester: SpySuggester(recorder: spoken, filing: nil))
        .resolve(transcript("File this under Grocery List."))
    #expect(await spoken.directive?.capturedTail == "Grocery List")

    let silent = SpyRecorder()
    _ = await TopicResolver(suggester: SpySuggester(recorder: silent, filing: nil))
        .resolve(transcript("I should buy groceries later."))
    #expect(await silent.directive == nil)
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

/// A directive spoken 30 minutes into a 40-minute call falls outside the
/// head+tail excerpt. The model would then be asked to name a folder while
/// being the only party that never saw the instruction — and `resolve` prefers
/// the model's topic over the regex capture, so its invention would win.
@Test func aMidTranscriptDirectiveStillReachesTheModel() {
    let filler = String(repeating: "small talk. ", count: 100)
    let text = filler + "File this under Q3 Budget. " + filler
    let directive = DirectiveParser.parse(text)

    let excerpt = OnDeviceSuggester.excerpt(of: text, edge: 100)
    let prompt = OnDeviceSuggester.prompt(for: text, directive: directive, edge: 100)

    // The excerpt alone loses the instruction — that is the whole problem.
    #expect(!excerpt.contains("Q3 Budget"))
    // The prompt recovers it, without giving up on being an excerpt.
    #expect(prompt.contains("File this under Q3 Budget"))
    #expect(prompt.count < text.count)
}

/// The matched phrase runs to the end of its line, and a transcript is joined
/// into a single line — so appending it raw would paste the rest of the
/// recording back in and undo the excerpt.
@Test func theAppendedInstructionDoesNotDragInTheRestOfTheRecording() {
    let text = "File this under Q3 Budget. " + String(repeating: "and then. ", count: 500)
    let directive = DirectiveParser.parse(text)

    #expect(directive?.matchedPhrase.count ?? 0 > 1_000)   // the raw phrase is huge
    #expect(OnDeviceSuggester.spokenInstruction(directive!) == "File this under Q3 Budget")
}

/// No sentence end anywhere, so the sentence trim cannot bound it.
@Test func anUnpunctuatedInstructionIsStillCapped() {
    let directive = Directive(matchedPhrase: String(repeating: "a", count: 900),
                              capturedTail: "x")

    #expect(OnDeviceSuggester.spokenInstruction(directive, limit: 200).count == 200)
}

@Test func withNoDirectiveThePromptIsJustTheExcerpt() {
    let text = "I should buy groceries later."

    #expect(OnDeviceSuggester.prompt(for: text, directive: nil, edge: 100) == text)
}
