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
