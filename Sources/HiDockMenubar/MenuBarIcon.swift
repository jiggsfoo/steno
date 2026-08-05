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

    private static let pointSize: CGFloat = 16

    public static func image(for state: State) -> NSImage {
        let image = symbolName(for: state).flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        } ?? composedSyncingImage()

        let configured = image.withSymbolConfiguration(configuration(for: state)) ?? image

        // Template images invert for light/dark and for a tinted menu bar.
        // Recording opts out so its red survives.
        configured.isTemplate = (state != .recording)
        configured.accessibilityDescription = accessibilityLabel(for: state)
        return configured
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

    /// `waveform` with a small downward chevron drawn beside it.
    ///
    /// No SF Symbol conveys "downloading" on a waveform, so this is the one
    /// state that is drawn. Keeping the waveform means the silhouette stays
    /// recognisable across every state.
    private static func composedSyncingImage() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let base = NSImage(systemSymbolName: "waveform",
                                     accessibilityDescription: nil) else { return false }
            base.isTemplate = true
            base.draw(in: NSRect(x: 0, y: 1, width: 14, height: 14))

            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: rect.maxX - 4, y: rect.midY + 4))
            path.line(to: NSPoint(x: rect.maxX - 4, y: rect.midY - 3))
            path.move(to: NSPoint(x: rect.maxX - 6.6, y: rect.midY - 0.6))
            path.line(to: NSPoint(x: rect.maxX - 4, y: rect.midY - 3.2))
            path.line(to: NSPoint(x: rect.maxX - 1.4, y: rect.midY - 0.6))
            NSColor.black.setStroke()      // template mode recolours this
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
