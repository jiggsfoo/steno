import AppKit
import SwiftUI
import Testing
@testable import StenoUI

/// `ImageRenderer` measures a view's IDEAL layout. The spec-2 menu bug was
/// invisible at ideal size and only appeared when the container offered less
/// height than the content wanted — the rows collapsed into each other while
/// three separate measurements said the layout was fine.
///
/// So: render both, and assert on the SPACING of what is still drawn. Never on
/// how many ink bands appear — clipping and collapsing both reduce a count, and
/// a count-based test written during that fix survived its own mutation check.
///
/// `TranscriptPane`'s reader sits inside a `ScrollView`, and `ImageRenderer`
/// draws nothing at all for content inside a `ScrollView` in this headless
/// environment — verified against a plain `VStack`, a `LazyVStack`, and a
/// `ScrollViewReader`-wrapped `ScrollView`, at heights from 120pt to 2000pt,
/// every one producing zero ink for the scrolled content. `inkBands`
/// unmodified would therefore compare the pane's header against itself and
/// pass regardless of what the transcript lines do underneath it — exactly
/// the "a count-based test proves nothing" trap this file's own reasoning
/// warns about, one level upstream of band-counting. `hostedInkBands` below
/// rasterizes through a real (offscreen, unshown) `NSHostingView` backing an
/// actual `NSWindow` instead, which does draw `ScrollView` content.
///
/// NOT a drop-in replacement for `inkBands` — only a usable substitute here.
/// Cross-checked against `inkBands` on the real menu popover (its one
/// `ScrollView`-free view, so the only content both can measure): band
/// BOTTOMS agree exactly across all 22 bands measured, at both its relaxed
/// and squeezed heights. TOPS do not — `hostedInkBands` reports a top either
/// identical to `inkBands`' or exactly one 2x-scale pixel row (0.5pt)
/// earlier, never later, in roughly half of them. Not the `scale` this file
/// derives (`rep.pixelsWide / size.width` measured 2.0 every time, same as
/// `inkBands`' hardcoded constant) and not `alphaFloor` (0.05, identical) —
/// most likely `cacheDisplay`'s antialiasing painting a fractional-alpha
/// pixel row above certain glyphs that `ImageRenderer`'s rasterizer does not
/// quite reach. This shrinks a measured GAP (next band's top minus this
/// band's bottom) by up to 0.5pt, one-sided, never widening one.
///
/// Confirmed load-bearing, not theoretical: reproducing the real spec-2
/// collapse (`MenuRow`'s `.fixedSize(horizontal:vertical:)` disabled, then
/// restored) makes `inkBands` fail cleanly — relaxed 4.0pt, squeezed 3.0pt,
/// needs ≥3.5pt. The identical collapse measured through `hostedInkBands`
/// reads relaxed 3.5pt, squeezed 3.0pt: PASSES, exactly on the -0.5pt
/// tolerance floor below. `TranscriptPane`'s own margins (12–15.5pt, 24-31x
/// that 0.5pt bias) are nowhere near that edge, so the assertion below is
/// sound — but do not reuse `hostedInkBands` for an assertion whose margin
/// is within a couple of points of its tolerance without accounting for
/// this. (`List` has the same `ImageRenderer` blindness and is worse still --
/// that warning now lives on `inkBands` itself, where someone about to point
/// it at `LibrarySidebar` will be looking.)
@MainActor
private func hostedInkBands(of view: some View, alphaFloor: CGFloat = 0.05) -> [InkBand] {
    let hosting = NSHostingView(rootView: view)
    let size = hosting.fittingSize
    guard size.width > 0, size.height > 0 else { return [] }
    hosting.frame = NSRect(origin: .zero, size: size)
    // Offscreen and never ordered front; released when this function returns.
    // Needed anyway -- an `NSHostingView` only draws `ScrollView` content once
    // it is actually backing a window, not when merely asked for an image.
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return [] }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let scale = Double(rep.pixelsWide) / Double(size.width)

    var bands: [InkBand] = []
    var open: (top: Int, bottom: Int, minX: Int, maxX: Int)?
    func close(_ o: (top: Int, bottom: Int, minX: Int, maxX: Int)) {
        bands.append(InkBand(top: Double(o.top) / scale, bottom: Double(o.bottom + 1) / scale,
                             minX: Double(o.minX) / scale, maxX: Double(o.maxX + 1) / scale))
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

/// The width every measurement below renders at.
private let paneWidth = 500.0

private func layoutProbeRecording(transcribed: Bool = true) -> LoadedRecording {
    let segments = (0..<6).map {
        Segment(start: Double($0) * 10, end: Double($0) * 10 + 8,
                text: "A line of transcript number \($0)", speaker: nil)
    }
    let sidecar = Sidecar(signature: "sig", deviceFilename: "a.hda",
                          relativePath: "2026-08-05/a.mp3", lengthBytes: 10,
                          durationSeconds: 60, recordedAt: nil,
                          syncedAt: Date(timeIntervalSince1970: 1), deviceSerial: "S",
                          deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila",
                          title: "Layout probe")
    guard transcribed else { return LoadedRecording(sidecar: sidecar, transcript: nil) }
    return LoadedRecording(
        sidecar: sidecar,
        transcript: Transcript(signature: "sig", text: "x", segments: segments,
                               locale: "en_US", backend: "speechanalyzer", modelID: "m",
                               transcribedAt: Date(timeIntervalSince1970: 1),
                               audioDurationSeconds: 60))
}

@MainActor
private func layoutProbePane(transcribed: Bool = true) -> some View {
    TranscriptPane(recording: layoutProbeRecording(transcribed: transcribed),
                   player: AudioPlayer(), knownTopics: [], model: AppModel(), onSaved: {})
        .frame(width: paneWidth)
}

/// Every DECISION behind the playhead is covered by `TranscriptPaneTests`'
/// pure-function tests. That the playhead is MOUNTED IN THE VIEW is not
/// something any of them can see: deleting `Divider()` and `transport` from
/// `TranscriptPane.body` compiles with zero warnings and leaves every other
/// test green. This is the only assertion on this branch that the feature
/// actually exists on screen.
///
/// The signature asserted is the transport row's, not an arbitrary pixel
/// count: a hairline rule spanning the full pane width, a wide row directly
/// under it, and nothing below that. Measured at 500pt wide, the transport
/// band is 473pt across and the rule 500pt by 1pt, while an ordinary
/// transcript line is 202.5pt — so the width test has better than 2x
/// headroom, far outside the 0.5pt one-sided bias `hostedInkBands` carries
/// (which applies to measured GAPS in any case, and nothing here measures a
/// gap). Verified stable: identical to 0.5pt across three consecutive runs.
///
/// Run for BOTH transcript states. The transport lives in `body` rather than
/// inside `reader(_:)` precisely so an untranscribed recording can still be
/// played, and moving it back inside would silently take that away — the
/// untranscribed case renders the same rule-then-row signature.
///
/// `bands.count >= 3` guards the `List` degenerate-render failure mode
/// `inkBands`' own doc comment warns about: one band spanning the whole frame
/// reads as a successful measurement. Nine bands are produced with a
/// transcript, five without.
@MainActor
@Test(arguments: [true, false])
func theTransportRowIsMountedBelowARuleAtTheBottomOfThePane(transcribed: Bool) throws {
    let bands = hostedInkBands(of: layoutProbePane(transcribed: transcribed))
    try #require(bands.count >= 3)

    let row = try #require(bands.last)
    let rule = bands[bands.count - 2]

    #expect(row.width > paneWidth * 0.8,
            Comment(rawValue: "the bottom band is \(row.width)pt wide of \(paneWidth)pt — "
                    + "that is a transcript line, not the transport row"))
    #expect(row.height < 60,
            Comment(rawValue: "the bottom band is \(row.height)pt tall — a row, not a pane"))
    #expect(rule.height <= 2,
            Comment(rawValue: "no hairline above the bottom row (measured \(rule.height)pt) — "
                    + "the transport's Divider is missing"))
    #expect(rule.width >= paneWidth * 0.98,
            Comment(rawValue: "the hairline spans \(rule.width)pt of \(paneWidth)pt — "
                    + "that is not a full-width rule"))
}

@MainActor
@Test func transcriptLinesDoNotCollapseWhenTheWindowIsShort() {
    let pane = layoutProbePane()

    func minimumGap(_ view: some View) -> Double {
        let bands = hostedInkBands(of: view)
        guard bands.count > 1 else { return 0 }
        return (1..<bands.count).map { bands[$0].top - bands[$0 - 1].bottom }.min() ?? 0
    }

    let relaxed = minimumGap(pane)
    let squeezed = minimumGap(pane.frame(height: 120))

    #expect(relaxed > 0, "the unconstrained pane should draw separated lines")
    #expect(squeezed >= relaxed - 0.5,
            Comment(rawValue: "lines sit \(squeezed)pt apart in a short window versus \(relaxed)pt relaxed — they are being squeezed together"))
}
