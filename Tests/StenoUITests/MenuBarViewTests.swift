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
