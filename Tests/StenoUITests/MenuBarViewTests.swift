import AppKit
import Foundation
import Testing
@testable import StenoUI

private let everyStatus: [DeviceStatus] = [
    .disconnected,
    .connected(battery: nil, freeMiB: 1, capacityMiB: 2),
    .syncing(done: 1, total: 2, percent: 50),
    .busy,
    .unavailable("boom"),
]

@Test func durationIsMinutesAndPaddedSeconds() {
    #expect(MenuBarView.durationLabel(4.464) == "0:04")
    #expect(MenuBarView.durationLabel(397.0) == "6:37")
    #expect(MenuBarView.durationLabel(3984.0) == "66:24")
}

@Test func durationHandlesMissingValue() {
    #expect(MenuBarView.durationLabel(nil) == "--:--")
}

@Test func dateHandlesMissingValue() {
    #expect(MenuBarView.dateLabel(nil) == "Unknown")
}

/// The formatter must be fixed-format, not locale-dependent — the same reason
/// Library's formatters pin en_US_POSIX.
@Test func dateFormatIsStableRegardlessOfLocale() {
    var components = DateComponents()
    components.year = 2026; components.month = 8; components.day = 5
    components.hour = 13; components.minute = 0
    let date = Calendar(identifier: .gregorian).date(from: components)!
    let label = MenuBarView.dateLabel(date)
    #expect(label.contains("13:00"))
    #expect(label.contains("Aug"))
}

@Test func everyStatusHasANonEmptyTitle() {
    for status in everyStatus {
        #expect(!MenuBarView.statusTitle(for: status).isEmpty)
    }
}

/// The spec's menu diagram shows the status row as "● P1 connected", and its
/// accessibility section justifies the never-colour-alone rule by pointing at
/// that symbol. A status row rendered as bare text has neither.
@Test func everyStatusCarriesItsOwnSymbol() {
    let symbols = everyStatus.map { MenuBarView.statusAccent(for: $0).symbol }
    #expect(symbols.allSatisfy { !$0.isEmpty })
    #expect(Set(symbols).count == symbols.count)
}

/// Colour is the reinforcement, never the signal — so every tinted status must
/// already be distinguishable with the tint discarded.
@Test func statusSymbolsStillDifferWithTheColourRemoved() {
    let tinted = everyStatus.map { MenuBarView.statusAccent(for: $0) }.filter { $0.tint != nil }
    #expect(!tinted.isEmpty)
    #expect(Set(tinted.map(\.symbol)).count == tinted.count)
}

@Test func everyStatusSymbolExistsOnThisSystem() {
    let accents = everyStatus.map { MenuBarView.statusAccent(for: $0) } + [MenuBarView.recordingAccent]
    for accent in accents {
        #expect(NSImage(systemSymbolName: accent.symbol, accessibilityDescription: nil) != nil,
                Comment(rawValue: "SF Symbol '\(accent.symbol)' does not exist"))
    }
}

/// GET_RECORDING_FILE's body layout beyond "empty means idle" is unverified,
/// so anything outside printable ASCII (a control byte here) must fall back
/// to a bare "Recording…" rather than render mangled text.
@Test func recordingLabelRejectsControlBytes() {
    let withControlByte = "take1\u{0007}.hda"
    #expect(MenuBarView.recordingLabel(for: withControlByte) == "Recording…")
}

/// Both windows this menu opens are `Window(_:id:)` scenes in `StenoApp`, and
/// SwiftUI tells them apart by id alone. Sharing one id would silently point
/// "Free Up Space on P1…" at the Settings window -- there is no diagnostic for
/// it, at compile time or at run time.
///
/// This is the only part of Bug 1's fix a test can reach: whether the window
/// visibly stops re-presenting needs a human, and is recorded as such.
@MainActor
@Test func theTwoWindowScenesHaveDistinctIDs() {
    #expect(!MenuBarView.settingsWindowID.isEmpty)
    #expect(!MenuBarView.reclaimWindowID.isEmpty)
    #expect(MenuBarView.settingsWindowID != MenuBarView.reclaimWindowID)
}

@Test func transcriptionLabelReadsAsProgressWhileWorking() {
    #expect(MenuBarView.transcriptionLabel(for: QueueProgress(done: 2, total: 11))
            == "Transcribing 3 of 11")
}

@Test func transcriptionLabelIsAbsentWhenIdleOrFinished() {
    #expect(MenuBarView.transcriptionLabel(for: nil) == nil)
    #expect(MenuBarView.transcriptionLabel(for: QueueProgress(done: 11, total: 11)) == nil)
}

@Test func transcriptionLabelHandlesAnEmptyQueueWithoutDividingByZero() {
    #expect(MenuBarView.transcriptionLabel(for: QueueProgress(done: 0, total: 0)) == nil)
}

/// IMPORTANT: the spec says "Empty means the cloud backend is not offered at
/// all." Before this fix, the context menu built from `TranscriberRegistry
/// .all()` UNCONDITIONALLY -- Deepgram was always in the list, even with no
/// Keychain key configured, so the first click any user made was guaranteed
/// to fail. `availableTranscribers` is the filter that closes that gap.
@Test func availableTranscribersFiltersToOnlyThoseMarkedAvailable() {
    let all = TranscriberRegistry.all()
    let onlyOnDevice = MenuBarView.availableTranscribers(from: all, availableIDs: ["speechanalyzer"])
    #expect(onlyOnDevice.map(\.id) == ["speechanalyzer"])
}

/// The empty-Keychain case the spec calls out by name: no key configured
/// means Deepgram (and everything else not yet confirmed available) is not
/// offered at all, not offered-but-guaranteed-to-fail.
@Test func availableTranscribersIsEmptyWhenNothingIsAvailable() {
    let all = TranscriberRegistry.all()
    #expect(MenuBarView.availableTranscribers(from: all, availableIDs: []).isEmpty)
}

@Test func availableTranscribersKeepsEveryoneWhenAllAreAvailable() {
    let all = TranscriberRegistry.all()
    let ids = Set(all.map(\.id))
    #expect(MenuBarView.availableTranscribers(from: all, availableIDs: ids).count == all.count)
}
