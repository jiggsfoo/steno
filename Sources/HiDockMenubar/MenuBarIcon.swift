import AppKit

/// Maps app state to the menu bar's icon.
///
/// Every state is distinguished by SHAPE rather than colour, so the icon still
/// reads on a tinted menu bar and for a colour-blind user. Red appears only on
/// the recording state, where it reinforces a shape that already reads as
/// recording on its own.
public enum MenuBarIcon {

    public enum State: CaseIterable, Sendable {
        case disconnected
        case connected
        case syncing
        case recording
        case attention
    }

    /// Recording wins over everything else. It is the most time-critical thing
    /// the icon can communicate, and it can coincide with any other status.
    public static func state(for status: DeviceStatus, recording: String?) -> State {
        if recording != nil { return .recording }
        switch status {
        case .disconnected: return .disconnected
        case .connected: return .connected
        case .syncing: return .syncing
        case .busy, .unavailable: return .attention
        }
    }

    /// The SF Symbol for a state, or nil when it must be composed.
    ///
    /// Verified against macOS 27 on 2026-08-05. `waveform.badge.arrow.down`
    /// does NOT exist — nor does any waveform badge meaning "downloading" —
    /// which is why `.syncing` returns nil and is drawn instead.
    public static func symbolName(for state: State) -> String? {
        switch state {
        case .disconnected: return "waveform.slash"
        case .connected:    return "waveform"
        case .syncing:      return nil                              // composed
        case .recording:    return "waveform.badge.mic"
        case .attention:    return "waveform.badge.exclamationmark"
        }
    }

    public static func accessibilityLabel(for state: State) -> String {
        switch state {
        case .disconnected: return "HiDock: no device"
        case .connected:    return "HiDock: connected"
        case .syncing:      return "HiDock: syncing"
        case .recording:    return "HiDock: recording"
        case .attention:    return "HiDock: needs attention"
        }
    }

    /// Symbol point size. 16 put 17-19pt of ink on screen and produced natural
    /// canvases of 19-22pt; the badged variants were then at or over the 22pt
    /// the status bar gives an item, which reads chunkier than the system's
    /// own extras. At 14 all four symbols land on a 15pt-tall ink grid.
    private static let pointSize: CGFloat = 14

    /// The size every state renders at.
    ///
    /// Without this each state shipped at its symbol's natural canvas —
    /// 19x21, 19x20, 21x21, 21x22, 22x21 — so the icon changed size by up to
    /// 2pt as the device changed state, visibly growing when a sync started.
    /// Height 18 sits inside the 22pt status item box, which is where Apple's
    /// own status art sits. Width is fixed too, so the items to the left of
    /// this one do not shuffle sideways on a state change.
    public static let renderedSize = NSSize(width: 20, height: 18)

    public static func image(for state: State) -> NSImage {
        let art = symbolName(for: state).flatMap { name -> NSImage? in
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            else { return nil }
            return symbol.withSymbolConfiguration(configuration(for: state)) ?? symbol
        } ?? composedSyncingImage()

        let image = fittedToMenuBar(art)

        // Template images invert for light/dark and for a tinted menu bar.
        // Recording opts out so its red survives.
        image.isTemplate = (state != .recording)
        image.accessibilityDescription = accessibilityLabel(for: state)
        return image
    }

    /// Centres a state's art, at its own scale, in the one shared canvas.
    ///
    /// Deliberately does NOT rescale the art. SF Symbols of the same family
    /// share a layout grid at a given point size — the badged variants have a
    /// bigger canvas, not a bigger waveform — so normalising the canvas is
    /// enough to hold the glyph still, while normalising the ink height would
    /// shrink the waveform on the badged states and reintroduce the same
    /// wobble in the part of the silhouette the user actually tracks.
    private static func fittedToMenuBar(_ art: NSImage) -> NSImage {
        let canvas = renderedSize
        // Rounded: a half-point offset resamples a crisp glyph into a blurry
        // one at 1x.
        let origin = NSPoint(x: ((canvas.width - art.size.width) / 2).rounded(),
                             y: ((canvas.height - art.size.height) / 2).rounded())
        return NSImage(size: canvas, flipped: false) { _ in
            art.draw(in: NSRect(origin: origin, size: art.size))
            return true
        }
    }

    /// Recording is the one state that carries colour, so it is also the one
    /// state that must ask for it. Opting out of template rendering only stops
    /// macOS recolouring the image; it does not make the image red. Without
    /// the palette colour below, `.recording` renders as flat black and is
    /// invisible on the default dark menu bar -- the exact state that must
    /// never go unnoticed.
    private static func configuration(for state: State) -> NSImage.SymbolConfiguration {
        let base = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard state == .recording else { return base }
        return base.applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
    }

    /// `waveform` with a downward arrow badged onto its bottom-trailing
    /// corner, mimicking a real SF Symbol badge.
    ///
    /// No SF Symbol conveys "downloading" on a waveform, so this is the one
    /// state that is drawn. Keeping the waveform means the silhouette stays
    /// recognisable across every state -- but only if it is the SAME
    /// waveform. `withSymbolConfiguration` rescales a symbol image; it does
    /// nothing to a hand-drawn one, so `pointSize` is inert here and the
    /// geometry has to be got right at draw time instead. Measured against
    /// the real symbols at `pointSize: 16` (top-left pixel coordinates):
    ///
    ///     bare `waveform`   canvas 19x20   ink 15x16 @ x2-16 y2-17
    ///     `.badge.mic`      canvas 21x22   badge 6x8  @ x13-18 y11-18
    ///     `.badge.exclam`   canvas 22x21   badge 8x7  @ x12-19 y11-17
    ///
    /// So: draw the waveform at the symbol's own configured size (NOT into a
    /// smaller box -- an earlier version used a hardcoded 14x14 and shipped a
    /// waveform 31% shorter than every other state), and bottom-anchor the
    /// badge the way both real badges are anchored. Badges knock a gap out of
    /// the glyph they sit on rather than overlapping it, which is why the
    /// waveform's right-hand bars are cleared before the arrow is stroked.
    ///
    /// Every number below is expressed as a fraction of `pointSize`, using the
    /// measurements above as the ratios. `withSymbolConfiguration` is a no-op
    /// on a hand-drawn image, so nothing else here would follow `pointSize` on
    /// its own -- and a `pointSize` that moved four states while pinning the
    /// fifth is exactly the drift that produced the 31%-short waveform.
    private static func composedSyncingImage() -> NSImage {
        let scale = pointSize / 16

        // The badged symbols are 21x22 and 22x21 at pointSize 16, and the
        // waveform's own 19x20 sits inside this with the same 2pt leading
        // inset. Rounded to a whole point: a fractional canvas puts the glyph
        // on half-pixel boundaries at 1x.
        let side = (21 * scale).rounded()
        let size = NSSize(width: side, height: side)
        // Bottom-left origin, matching `flipped: false` below. At pointSize 16
        // this lands the arrow at x13-18 / y11-18 top-left -- the mic badge's
        // own box.
        let badge = NSRect(x: 13 * scale, y: 2 * scale,
                           width: 6 * scale, height: 8 * scale)

        let image = NSImage(size: size, flipped: false) { _ in
            guard let waveform = NSImage(systemSymbolName: "waveform",
                                         accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration(for: .syncing))
            else { return false }
            waveform.isTemplate = true
            // Top-aligned in the 21pt canvas so the ink lands at y2-17, the
            // same rows the symbol states occupy.
            waveform.draw(in: NSRect(x: 0, y: size.height - waveform.size.height,
                                     width: waveform.size.width,
                                     height: waveform.size.height))

            // -1.2 is tuned, not arbitrary: it leaves the shortest bar's tip
            // as a 2x2 nub above the badge, which is exactly what
            // `waveform.badge.exclamationmark` leaves. A wider knockout
            // shaves that to a lone 1px speck that reads as a rendering
            // artifact.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: badge.insetBy(dx: -1.2 * scale, dy: -1.2 * scale),
                         xRadius: 3 * scale, yRadius: 3 * scale).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // 1.8 rather than the bars' 2.0: the head's two arms and the stem
            // all meet in a 3pt square, and at the bars' full weight that
            // corner fills in and reads as a solid wedge rather than an arrow.
            let arrow = NSBezierPath()
            arrow.lineWidth = 1.8 * scale
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.move(to: NSPoint(x: badge.midX, y: badge.maxY - 1 * scale))
            arrow.line(to: NSPoint(x: badge.midX, y: badge.minY + 1.4 * scale))
            arrow.move(to: NSPoint(x: badge.minX + 1.1 * scale, y: badge.minY + 4.2 * scale))
            arrow.line(to: NSPoint(x: badge.midX, y: badge.minY + 1.4 * scale))
            arrow.line(to: NSPoint(x: badge.maxX - 1.1 * scale, y: badge.minY + 4.2 * scale))
            NSColor.black.setStroke()      // template mode recolours this
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
