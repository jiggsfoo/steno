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

/// Opting out of template rendering only stops macOS RECOLOURING the image --
/// it does not colour it. `.recording` was shipping as flat black with
/// `isTemplate = false`, which on the default dark menu bar is an invisible
/// icon for the one state that must never be missed. This asserts the pixels,
/// not the intent.
@Test func recordingActuallyCarriesRedAndNoOtherStateDoes() {
    #expect(maxRedness(MenuBarIcon.image(for: .recording)) > 0.3,
            "the recording icon renders with no colour at all")

    for state in MenuBarIcon.State.allCases where state != .recording {
        let image = MenuBarIcon.image(for: state)
        // Without this the assertion below fails OPEN: if the image cannot be
        // rasterised, `opaquePixels` returns [] and `< 0.05` passes on an
        // image that was never examined.
        #expect(!opaquePixels(of: image).isEmpty,
                Comment(rawValue: "\(state) produced no readable pixels"))
        #expect(maxRedness(image) < 0.05,
                Comment(rawValue: "\(state) is a template image and must stay colourless"))
    }
}

/// Guards the actual failure mode rather than its cause: a non-template image
/// dark enough to vanish against a dark menu bar.
///
/// The DARKEST ink, not the average: a half-red, half-black icon would clear a
/// mean threshold while still being half invisible.
@Test func theNonTemplateRecordingIconIsNotBlack() {
    let image = MenuBarIcon.image(for: .recording)
    #expect(!opaquePixels(of: image).isEmpty, "recording produced no readable pixels")
    #expect(minInkLuminance(image) > 0.2,
            "recording has ink dark enough to disappear on a dark menu bar")
}

// MARK: - Pixel helpers

private func opaquePixels(of image: NSImage) -> [NSColor] {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return [] }
    var colors: [NSColor] = []
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                  color.alphaComponent > 0.35 else { continue }
            colors.append(color)
        }
    }
    return colors
}

/// Peak separation between the red channel and the strongest other channel.
/// Zero for any greyscale image, high for a red one.
private func maxRedness(_ image: NSImage) -> Double {
    opaquePixels(of: image)
        .map { $0.redComponent - max($0.greenComponent, $0.blueComponent) }
        .max() ?? 0
}

/// Relative luminance of the DARKEST drawn pixel. A mean would let a bright
/// area average away an invisible one.
private func minInkLuminance(_ image: NSImage) -> Double {
    opaquePixels(of: image)
        .map { 0.2126 * $0.redComponent + 0.7152 * $0.greenComponent + 0.0722 * $0.blueComponent }
        .min() ?? 0
}
