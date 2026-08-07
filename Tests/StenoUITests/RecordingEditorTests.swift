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

/// The review's second Important: tapping one field must not discard the
/// other's unsaved edit. A field mid-edit holds the user's own intent, which
/// is newer than disk, so it is exempt from the resync a sibling's tap would
/// otherwise trigger — the same "newer wins" ruling Task 4's `AppModel`
/// stale-snapshot fix applied one layer down, applied here to two `@State`
/// vars instead of a file on disk.
@Test func aFieldMidEditIsNotClobberedByTheOtherFieldsResync() {
    #expect(RecordingEditor.resyncedValue(current: "typed", onDisk: "disk", isEditing: true) == "typed")
}

/// The counterpart: an idle field DOES pick up whatever is on disk, which is
/// the whole point of resyncing at all — see Task 4's stale-`@State` fix.
@Test func anIdleFieldResyncsFromDisk() {
    #expect(RecordingEditor.resyncedValue(current: "stale", onDisk: "fresh", isEditing: false) == "fresh")
}

/// No topic on disk resyncs to empty, matching `init`'s own `?? ""` and
/// `save()`'s `topic.isEmpty ? nil : topic` round trip.
@Test func anIdleFieldWithNoDiskValueResyncsToEmpty() {
    #expect(RecordingEditor.resyncedValue(current: "stale", onDisk: nil, isEditing: false) == "")
}
