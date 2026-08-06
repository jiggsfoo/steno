import Foundation
import Testing
@testable import StenoUI

private func grouped(_ topic: String?, _ signature: String) -> LoadedRecording {
    LoadedRecording(
        sidecar: Sidecar(signature: signature, deviceFilename: "\(signature).hda",
                         relativePath: "2026-08-05/\(signature).mp3", lengthBytes: 10,
                         durationSeconds: 60,
                         recordedAt: Date(timeIntervalSince1970: 1_754_400_000),
                         syncedAt: Date(timeIntervalSince1970: 1),
                         deviceSerial: "S", deviceModel: "hidock-p1",
                         timeZoneIdentifier: "Asia/Manila", title: "T", topic: topic),
        transcript: nil)
}

@Test func recordingsAreGroupedByTopic() {
    let groups = LibrarySidebar.grouped([
        grouped("Client Calls", "a"), grouped("Receipts", "b"), grouped("Client Calls", "c"),
    ])

    #expect(groups.count == 2)
    #expect(groups.first(where: { $0.topic == "Client Calls" })?.recordings.count == 2)
}

/// Filing has never run on the real library, so every recording is unfiled
/// today. That has to be a named group, not a blank heading.
@Test func unfiledRecordingsGetTheirOwnNamedGroup() {
    let groups = LibrarySidebar.grouped([grouped(nil, "a"), grouped(nil, "b")])

    #expect(groups.count == 1)
    #expect(groups.first?.topic == "Unfiled")
    #expect(groups.first?.recordings.count == 2)
}

/// Unfiled sorts last, so a library that is entirely unfiled today does not
/// bury its real topics under a growing pile tomorrow.
@Test func unfiledSortsAfterNamedTopics() {
    let groups = LibrarySidebar.grouped([grouped(nil, "a"), grouped("Receipts", "b")])

    #expect(groups.map(\.topic) == ["Receipts", "Unfiled"])
}

@Test func namedTopicsSortAlphabetically() {
    let groups = LibrarySidebar.grouped([
        grouped("Receipts", "a"), grouped("Admin", "b"), grouped("Client Calls", "c"),
    ])

    #expect(groups.map(\.topic) == ["Admin", "Client Calls", "Receipts"])
}

@Test func anEmptyLibraryProducesNoGroups() {
    #expect(LibrarySidebar.grouped([]).isEmpty)
}
