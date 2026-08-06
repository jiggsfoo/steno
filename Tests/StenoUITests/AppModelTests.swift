// Tests/StenoUITests/AppModelTests.swift
import Testing
@testable import StenoUI

/// `AppModel` itself has no test seam -- it drives real USB I/O and MainActor
/// state -- so only the pure decision extracted from the poll loop is covered
/// here. See `poll-feature-report.md` for what could and could not be
/// verified beyond this.
///
/// `shouldSyncAfterPoll` is a change detector against the LAST OBSERVED
/// device count, not a running total: comparing against a permanent count
/// (like every signature ever synced) breaks after a reclaim, since that
/// count never goes back down while the device count does.
@Test func pollDoesNotSyncOnTheFirstObservationEvenIfTheDeviceHasFiles() {
    #expect(AppModel.shouldSyncAfterPoll(
        recording: nil, deviceFileCount: 5, lastSeenCount: nil) == false)
}

@Test func pollSyncsWhenIdleAndTheDeviceCountIncreasedSinceLastSeen() {
    #expect(AppModel.shouldSyncAfterPoll(
        recording: nil, deviceFileCount: 5, lastSeenCount: 3) == true)
}

@Test func pollDoesNotSyncWhenIdleAndTheCountIsUnchanged() {
    #expect(AppModel.shouldSyncAfterPoll(
        recording: nil, deviceFileCount: 3, lastSeenCount: 3) == false)
}

/// The post-reclaim case: the device count dropped (files were deleted from
/// the P1) while the last-seen baseline is still the pre-reclaim high-water
/// mark. Must not sync -- there is nothing new, and syncing here would just
/// re-download nothing while burning a device open/close for no reason.
@Test func pollDoesNotSyncWhenTheDeviceCountDecreasedAfterAReclaim() {
    #expect(AppModel.shouldSyncAfterPoll(
        recording: nil, deviceFileCount: 3, lastSeenCount: 20) == false)
}

@Test func pollDoesNotSyncWhileARecordingIsInProgressEvenIfTheCountIncreased() {
    #expect(AppModel.shouldSyncAfterPoll(
        recording: "REC001.hda", deviceFileCount: 5, lastSeenCount: 3) == false)
}
