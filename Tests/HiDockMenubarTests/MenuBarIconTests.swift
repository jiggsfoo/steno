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
/// tinted menu bar and colour-blind vision.
///
/// Compares the rendered silhouettes, not the symbol names. A name-based check
/// passes trivially for `.syncing`, which has no name: substituting the case
/// name as a placeholder makes distinctness true by construction and tests
/// nothing but the `switch` restating itself. The alpha mask is exactly
/// "shape, with colour discarded", which is the property being claimed.
@Test func everyStateHasADistinctAppearance() {
    let all = MenuBarIcon.State.allCases
    let silhouettes = all.map { alphaSilhouette(of: MenuBarIcon.image(for: $0)) }
    for (state, silhouette) in zip(all, silhouettes) {
        #expect(silhouette.contains(true),
                Comment(rawValue: "\(state) drew nothing at all"))
    }
    #expect(Set(silhouettes).count == all.count)
}

/// The status bar gives an item a box about 22pt tall. Rendering each state at
/// its symbol's own natural canvas shipped 19x21, 19x20, 21x21, 21x22 and
/// 22x21 — bigger than the neighbouring extras, and changing by up to 2pt as
/// the device changed state, so the icon visibly grew when a sync began.
@Test func everyStateRendersAtOneMenuBarSize() {
    for state in MenuBarIcon.State.allCases {
        #expect(MenuBarIcon.image(for: state).size == MenuBarIcon.renderedSize,
                Comment(rawValue: "\(state) is \(MenuBarIcon.image(for: state).size)"))
    }
    #expect(MenuBarIcon.renderedSize.height <= 18)
}

/// The canvas being equal is not enough on its own: art that overflows it is
/// silently clipped, and art that shrinks inside it is the same wobble one
/// level down. Measures the drawn ink, which is what a person sees.
@Test func theInkIsMenuBarSizedAndHoldsStillAcrossStates() {
    let boxes = MenuBarIcon.State.allCases.map { state -> NSRect in
        guard let ink = inkBounds(of: MenuBarIcon.image(for: state)) else {
            Issue.record("\(state) produced no readable ink")
            return .zero
        }
        return ink
    }
    let heights = boxes.map(\.height)
    // Apple's own status art is roughly 16-18pt tall inside the 22pt box.
    #expect(heights.allSatisfy { $0 >= 13 && $0 <= 18 },
            Comment(rawValue: "ink heights \(heights)"))
    #expect((heights.max() ?? 0) - (heights.min() ?? 0) <= 1.5,
            Comment(rawValue: "ink heights \(heights)"))
    // Nothing reaches an edge, so nothing is clipped by the shared canvas.
    for (state, box) in zip(MenuBarIcon.State.allCases, boxes) {
        #expect(box.minX >= 0.5 && box.maxX <= MenuBarIcon.renderedSize.width - 0.5,
                Comment(rawValue: "\(state) ink \(box) touches the canvas edge"))
        #expect(box.minY >= 0 && box.maxY <= MenuBarIcon.renderedSize.height,
                Comment(rawValue: "\(state) ink \(box) touches the canvas edge"))
    }
}

@Test func symbolNamesActuallyExistOnThisSystem() {
    for state in MenuBarIcon.State.allCases {
        guard let name = MenuBarIcon.symbolName(for: state) else { continue }
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "SF Symbol '\(name)' does not exist")
    }
}

/// `.syncing` is the one state this code draws itself; every other state names
/// a symbol and lets AppKit draw it.
///
/// Asserts our mapping, not Apple's catalogue. An earlier version also
/// asserted that `waveform.badge.arrow.down` does not exist on the running
/// system — true today, and the reason `.syncing` is composed, but a fact
/// about macOS rather than about this code: a future release adding that
/// symbol would fail the suite with nothing here broken.
@Test func syncingIsTheOnlyComposedState() {
    #expect(MenuBarIcon.symbolName(for: .syncing) == nil)
    for state in MenuBarIcon.State.allCases where state != .syncing {
        #expect(MenuBarIcon.symbolName(for: state) != nil,
                Comment(rawValue: "\(state) unexpectedly has no symbol"))
    }
    // Composed or not, it still has to produce a real glyph.
    #expect(inkBounds(of: MenuBarIcon.image(for: .syncing))?.height ?? 0 > 0)
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

/// Rasterises at a chosen scale instead of reading `tiffRepresentation`.
///
/// `tiffRepresentation` of an image built by `NSImage(size:flipped:handler:)`
/// draws at the host's backing scale and then resamples down to 1x, and the
/// resample bleeds ink across a whole point in each direction — enough to make
/// a 15pt glyph measure 14 or 16. Drawing into a bitmap this code owns, at 2x,
/// measures what the glyph actually is to within half a point.
private func raster(_ image: NSImage, scale: CGFloat = 2) -> NSBitmapImageRep? {
    let width = Int((image.size.width * scale).rounded())
    let height = Int((image.size.height * scale).rounded())
    guard width > 0, height > 0,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                                     pixelsHigh: height, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                     bitsPerPixel: 0)
    else { return nil }
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    return rep
}

/// The drawn ink's bounding box, in points. Nil when nothing was drawn.
private func inkBounds(of image: NSImage) -> NSRect? {
    guard let rep = raster(image) else { return nil }
    var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05
            else { continue }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let sx = image.size.width / CGFloat(rep.pixelsWide)
    let sy = image.size.height / CGFloat(rep.pixelsHigh)
    return NSRect(x: CGFloat(minX) * sx, y: CGFloat(minY) * sy,
                  width: CGFloat(maxX - minX + 1) * sx,
                  height: CGFloat(maxY - minY + 1) * sy)
}

/// The image's coverage mask — shape with colour thrown away. Two states that
/// differ only in tint produce the same silhouette, which is the point: the
/// icon has to read on a tinted menu bar and to a colour-blind user.
private func alphaSilhouette(of image: NSImage) -> [Bool] {
    guard let rep = raster(image) else { return [] }
    var mask: [Bool] = []
    mask.reserveCapacity(rep.pixelsWide * rep.pixelsHigh)
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            mask.append((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.35)
        }
    }
    return mask
}

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
