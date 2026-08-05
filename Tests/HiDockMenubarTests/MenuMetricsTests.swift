import AppKit
import SwiftUI
import Testing
@testable import HiDockMenubar

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

@MainActor
private func sampleMenu() -> MenuBarView {
    let model = AppModel()
    model.status = .connected(battery: nil, freeMiB: 10 * 1024, capacityMiB: 32 * 1024)
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
