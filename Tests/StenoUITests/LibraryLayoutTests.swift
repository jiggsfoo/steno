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
/// Cross-checked against `inkBands` on the real menu bar popover (not
/// `ScrollView`-backed, so both can measure it): band edges agree to within a
/// point at both its relaxed and squeezed heights. Substitute rasterizer, not
/// a different measurement.
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

@MainActor
@Test func transcriptLinesDoNotCollapseWhenTheWindowIsShort() {
    let segments = (0..<6).map {
        Segment(start: Double($0) * 10, end: Double($0) * 10 + 8,
                text: "A line of transcript number \($0)", speaker: nil)
    }
    let recording = LoadedRecording(
        sidecar: Sidecar(signature: "sig", deviceFilename: "a.hda",
                         relativePath: "2026-08-05/a.mp3", lengthBytes: 10,
                         durationSeconds: 60, recordedAt: nil,
                         syncedAt: Date(timeIntervalSince1970: 1), deviceSerial: "S",
                         deviceModel: "hidock-p1", timeZoneIdentifier: "Asia/Manila",
                         title: "Layout probe"),
        transcript: Transcript(signature: "sig", text: "x", segments: segments,
                               locale: "en_US", backend: "speechanalyzer", modelID: "m",
                               transcribedAt: Date(timeIntervalSince1970: 1),
                               audioDurationSeconds: 60))

    let pane = TranscriptPane(recording: recording, player: AudioPlayer(),
                              knownTopics: [], model: AppModel(), onSaved: {})
        .frame(width: 500)

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
