import AppKit
import Testing
@testable import HiDockMenubar

@Test func eachStatusMapsToItsOwnIconState() {
    #expect(MenuBarIcon.state(for: .disconnected, recording: nil) == .disconnected)
    #expect(MenuBarIcon.state(for: .connected(battery: nil, freeMiB: 1, capacityMiB: 2),
                              recording: nil) == .connected)
    #expect(MenuBarIcon.state(for: .syncing(done: 1, total: 2, percent: 50),
                              recording: nil) == .syncing)
    #expect(MenuBarIcon.state(for: .busy, recording: nil) == .attention)
    #expect(MenuBarIcon.state(for: .unavailable("x"), recording: nil) == .attention)
}

/// Recording is the most time-critical thing the icon can tell you, and it can
/// coincide with any other state. It must win.
@Test func recordingOverridesEveryOtherStatus() {
    let statuses: [DeviceStatus] = [
        .disconnected,
        .connected(battery: nil, freeMiB: 1, capacityMiB: 2),
        .syncing(done: 1, total: 2, percent: 50),
        .busy,
        .unavailable("x"),
    ]
    for status in statuses {
        #expect(MenuBarIcon.state(for: status, recording: "a.hda") == .recording)
    }
}

/// Every state must be distinguishable by SHAPE, not colour — that survives a
/// tinted menu bar and colour-blind vision. Distinct symbols (or a composed
/// image) per state is what guarantees it.
@Test func everyStateHasADistinctAppearance() {
    let all = MenuBarIcon.State.allCases
    let names = all.map { MenuBarIcon.symbolName(for: $0) ?? "composed-\($0)" }
    #expect(Set(names).count == all.count)
}

@Test func symbolNamesActuallyExistOnThisSystem() {
    for state in MenuBarIcon.State.allCases {
        guard let name = MenuBarIcon.symbolName(for: state) else { continue }
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "SF Symbol '\(name)' does not exist")
    }
}

/// The syncing state has no SF Symbol — `waveform.badge.arrow.down` does not
/// exist — so it is composed. This pins that fact.
@Test func syncingIsComposedBecauseNoSymbolExists() {
    #expect(MenuBarIcon.symbolName(for: .syncing) == nil)
    #expect(NSImage(systemSymbolName: "waveform.badge.arrow.down",
                    accessibilityDescription: nil) == nil)
}

@Test func everyStateProducesADistinctNonEmptyAccessibilityLabel() {
    let labels = MenuBarIcon.State.allCases.map { MenuBarIcon.accessibilityLabel(for: $0) }
    #expect(labels.allSatisfy { !$0.isEmpty })
    #expect(Set(labels).count == labels.count)
    #expect(labels.allSatisfy { $0.hasPrefix("HiDock") })
}

@Test func everyStateRendersAnImageWithTheAccessibilityLabelAttached() {
    for state in MenuBarIcon.State.allCases {
        let image = MenuBarIcon.image(for: state)
        #expect(image.size.width > 0 && image.size.height > 0)
        #expect(image.accessibilityDescription == MenuBarIcon.accessibilityLabel(for: state))
    }
}

/// Template images invert for light/dark and for a tinted menu bar. Recording
/// is deliberately NOT a template: red is meaningful there and must survive.
@Test func allStatesAreTemplateExceptRecording() {
    for state in MenuBarIcon.State.allCases where state != .recording {
        #expect(MenuBarIcon.image(for: state).isTemplate, "\(state) should be a template image")
    }
    #expect(MenuBarIcon.image(for: .recording).isTemplate == false)
}
