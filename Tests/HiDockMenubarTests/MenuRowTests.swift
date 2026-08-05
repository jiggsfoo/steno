import Testing
@testable import HiDockMenubar

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
    #expect(!MenuRow.composedAccessibilityLabel(title: "Quit HiDock", value: nil, detail: nil)
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
