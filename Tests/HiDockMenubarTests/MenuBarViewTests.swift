import Foundation
import Testing
@testable import HiDockMenubar

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
    let statuses: [DeviceStatus] = [
        .disconnected,
        .connected(battery: nil, freeMiB: 1, capacityMiB: 2),
        .syncing(done: 1, total: 2, percent: 50),
        .busy,
        .unavailable("boom"),
    ]
    for status in statuses {
        #expect(!MenuBarView.statusTitle(for: status).isEmpty)
    }
}

/// GET_RECORDING_FILE's body layout beyond "empty means idle" is unverified,
/// so anything outside printable ASCII (a control byte here) must fall back
/// to a bare "Recording…" rather than render mangled text.
@Test func recordingLabelRejectsControlBytes() {
    let withControlByte = "take1\u{0007}.hda"
    #expect(MenuBarView.recordingLabel(for: withControlByte) == "Recording…")
}
