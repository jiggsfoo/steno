import AppKit
import SwiftUI
import Testing
@testable import StenoUI

// MARK: - Measurement harness
//
// Nothing here asks a view what size it thinks it is. Every number is read back
// out of pixels the view actually drew, via `ImageRenderer` -- which renders
// headlessly in this environment, the same property `MenuBarIconLabelTests`
// relies on. `screencapture` returns black frames here, so this is the only way
// to measure the real thing rather than a replica of it.

/// A contiguous run of pixel rows containing ink, and that ink's extent.
struct InkBand {
    let top: Double
    let bottom: Double
    let minX: Double
    let maxX: Double

    var height: Double { bottom - top }
    var width: Double { maxX - minX }
    var midY: Double { (top + bottom) / 2 }
}

/// Rendered at scale 2, so every measurement below resolves to 0.5pt.
private let renderScale = 2.0

@MainActor
func inkBands(of view: some View, alphaFloor: CGFloat = 0.05) -> [InkBand] {
    let renderer = ImageRenderer(content: view)
    renderer.scale = CGFloat(renderScale)
    guard let tiff = renderer.nsImage?.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return [] }

    var bands: [InkBand] = []
    var open: (top: Int, bottom: Int, minX: Int, maxX: Int)?
    func close(_ o: (top: Int, bottom: Int, minX: Int, maxX: Int)) {
        bands.append(InkBand(top: Double(o.top) / renderScale,
                             bottom: Double(o.bottom + 1) / renderScale,
                             minX: Double(o.minX) / renderScale,
                             maxX: Double(o.maxX + 1) / renderScale))
    }
    for py in 0..<rep.pixelsHigh {
        var minX = -1, maxX = -1
        for px in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: px, y: py), c.alphaComponent > alphaFloor else { continue }
            if minX < 0 { minX = px }
            maxX = px
        }
        if minX >= 0 {
            if var o = open {
                o.bottom = py; o.minX = min(o.minX, minX); o.maxX = max(o.maxX, maxX)
                open = o
            } else {
                open = (py, py, minX, maxX)
            }
        } else if let o = open {
            close(o)
            open = nil
        }
    }
    if let o = open { close(o) }
    return bands
}

@MainActor
func renderedHeight(of view: some View) -> Double {
    let renderer = ImageRenderer(content: view)
    renderer.scale = CGFloat(renderScale)
    return Double(renderer.nsImage?.size.height ?? 0)
}

/// Corner radius, read off what the shape drew rather than asked for.
///
/// At its leftmost inked column a rounded rect has only just started, so the ink
/// there is short by both corners: `chord = (height - inked) / 2`. For a
/// circular corner of radius `r` measured at depth `d` into the shape,
/// `chord = r - sqrt(r² - (r - d)²)`, which solves to
/// `r = chord + d + sqrt(2·chord·d)`.
@MainActor
func measuredCornerRadius(of view: some View, height: Double) -> Double? {
    guard let rep = bitmap(of: view) else { return nil }

    for px in 0..<rep.pixelsWide {
        var inked = 0
        for py in 0..<rep.pixelsHigh
        where (rep.colorAt(x: px, y: py)?.alphaComponent ?? 0) > 0.5 { inked += 1 }
        guard inked > 0 else { continue }

        let chord = (height - Double(inked) / renderScale) / 2
        // That column's centre, i.e. half a rendered pixel into the shape.
        let depth = 0.5 / renderScale
        return chord + depth + (2 * chord * depth).squareRoot()
    }
    return nil
}

/// Every pixel a view drew, for the two helpers above that need colours rather
/// than coverage.
@MainActor
func bitmap(of view: some View) -> NSBitmapImageRep? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = CGFloat(renderScale)
    guard let tiff = renderer.nsImage?.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: tiff)
}

/// The horizontal rules in a rendered menu. Text ink never spans most of the
/// menu width in one unbroken run of pixel rows, so width plus thinness
/// separates a rule from a line of text without knowing where either sits.
func dividerBands(_ bands: [InkBand], menuWidth: Double) -> [InkBand] {
    bands.filter { $0.width > menuWidth * 0.5 && $0.height <= 2.5 }
}

/// The width `MenuBarView` fixes its popover to.
private let menuWidth = 272.0

/// One pixel at the render scale. Tolerances are this, not "close enough" --
/// the before/after difference on every assertion below is 6pt or more.
private let onePixel = 1.0 / renderScale

/// Shared, so a row rendered alone below cannot drift from the one the popover
/// renders.
private let sampleStatus = DeviceStatus.connected(battery: nil,
                                                  freeMiB: 10 * 1024,
                                                  capacityMiB: 32 * 1024)

@MainActor
private func sampleMenu() -> MenuBarView {
    let model = AppModel()
    model.status = sampleStatus
    return MenuBarView(model: model)
}

// MARK: - The native oracle

/// AppKit, not this file, is the authority on what a menu measures. This builds
/// real `NSMenu`s and derives the metrics from the difference between them, so
/// a `MenuMetrics` constant that drifts away from the platform fails here --
/// including if a future macOS changes them.
@MainActor
@Test func menuMetricsMatchTheOnesAppKitLaysARealMenuOutWith() {
    _ = NSApplication.shared

    func menuSize(items: Int, separators: Int) -> NSSize {
        let menu = NSMenu()
        for i in 0..<items {
            menu.addItem(NSMenuItem(title: "Item \(i)", action: nil, keyEquivalent: ""))
        }
        for _ in 0..<separators { menu.addItem(.separator()) }
        return menu.size
    }

    // Differences, so the menu's own top/bottom padding cancels out.
    let nativeRowHeight = menuSize(items: 3, separators: 0).height
        - menuSize(items: 2, separators: 0).height
    let nativeSeparatorHeight = menuSize(items: 2, separators: 1).height
        - menuSize(items: 2, separators: 0).height
    // An empty menu is padding and nothing else, split evenly top and bottom.
    let nativeContentInset = menuSize(items: 0, separators: 0).height / 2

    #expect(nativeRowHeight > 0, "the AppKit oracle produced no row height at all")
    #expect(MenuMetrics.rowHeight == nativeRowHeight,
            Comment(rawValue: "row height: ours \(MenuMetrics.rowHeight), AppKit \(nativeRowHeight)"))
    #expect(MenuMetrics.separatorHeight == nativeSeparatorHeight,
            Comment(rawValue: "separator height: ours \(MenuMetrics.separatorHeight), AppKit \(nativeSeparatorHeight)"))
    #expect(MenuMetrics.contentInset == nativeContentInset,
            Comment(rawValue: "content inset: ours \(MenuMetrics.contentInset), AppKit \(nativeContentInset)"))

    // The rows use SwiftUI `.body`. If that ever stops resolving to the menu
    // font's size, every height derived from it is wrong -- including the 4pt
    // padding that makes a row come out at exactly `rowHeight`.
    #expect(NSFont.preferredFont(forTextStyle: .body).pointSize
            == NSFont.menuFont(ofSize: 0).pointSize,
            "the row font is no longer the size AppKit uses for menu items")
}

// MARK: - What the menu actually draws

/// The single most obvious tell of a hand-built menu: our separators ran the
/// full 272pt width; AppKit insets a real one 16pt from both edges.
@MainActor
@Test func renderedSeparatorsAreInsetTheWayNativeOnesAre() throws {
    let dividers = dividerBands(inkBands(of: sampleMenu()), menuWidth: menuWidth)

    // Status | Recent | Actions | Settings+Quit.
    try #require(dividers.count == 3,
                 "expected 3 separators in the menu, measured \(dividers.count)")

    for (i, d) in dividers.enumerated() {
        #expect(abs(d.minX - MenuMetrics.separatorInset) <= onePixel,
                Comment(rawValue: "separator \(i) starts at \(d.minX), expected \(MenuMetrics.separatorInset)"))
        #expect(abs((menuWidth - d.maxX) - MenuMetrics.separatorInset) <= onePixel,
                Comment(rawValue: "separator \(i) ends \(menuWidth - d.maxX) from the right edge, expected \(MenuMetrics.separatorInset)"))
        #expect(abs(d.height - MenuMetrics.separatorThickness) <= onePixel,
                Comment(rawValue: "separator \(i) is \(d.height)pt thick, expected \(MenuMetrics.separatorThickness)"))
    }
}

/// Rows read as looser than native ones. `MenuRow` was already 24pt tall; the
/// looseness was the 2pt the enclosing `VStack` inserted between every row and
/// the separator's 9pt footprint where AppKit uses 11.
///
/// Measured centre-to-centre between the last two separators, which enclose
/// exactly the three action rows -- Sync Now, Show in Finder, Free Up Space on
/// P1. Each separator contributes half its footprint to that span, so the
/// distance is 3 rows plus one whole separator, and it is wrong if the row
/// height, the row spacing OR the separator footprint is wrong.
@MainActor
@Test func renderedRowPitchMatchesTheNativeMenu() throws {
    let dividers = dividerBands(inkBands(of: sampleMenu()), menuWidth: menuWidth)
    try #require(dividers.count == 3,
                 "expected 3 separators in the menu, measured \(dividers.count)")

    let actionRows = 3.0
    let expected = actionRows * MenuMetrics.rowHeight + MenuMetrics.separatorHeight
    let measured = dividers[2].midY - dividers[1].midY

    #expect(abs(measured - Double(expected)) <= onePixel,
            Comment(rawValue: "\(actionRows) action rows plus a separator measured \(measured)pt, expected \(expected)pt"))
}

/// Row text sat 8pt from the popover edge; a real menu item's text sits at 14.
///
/// The bare `Text` is rendered to measure the glyph's own left side bearing, so
/// the comparison is between two SwiftUI renders of the same string in the same
/// font and the bearing cancels exactly -- rather than being guessed at.
@MainActor
@Test func renderedRowTextSitsAtTheNativeLeadingInset() throws {
    let title = "Sync Now"

    let bareInk = try #require(inkBands(of: Text(title).font(.body)).map(\.minX).min(),
                               "the bare Text drew nothing to measure a bearing from")
    let rowInk = try #require(inkBands(of: MenuRow(title) {}.frame(width: menuWidth)).map(\.minX).min(),
                              "the MenuRow drew nothing to measure an inset from")

    let inset = rowInk - bareInk
    #expect(abs(inset - MenuMetrics.textInset) <= onePixel,
            Comment(rawValue: "row text is inset \(inset)pt, expected \(MenuMetrics.textInset)pt"))
}

/// `MenuRow` uses `minHeight`, not a fixed height: a one-line row has to land on
/// the native 24, and a row carrying a second line -- a status detail, an error,
/// a notice -- has to be allowed to grow past it rather than clip.
@MainActor
@Test func aOneLineRowIsExactlyNativeHeightAndATwoLineRowGrows() {
    let oneLine = renderedHeight(of: MenuRow("Sync Now") {}.frame(width: menuWidth))
    #expect(abs(oneLine - Double(MenuMetrics.rowHeight)) <= onePixel,
            Comment(rawValue: "a one-line row measured \(oneLine)pt, expected \(MenuMetrics.rowHeight)pt"))

    let twoLine = renderedHeight(
        of: MenuRow("P1 Connected", detail: "10 GB free of 32 GB").frame(width: menuWidth))
    #expect(twoLine > oneLine,
            Comment(rawValue: "a two-line row measured \(twoLine)pt, no taller than a one-line row"))
}

/// The popover's own top and bottom edge padding, measured as a difference so
/// the glyphs' top bearing cancels: the same first row and the same last row are
/// each rendered alone, and what is left over is the container's.
///
/// Both ends are asserted because the fix moves them together -- raising the top
/// alone would leave the popover visibly bottom-light.
@MainActor
@Test func renderedPopoverEdgePaddingIsBalancedAndMatchesTheMetric() throws {
    let menu = sampleMenu()
    let menuBands = inkBands(of: menu)
    let menuHeight = renderedHeight(of: menu)
    try #require(menuBands.count > 1, "the popover drew nothing to measure")

    let first = MenuRow(MenuBarView.statusTitle(for: sampleStatus),
                        accent: MenuBarView.statusAccent(for: sampleStatus),
                        detail: "10 GB free of 32 GB").frame(width: menuWidth)
    let last = MenuRow("Quit Steno") {}.frame(width: menuWidth)

    let firstInk = try #require(inkBands(of: first).first?.top,
                                "the status row drew nothing")
    let lastInk = try #require(inkBands(of: last).last?.bottom,
                               "the last row drew nothing")
    let lastTail = renderedHeight(of: last) - lastInk

    let topInset = menuBands[0].top - firstInk
    let bottomInset = menuHeight - menuBands[menuBands.count - 1].bottom - lastTail

    #expect(abs(topInset - MenuMetrics.popoverInset) <= onePixel,
            Comment(rawValue: "top inset measured \(topInset)pt, expected \(MenuMetrics.popoverInset)pt"))
    #expect(abs(bottomInset - MenuMetrics.popoverInset) <= onePixel,
            Comment(rawValue: "bottom inset measured \(bottomInset)pt, expected \(MenuMetrics.popoverInset)pt"))
    #expect(abs(topInset - bottomInset) <= onePixel,
            Comment(rawValue: "popover is unbalanced: \(topInset)pt above, \(bottomInset)pt below"))
}

/// The hover highlight was a full-width, square-cornered bar running the popover
/// edge to edge. A native menu highlights a rounded rect inset from both edges.
///
/// Hover cannot be simulated headlessly, which is why `MenuRowHighlight` is its
/// own view: this renders it with `isActive` forced on and measures what it drew,
/// rather than asserting the constants against themselves.
@MainActor
@Test func renderedHoverHighlightIsInsetFromBothEdgesAndRounded() throws {
    let highlight = MenuRowHighlight(isActive: true)
        .frame(width: menuWidth, height: MenuMetrics.rowHeight)
    // Crisp coverage only: a corner's antialiased fringe is not its geometry.
    let band = try #require(inkBands(of: highlight, alphaFloor: 0.5).first,
                            "the active highlight drew nothing")

    #expect(abs(band.minX - MenuMetrics.highlightInset) <= onePixel,
            Comment(rawValue: "highlight starts at \(band.minX), expected \(MenuMetrics.highlightInset)"))
    #expect(abs((menuWidth - band.maxX) - MenuMetrics.highlightInset) <= onePixel,
            Comment(rawValue: "highlight ends \(menuWidth - band.maxX) from the right edge, expected \(MenuMetrics.highlightInset)"))
    // The one relationship the reference screenshot fixes: wider than the
    // separator, still short of the popover edge.
    #expect(band.minX > 0 && band.minX < MenuMetrics.separatorInset,
            Comment(rawValue: "highlight inset \(band.minX) must sit between flush and the separator's \(MenuMetrics.separatorInset)"))

    let radius = try #require(measuredCornerRadius(of: highlight,
                                                   height: Double(MenuMetrics.rowHeight)),
                              "could not read a corner off the rendered highlight")
    #expect(abs(radius - Double(MenuMetrics.highlightCornerRadius)) <= 0.5,
            Comment(rawValue: "corner radius measured \(radius)pt, expected \(MenuMetrics.highlightCornerRadius)pt"))
}

/// The highlight belongs to hover on an interactive row and nothing else. A
/// popover with nothing hovered must carry none of it -- not on the status row,
/// not on the error or notice rows, not on the disabled actions.
///
/// Asserted by colour on the whole popover rather than by rendering one
/// unhighlighted row and checking it is empty: an "it drew nothing" assertion is
/// not reliable here, because `ImageRenderer` hands back a previous render of the
/// same pixel size when the content draws nothing at all. Colour on a render this
/// size cannot be fooled that way, and it tests the real composition.
@MainActor
@Test func nothingIsHighlightedUntilARowIsHovered() throws {
    let lit = try #require(bitmap(of: MenuRowHighlight(isActive: true)
        .frame(width: menuWidth, height: MenuMetrics.rowHeight))?
        .colorAt(x: 200, y: 20)?.usingColorSpace(.deviceRGB),
                           "could not sample the highlight's own colour")
    let menu = try #require(bitmap(of: sampleMenu()), "the popover rendered nothing")

    for py in 0..<menu.pixelsHigh {
        for px in 0..<menu.pixelsWide {
            guard let c = menu.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB),
                  c.alphaComponent > 0.5 else { continue }
            let distance = abs(c.redComponent - lit.redComponent)
                + abs(c.greenComponent - lit.greenComponent)
                + abs(c.blueComponent - lit.blueComponent)
            #expect(distance > 0.3,
                    Comment(rawValue: "pixel (\(px), \(py)) is the hover highlight's colour with nothing hovered"))
            if distance <= 0.3 { return }
        }
    }
}

/// The whole menu, offered the height it had before recordings carried titles.
///
/// `MenuRow` sized itself with `.frame(minHeight:)`, which is a floor rather
/// than a commitment: it clamps the proposal it forwards but still hands an
/// undersized one to its content. A `VStack` short on height therefore squeezed
/// every FLEXIBLE two-line row toward 24pt — the single-line height — while the
/// rigid single-line rows kept their size, and each detail line collapsed into
/// the title below it.
///
/// Measured on the live app: the popover drew at 330pt against a 412pt ideal.
/// That gap is exactly 84pt, which is what you get when all six two-line rows
/// sit at 24 instead of 38.
///
/// Invisible before spec 2, because only the status row had two lines. Five
/// recent titles turned one row's worth of squeeze into six.
///
/// Asserted on the SPACING of the lines still drawn, not on how many are drawn:
/// content that no longer fits is clipped at the menu's edge, which also drops
/// bands. Collapsing changes the spacing; clipping does not.
@MainActor
@Test func theMenuDoesNotSqueezeTwoLineRowsWhenHeightIsShort() {
    let model = AppModel()
    model.status = .connected(battery: nil, freeMiB: 59520, capacityMiB: 59648)
    model.recent = (0..<5).map { i in
        Sidecar(signature: "sig\(i)", deviceFilename: "a.hda",
                relativePath: "2026-08-05/sig\(i).mp3", lengthBytes: 10,
                durationSeconds: 3985,
                recordedAt: Date(timeIntervalSince1970: 1_754_400_000 - Double(i) * 3600),
                syncedAt: Date(timeIntervalSince1970: 1_754_400_000),
                deviceSerial: "S", deviceModel: "hidock-p1",
                timeZoneIdentifier: "Asia/Manila",
                title: "Distribution Networking Explained")
    }
    let menu = MenuBarView(model: model)

    func minimumLineGap(_ view: some View) -> Double {
        let bands = inkBands(of: view)
        guard bands.count > 1 else { return 0 }
        return (1..<bands.count).map { bands[$0].top - bands[$0 - 1].bottom }.min() ?? 0
    }

    let relaxed = minimumLineGap(menu)
    // 330pt is what the live popover offered: the height this menu needed back
    // when every row was one line.
    let squeezed = minimumLineGap(menu.frame(height: 330))

    #expect(relaxed > 0, "the unconstrained menu should draw separated lines")
    #expect(squeezed >= relaxed - onePixel,
            Comment(rawValue: "lines sit \(squeezed)pt apart at 330pt versus \(relaxed)pt unconstrained — two-line rows are being squeezed into each other"))
}
