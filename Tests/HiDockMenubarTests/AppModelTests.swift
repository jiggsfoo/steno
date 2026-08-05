// Tests/HiDockMenubarTests/AppModelTests.swift
import Testing
@testable import HiDockMenubar

/// `AppModel` itself has no test seam -- it drives real USB I/O and MainActor
/// state -- so only the pure decision extracted from the poll loop is covered
/// here. See `poll-feature-report.md` for what could and could not be
/// verified beyond this.
@Test func pollDoesNotSyncWhileARecordingIsInProgressEvenIfDeviceCountIsHigher() {
    #expect(AppModel.shouldSyncAfterPoll(
        recording: "REC001.hda", deviceFileCount: 5, localCount: 3) == false)
}

@Test func pollSyncsWhenIdleAndTheDeviceHasMoreFilesThanLocal() {
    #expect(AppModel.shouldSyncAfterPoll(
        recording: nil, deviceFileCount: 5, localCount: 3) == true)
}

@Test func pollDoesNotSyncWhenIdleAndCountsAreEqual() {
    #expect(AppModel.shouldSyncAfterPoll(
        recording: nil, deviceFileCount: 3, localCount: 3) == false)
}
