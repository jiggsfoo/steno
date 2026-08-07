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
/// The signature asserted is the transport's, not an arbitrary pixel count: a
/// hairline rule spanning the full pane width, with the transport drawing
/// below it and nothing below THAT. Two rows of stacked controls now draw as
/// three separate ink bands — the scrubber, the elapsed/remaining line, and
/// the button row — with real vertical gaps between them (measured 5–7.5pt),
/// not one taller band the way a single-row transport was. So `bands.last`
/// is no longer the whole transport: it is only the button row, centred by
/// `Spacer()`s on both sides and just 272pt wide of 500pt — narrower than the
/// 80%-of-pane-width floor below, despite being exactly the row this test
/// means to find. Position-from-the-end (`bands.count - 2` / `.last`) is what
/// broke; the rule's own SHAPE did not, so it is found by that shape —
/// height ≤ 2pt, width ≥ 98% of the pane — searched from the end, and
/// everything after it (whatever number of bands that is) is folded into one
/// bounding box standing in for "the transport". That box's width is 476.5pt
/// (the full-width scrubber alone clears the 80% floor) and its height is
/// 52.5pt of ink — under the SAME 60pt ceiling the single-row transport used,
/// with 7.5pt of margin, so the ceiling did not need widening even though the
/// row it bounds now spans three lines rather than one. Both numbers hold
/// for both transcript states. Not folding the trailing bands would have
/// meant either hardcoding "3" (brittle to a font-rendering tweak merging or
/// splitting one of the three rows) or reverting to position math (which is
/// exactly what just broke).
///
/// Run for BOTH transcript states. The transport lives in `body` rather than
/// inside `reader(_:)` precisely so an untranscribed recording can still be
/// played, and moving it back inside would silently take that away — the
/// untranscribed case renders the same rule-then-transport signature.
///
/// `bands.count >= 3` guards the `List` degenerate-render failure mode
/// `inkBands`' own doc comment warns about: one band spanning the whole frame
/// reads as a successful measurement. Eleven bands are produced with a
/// transcript, seven without (up from nine and five before this task — the
/// two extra rows).
@MainActor
@Test(arguments: [true, false])
func theTransportRowIsMountedBelowARuleAtTheBottomOfThePane(transcribed: Bool) throws {
    let bands = hostedInkBands(of: layoutProbePane(transcribed: transcribed))
    try #require(bands.count >= 3)

    let ruleIndex = try #require(
        bands.lastIndex { $0.height <= 2 && $0.width >= paneWidth * 0.98 },
        Comment(rawValue: "no full-width hairline rule found anywhere in the pane — "
                + "the transport's Divider is missing"))
    let transportBands = bands[(ruleIndex + 1)...]
    try #require(!transportBands.isEmpty,
                 Comment(rawValue: "nothing draws below the rule — the transport row is missing"))

    let row = InkBand(top: transportBands.map(\.top).min()!,
                      bottom: transportBands.map(\.bottom).max()!,
                      minX: transportBands.map(\.minX).min()!,
                      maxX: transportBands.map(\.maxX).max()!)

    #expect(row.width > paneWidth * 0.8,
            Comment(rawValue: "the transport's combined band is \(row.width)pt wide of \(paneWidth)pt — "
                    + "that is a transcript line, not the transport row"))
    #expect(row.height < 60,
            Comment(rawValue: "the transport's combined band is \(row.height)pt tall — a row, not a pane"))
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

/// Task 5's review caught `Menu { … } label: { EmptyView() }` in
/// `RecordingEditor`'s topic combo box as an invisible affordance:
/// `.menuStyle(.borderlessButton)` renders only what its label gives it,
/// unlike the automatic pull-down style, which bakes a disclosure glyph into
/// its bezel regardless of label content.
///
/// `RecordingEditor` itself cannot be rendered mid-edit to check this
/// directly: `editingTopic` is `private @State`, defaulted `false`, with no
/// initializer path in from outside a live tap gesture — the same
/// `@State`-is-inert wall documented throughout this branch. So this isolates
/// the exact label/style/frame construction the combo box's chevron uses
/// (`Image(systemName: "chevron.down")`, `.caption2`, `.secondary`,
/// `.menuStyle(.borderlessButton)`, `.frame(width: 16)`) and asks whether
/// THAT draws meaningfully more ink than the broken form did — a check on the
/// general SwiftUI behaviour the fix rests on, not on `RecordingEditor`'s own
/// view tree.
///
/// NOT a plain "is it non-empty" check, deliberately: an `EmptyView()` label
/// on this exact `Menu`/`.borderlessButton`/`frame(width: 16)` combination
/// was measured to draw a small amount of ink of its own — one band, 4.5pt
/// tall by 7pt wide (`≈32pt²`), not the literal zero its name and the
/// review's wording suggest. Read directly off pixels, not asserted from
/// AppKit documentation: `.borderlessButton` still supplies *some* minimal
/// default chrome for hit-testing even with nothing in the label, and a bare
/// `#expect(!bands.isEmpty)` would have passed on the ORIGINAL broken form
/// too, proving nothing. What actually changed is the SIZE: the explicit
/// glyph measures `≈68pt²`, roughly double the empty label's incidental
/// artifact, and — unlike that artifact — starts at the frame's left edge
/// rather than sitting inset and centred, consistent with a real chevron
/// glyph rather than a stray focus-ring fragment. The `1.5×` floor below sits
/// with comfortable margin under the measured `≈2.17×` and well above `1.0×`
/// (which is what reverting to `EmptyView()` produces): confirmed by
/// literally reverting to `label: { EmptyView() }` and rerunning, which
/// fails this assertion (`chevronArea` and `emptyArea` converge to the same
/// value, ratio ~1.0).
@MainActor
@Test func aBorderlessMenuLabelledByAnImageDrawsMeaningfullyMoreInkThanAnEmptyLabel() {
    func probe(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            Text("x")
        } label: {
            label()
        }
        .menuStyle(.borderlessButton)
        .frame(width: 16, height: 16)
    }

    func inkArea(_ bands: [InkBand]) -> Double {
        bands.reduce(0) { $0 + $1.width * $1.height }
    }

    let chevronArea = inkArea(hostedInkBands(of: probe {
        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
    }))
    let emptyArea = inkArea(hostedInkBands(of: probe { EmptyView() }))

    #expect(chevronArea > emptyArea * 1.5,
            Comment(rawValue: "Image(systemName: \"chevron.down\") drew \(chevronArea)pt² of ink versus "
                    + "\(emptyArea)pt² for an EmptyView() label in the same Menu — not meaningfully "
                    + "more visible, so the chevron affordance is effectively still missing"))
}
