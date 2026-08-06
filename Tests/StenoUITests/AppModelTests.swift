// Tests/StenoUITests/AppModelTests.swift
import Foundation
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

/// `openIndex()` deletes index.sqlite on a failed open but historically left
/// `-wal` and `-shm` behind. WAL is enabled, so a stale write-ahead log can be
/// recovered back into the fresh file, reviving the corruption the delete was
/// meant to clear.
@Test func indexResetRemovesWalAndShmAlongsideTheDatabase() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let db = dir.appendingPathComponent("index.sqlite")

    for suffix in ["", "-wal", "-shm"] {
        try Data("stale".utf8).write(to: URL(fileURLWithPath: db.path + suffix))
    }

    let urls = AppModel.indexSidecarURLs(for: db)
    for url in urls { try? FileManager.default.removeItem(at: url) }

    #expect(urls.count == 3)
    for suffix in ["", "-wal", "-shm"] {
        #expect(!FileManager.default.fileExists(atPath: db.path + suffix),
                "index.sqlite\(suffix) survived the reset")
    }
}

/// `shouldClearTranscriptionState` is the pure predicate behind
/// `transcriptionGeneration` -- the same "cancel A, start B, A's stale unwind
/// must not clobber B" guard `syncGeneration` already uses for `syncTask`,
/// applied to `transcriptionTask`. A task's `defer` captures the generation
/// current when IT started; by the time it runs, a newer task may have
/// already bumped the counter and been assigned to `transcriptionTask`.
@Test func transcriptionCleanupRunsWhenTheGenerationStillMatches() {
    #expect(AppModel.shouldClearTranscriptionState(
        capturedGeneration: 1, currentGeneration: 1) == true)
}

/// The exact race this exists for: a cancelled sweep's `defer` finally runs
/// AFTER `startTranscription` has already bumped the generation and started a
/// newer task. Clearing here would discard the reference to that newer task
/// and defeat `startTranscription`'s own re-entrancy guard, letting a later
/// trigger spawn an unbounded further sweep on top of it.
@Test func transcriptionCleanupIsSkippedWhenANewerSweepHasAlreadyStarted() {
    #expect(AppModel.shouldClearTranscriptionState(
        capturedGeneration: 1, currentGeneration: 2) == false)
}

/// `mayStartTranscribing` is the pure predicate behind `sidecarsInFlight` --
/// the guard that keeps the automatic sweep and a manual `retranscribe` off
/// the SAME recording at the same time. `startTranscription`'s sweep and
/// `retranscribe` each build their own `TranscriptionQueue`, so actor
/// isolation protects state within one instance, not across two -- nothing
/// else stops both from writing the same sidecar/transcript concurrently.
/// Task 13 made those writes UUID-staged and atomic, so they can no longer
/// tear a file, but two writers can still race last-writer-wins on the same
/// sidecar, silently reverting a deliberate re-transcription. See
/// `sidecarsInFlight`'s own doc comment for the full reasoning.
@Test func aRecordingAlreadyInFlightMayNotBeStartedAgain() {
    #expect(AppModel.mayStartTranscribing(signature: "sig-1", inFlight: ["sig-1"]) == false)
}

@Test func aDifferentRecordingInFlightDoesNotBlockThisOne() {
    #expect(AppModel.mayStartTranscribing(signature: "sig-1", inFlight: ["sig-2"]) == true)
}

@Test func nothingInFlightBlocksNothing() {
    #expect(AppModel.mayStartTranscribing(signature: "sig-1", inFlight: []) == true)
}
