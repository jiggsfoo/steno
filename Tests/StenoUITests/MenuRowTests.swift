import AppKit
import Testing
@testable import StenoUI

@Test func labelIsJustTheTitleWhenThereIsNothingElse() {
    #expect(MenuRow.composedAccessibilityLabel(title: "Sync Now", value: nil, detail: nil)
            == "Sync Now")
}

/// VoiceOver would otherwise read "Today 13:00 66:24" as visual shorthand.
/// Joining with a comma makes it a sentence.
@Test func valueIsJoinedToTheTitleForVoiceOver() {
    #expect(MenuRow.composedAccessibilityLabel(title: "Today 13:00", value: "66:24", detail: nil)
            == "Today 13:00, 66:24")
}

@Test func detailIsAppendedAfterTheValue() {
    #expect(MenuRow.composedAccessibilityLabel(title: "Today 13:00", value: "66:24",
                                               detail: "48 MB")
            == "Today 13:00, 66:24, 48 MB")
}

@Test func emptyAndWhitespaceOnlyPartsAreSkipped() {
    #expect(MenuRow.composedAccessibilityLabel(title: "Sync Now", value: "", detail: "   ")
            == "Sync Now")
}

@Test func aRowIsNeverAnnouncedAsEmpty() {
    #expect(!MenuRow.composedAccessibilityLabel(title: "Quit Steno", value: nil, detail: nil)
             .isEmpty)
}

/// A dimmed row is the only signal a sighted user gets that an action exists
/// but is not available right now. VoiceOver needs the same signal, or
/// "Sync Now" announces identically whether or not it will do anything.
@Test func anUnavailableActionSaysSo() {
    #expect(MenuRow.composedAccessibilityValue(hasAction: true, isEnabled: false)
            == "Unavailable")
}

@Test func anAvailableActionHasNoExtraValue() {
    #expect(MenuRow.composedAccessibilityValue(hasAction: true, isEnabled: true).isEmpty)
}

/// A row with no action is a status line, not a broken button. It must not
/// announce as unavailable just because it isn't tappable.
@Test func aPlainStatusRowIsNotAnnouncedAsUnavailable() {
    #expect(MenuRow.composedAccessibilityValue(hasAction: false, isEnabled: false).isEmpty)
    #expect(MenuRow.composedAccessibilityValue(hasAction: false, isEnabled: true).isEmpty)
}

// MARK: - Severity

/// VoiceOver gets neither the orange nor the triangle, so the severity has to
/// arrive as a word — and first, before a three-line message.
@Test func anErrorAnnouncesThatItIsAnError() {
    #expect(MenuRow.composedAccessibilityLabel(
        title: "", value: nil, detail: "3 recordings failed to sync",
        severity: MenuRow.Accent.error.spokenSeverity) == "Error, 3 recordings failed to sync")
}

/// The defect this replaces: a partial sync failure and a successful reclaim
/// were both `MenuRow("", detail:)`, so they rendered as the same grey caption
/// and announced as the same bare sentence.
@Test func aFailureAndASuccessNoticeDoNotAnnounceAlike() {
    let failure = MenuRow.composedAccessibilityLabel(
        title: "", value: nil, detail: "3 recordings failed to sync",
        severity: MenuRow.Accent.error.spokenSeverity)
    let success = MenuRow.composedAccessibilityLabel(
        title: "", value: nil, detail: "Freed 3 recording(s) from the P1.",
        severity: MenuRow.Accent.notice.spokenSeverity)
    #expect(failure != success)
    #expect(failure.hasPrefix("Error"))
    #expect(success.hasPrefix("Notice"))
}

/// Severity must survive with the colour switched off: distinct shapes, and a
/// spoken word each. HIG forbids encoding state in colour alone.
@Test func severityIsCarriedByShapeAndSpeechNotOnlyColour() {
    #expect(MenuRow.Accent.error.symbol != MenuRow.Accent.notice.symbol)
    #expect(MenuRow.Accent.error.spokenSeverity != MenuRow.Accent.notice.spokenSeverity)
    #expect(MenuRow.Accent.notice.tint == nil)
}

@Test func aRowWithNoAccentAnnouncesExactlyAsBefore() {
    #expect(MenuRow.composedAccessibilityLabel(title: "Sync Now", value: nil, detail: nil,
                                               severity: nil) == "Sync Now")
}

@Test func everyAccentSymbolExistsOnThisSystem() {
    for accent in [MenuRow.Accent.error, .notice] {
        #expect(NSImage(systemSymbolName: accent.symbol, accessibilityDescription: nil) != nil,
                Comment(rawValue: "SF Symbol '\(accent.symbol)' does not exist"))
    }
}
