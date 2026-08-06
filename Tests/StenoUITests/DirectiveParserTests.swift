import Foundation
import Testing
@testable import StenoUI

@Test(arguments: [
    "File this under Grocery List.",
    "file this under grocery list",
    "Okay, so, file this under Grocery List. Anyway,",
    "File this in Grocery List.",
    "Save this to Grocery List.",
    "Save this in Grocery List.",
    "Save this under Grocery List!",
])
func recognisedPhrasingsYieldADirective(_ text: String) {
    #expect(DirectiveParser.parse(text) != nil, "no directive found in: \(text)")
}

/// The last four are VERBATIM from Angelo's real recordings, captured during
/// the Task 4 quality gate. Scanning 3 hours of real speech produced 12
/// directive-shaped phrases and zero genuine directives — and the plan's
/// original `put (this|that|it) (under|into)` pattern matched two of them,
/// deep inside client calls. Filing a client call under an invented topic is
/// the exact failure the prefilter exists to prevent, so `put` and `stick`
/// were dropped entirely. Do not re-add them to make a phrasing work.
@Test(arguments: [
    "",
    "I need to buy groceries later.",
    "The grocery list is on the fridge.",
    "We filed the paperwork under the wrong client.",
    "Put this in the car when you get home.",
    "take that credit card string, put it into the payment method",
    "I reconstitute it and I put it into a sprayer",
    "we could have it testable by next week and then put it live August 14th",
    "the doctor just sent me a PDF, so I'm going to save this one",
])
func ordinarySpeechYieldsNoDirective(_ text: String) {
    #expect(DirectiveParser.parse(text) == nil, "false positive on: \(text)")
}

@Test func theTailIsCapturedForUseWhenNoModelIsAvailable() {
    let directive = DirectiveParser.parse("File this under Grocery List. Then we talked.")

    #expect(directive?.capturedTail == "Grocery List")
}

/// Directives are spoken, so they arrive without punctuation as often as with.
@Test func anUnpunctuatedDirectiveStillCapturesToEndOfLine() {
    let directive = DirectiveParser.parse("file this under grocery list")

    #expect(directive?.capturedTail == "grocery list")
}

/// The first directive wins. A recording that changes its mind is ambiguous,
/// and filing it twice is worse than filing it once.
@Test func onlyTheFirstDirectiveIsReturned() {
    let directive = DirectiveParser.parse(
        "File this under Groceries. Actually, file this under Receipts.")

    #expect(directive?.capturedTail == "Groceries")
}

@Test func aDirectiveWithNothingAfterItIsNotADirective() {
    #expect(DirectiveParser.parse("File this under.") == nil)
    #expect(DirectiveParser.parse("File this under   ") == nil)
}
