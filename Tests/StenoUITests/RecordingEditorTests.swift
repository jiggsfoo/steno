import Foundation
import Testing
@testable import StenoUI

private func withTopic(_ topic: String?, _ signature: String) -> LoadedRecording {
    LoadedRecording(
        sidecar: Sidecar(signature: signature, deviceFilename: "a.hda",
                         relativePath: "2026-08-05/\(signature).mp3", lengthBytes: 10,
                         durationSeconds: 60, recordedAt: nil,
                         syncedAt: Date(timeIntervalSince1970: 1), deviceSerial: "S",
                         deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila",
                         topic: topic),
        transcript: nil)
}

@Test func topicChoicesAreTheOnesAlreadyInUse() {
    let choices = RecordingEditor.topicChoices(from: [
        withTopic("Receipts", "a"), withTopic("Admin", "b"), withTopic("Receipts", "c"),
    ])

    #expect(choices == ["Admin", "Receipts"])
}

@Test func unfiledRecordingsContributeNoTopicChoice() {
    #expect(RecordingEditor.topicChoices(from: [withTopic(nil, "a")]).isEmpty)
}

/// A refused folder name has to say WHY, or the field just appears not to work.
@Test func aRefusedTopicIsExplained() throws {
    let message = try #require(RecordingEditor.message(for: .rejectedTopic("../etc")))

    #expect(message.contains("../etc"))
}

/// Busy is not an error — something else is legitimately writing this
/// recording — so it reads as "try again", not as a failure.
@Test func busySaysWhatToDoAboutIt() throws {
    let message = try #require(RecordingEditor.message(for: .busy))

    #expect(!message.isEmpty)
}

@Test func aSuccessfulSaveHasNothingToSay() {
    let sidecar = withTopic("Admin", "a").sidecar

    #expect(RecordingEditor.message(for: .updated(sidecar)) == nil)
}

/// This is the decision behind the Critical fix: only `.updated` actually
/// changed the sidecar on disk, so it's the only outcome worth telling
/// `LibraryWindow` to reload over — the other three leave the field open
/// with its message showing instead.
@Test func aSuccessfulSaveNotifiesTheCaller() {
    let sidecar = withTopic("Admin", "a").sidecar
    #expect(RecordingEditor.shouldNotifySaved(for: .updated(sidecar)))
}

@Test func anUnsuccessfulSaveDoesNotNotifyTheCaller() {
    #expect(!RecordingEditor.shouldNotifySaved(for: .busy))
    #expect(!RecordingEditor.shouldNotifySaved(for: .rejectedTopic("../etc")))
    #expect(!RecordingEditor.shouldNotifySaved(for: .failed("disk full")))
}

/// Busy has to look different from a refusal or a failure, or the copy
/// ("try again in a moment") reads as a lie next to error-red text.
@Test func busyIsNotStyledAsAFailure() {
    let sidecar = withTopic("Admin", "a").sidecar
    #expect(RecordingEditor.isBusyMessage(.busy))
    #expect(!RecordingEditor.isBusyMessage(.rejectedTopic("../etc")))
    #expect(!RecordingEditor.isBusyMessage(.failed("disk full")))
    #expect(!RecordingEditor.isBusyMessage(.updated(sidecar)))
}

/// The combo box offers what exists plus an explicit way out. "None" must be
/// distinguishable from a topic literally named that — `TopicName` reserves
/// the sidebar's Unfiled sentinel, so the menu's own escape hatch carries no
/// topic string at all.
@Test func theTopicMenuOffersExistingTopicsAndAWayToUnfile() {
    let choices = RecordingEditor.topicChoices(from: [
        withTopic("Receipts", "a"), withTopic("Admin", "b"),
    ])

    #expect(choices == ["Admin", "Receipts"])
    #expect(RecordingEditor.unfileLabel == "None — unfile this")
}

/// The whole-branch review's Critical, as a truth table.
///
/// The editor resynced on ENTRY and then committed from the entry-time
/// snapshot. Between tapping the title and pressing Return, the transcription
/// sweep can file the recording — writing `topic` into the sidecar and
/// creating the note in that topic's folder — and `LibraryWindow.reload()`
/// refreshes `recording` without re-running `init`, so the `topic` `@State`
/// stayed at its tap-time value. Return then sent nil, and `updateRecording`
/// removed the note instead of moving it: the AI-assigned topic reverted to
/// Unfiled and the markdown note was orphaned.
///
/// Taking the sibling from disk AT COMMIT TIME is what closes it — the stale
/// `@State` is not an input to this function at all, so no gap between tap and
/// Return can reopen it.
@Test func committingTheTitleWritesTheTopicTheSidecarHasNow() {
    let edit = RecordingEditor.titleCommit(typed: "Kickoff call", topicOnDisk: "Client Calls")

    #expect(edit == RecordingEditor.Edit(title: "Kickoff call", topic: "Client Calls"))
}

/// The review's second Important, closed by the same fix pointed the other
/// way: an abandoned draft in the title field is not evidence of anything.
/// Type "Weekl", tap over to the topic without pressing Return, commit the
/// topic — the title on disk stays "Weekly Sync", which is also what makes Esc
/// on the still-open title field restore something true.
@Test func committingTheTopicWritesTheTitleTheSidecarHasNow() {
    let edit = RecordingEditor.topicCommit(typed: "Projects", titleOnDisk: "Weekly Sync")

    #expect(edit == RecordingEditor.Edit(title: "Weekly Sync", topic: "Projects"))
}

/// An unfiled recording has no topic at all rather than one named "" —
/// matching `init`'s `?? ""` on the way in and what `writeEdit` does with an
/// empty string on the way out. This is the menu's "None — unfile this" path.
@Test func anEmptyTopicCommitsAsUnfiled() {
    #expect(RecordingEditor.topicCommit(typed: "", titleOnDisk: "Weekly Sync").topic == nil)
}

/// A recording synced but not yet titled has `title: nil` on its sidecar.
/// Committing a topic must not invent a title for it, and must not send nil to
/// a parameter that does not take one.
@Test func aRecordingWithNoTitleYetCommitsAnEmptyOne() {
    #expect(RecordingEditor.topicCommit(typed: "Projects", titleOnDisk: nil).title == "")
}

/// The other direction of the same restraint: retitling an unfiled recording
/// must not file it anywhere.
@Test func committingTheTitleOfAnUnfiledRecordingLeavesItUnfiled() {
    #expect(RecordingEditor.titleCommit(typed: "Kickoff", topicOnDisk: nil).topic == nil)
}
