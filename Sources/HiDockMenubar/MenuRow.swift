import SwiftUI

/// One row of the menu.
///
/// `MenuBarExtra` stays `.window` style because `.menu` renders a real NSMenu
/// and cannot host the sync progress bar or a two-line row. That means the menu
/// *appearance* is hand-built, and this is where it lives — so it is built once
/// and every row inherits it.
///
/// `detail` is the row's optional second line. Today it carries the free-space
/// summary, the unavailable reason, and the error/notice messages; spec 2 adds
/// transcript titles to the recent rows on the same slot.
public struct MenuRow: View {

    /// A row's leading symbol, its tint, and the word VoiceOver hears first.
    ///
    /// Bundled into one value rather than passed as three parameters so a tint
    /// can never travel without a shape to carry it -- enforced below by
    /// `init`, not just by convention at the two call sites that build one.
    /// HIG forbids encoding state in colour alone, and a menu row has exactly
    /// one place that gets colour — here.
    ///
    /// `spokenSeverity` exists because VoiceOver receives neither the colour
    /// nor the symbol. Without it, "3 recordings failed to sync" and "Freed 3
    /// recording(s) from the P1." announce as the same kind of thing.
    public struct Accent: Sendable, Equatable {
        public let symbol: String
        public let tint: Color?
        public let spokenSeverity: String?

        public init(symbol: String, tint: Color? = nil, spokenSeverity: String? = nil) {
            precondition(!symbol.isEmpty,
                         "Accent needs a real symbol -- a tint must never travel without a shape to carry it.")
            self.symbol = symbol
            self.tint = tint
            self.spokenSeverity = spokenSeverity
        }

        /// Something went wrong. Orange is reinforcement; the triangle and the
        /// spoken "Error" are what actually carry it.
        public static let error = Accent(symbol: "exclamationmark.triangle.fill",
                                         tint: .orange,
                                         spokenSeverity: "Error")

        /// A completed action worth mentioning, e.g. "Freed 3 recording(s)".
        /// Deliberately untinted — it is not a warning — but it still needs a
        /// shape and a word of its own so it cannot be mistaken for one.
        public static let notice = Accent(symbol: "checkmark.circle",
                                          spokenSeverity: "Notice")
    }

    private let title: String
    private let accent: Accent?
    private let value: String?
    private let detail: String?
    private let detailLineLimit: Int?
    private let isEnabled: Bool
    private let action: (() -> Void)?

    @State private var isHovering = false

    /// `detailLineLimit` rather than `lineLimit`: it caps the second line only.
    /// Under the old name `MenuRow("a very long title", lineLimit: 2)` compiled
    /// and silently did nothing. Titles here are short generated strings and
    /// have never needed capping.
    public init(
        _ title: String,
        accent: Accent? = nil,
        value: String? = nil,
        detail: String? = nil,
        detailLineLimit: Int? = nil,
        isEnabled: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.accent = accent
        self.value = value
        self.detail = detail
        self.detailLineLimit = detailLineLimit
        self.isEnabled = isEnabled
        self.action = action
    }

    /// What VoiceOver reads. Pure, and therefore the testable part.
    ///
    /// `severity` leads because it changes how everything after it should be
    /// heard, and a screen reader user should not have to wait for the end of
    /// a three-line error to learn it was an error.
    ///
    /// `nonisolated`: `MenuRow` conforms to `View` whose only requirement,
    /// `body`, is `@MainActor`. Swift 6 infers that isolation onto every
    /// member of a type that conforms directly (not just `body`), which would
    /// otherwise make this pure string function unreachable from a plain,
    /// non-isolated `@Test func` without a runtime trap.
    nonisolated static func composedAccessibilityLabel(
        title: String, value: String?, detail: String?, severity: String? = nil
    ) -> String {
        [severity, title, value, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// What VoiceOver reads after the label. Also pure, also testable.
    ///
    /// A dimmed row tells a sighted user "this action exists but not right
    /// now". Without this, an unavailable action announces identically to a
    /// working one and the only feedback for activating it is silence.
    nonisolated static func composedAccessibilityValue(
        hasAction: Bool, isEnabled: Bool
    ) -> String {
        (hasAction && !isEnabled) ? "Unavailable" : ""
    }

    private var isInteractive: Bool { action != nil && isEnabled }

    private var accessibilityLabelText: String {
        Self.composedAccessibilityLabel(title: title, value: value, detail: detail,
                                        severity: accent?.spokenSeverity)
    }

    private var accessibilityValueText: String {
        Self.composedAccessibilityValue(hasAction: action != nil, isEnabled: isEnabled)
    }

    /// A row with an action is a real `Button`, not a tappable `Text` stack.
    /// A tap gesture is invisible to macOS Full Keyboard Access, so rows built
    /// that way drop out of the focus ring entirely — and with no keyboard
    /// shortcuts anywhere in this menu, keyboard access and VoiceOver are the
    /// only non-mouse routes into the app.
    ///
    /// `Button` supplies the `.isButton` trait and the disabled state itself,
    /// so neither is hand-applied any more. `.disabled(!isEnabled)` rather
    /// than dropping the Button keeps the earlier review's outcome intact: a
    /// disabled control still appears in VoiceOver's rotor, announced as
    /// dimmed and valued "Unavailable", which beats vanishing from the rotor
    /// and announcing as static text.
    ///
    /// A row with no action is a status line. It stays plain text and is
    /// deliberately not focusable.
    public var body: some View {
        if let action {
            Button(action: action) { rowContent }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityLabel(accessibilityLabelText)
                .accessibilityValue(accessibilityValueText)
        } else {
            rowContent
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabelText)
                .accessibilityValue(accessibilityValueText)
        }
    }

    private var rowContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let accent {
                // Sized to whichever line it sits beside: a title-less row is
                // all caption, and a body-sized glyph would tower over it.
                Image(systemName: accent.symbol)
                    .font(title.isEmpty ? .caption : nil)
                    .foregroundStyle(symbolColor(accent))
            }
            VStack(alignment: .leading, spacing: 1) {
                // An empty title (e.g. an error/notice row that is all detail)
                // must not render at all -- an empty `Text` still reserves a
                // full line above the caption.
                if !title.isEmpty {
                    Text(title)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .lineLimit(detailLineLimit)
                        .foregroundStyle(isHovering && isInteractive ? .white : .secondary)
                }
            }
            if let value, !value.isEmpty {
                Spacer(minLength: 8)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(isHovering && isInteractive ? .white : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Native metrics, measured off a real NSMenu -- see `MenuMetrics`.
        // `minHeight` rather than a fixed height: a two-line row (a status
        // detail, an error) is legitimately taller and must still be allowed
        // to grow, but a one-line row must land on exactly the native 24.
        .padding(.horizontal, MenuMetrics.textInset)
        .padding(.vertical, MenuMetrics.rowVerticalPadding)
        .frame(minHeight: MenuMetrics.rowHeight)
        .foregroundStyle(rowForeground)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering && isInteractive ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private func symbolColor(_ accent: Accent) -> Color {
        if isHovering && isInteractive { return .white }
        return accent.tint ?? rowForeground
    }

    /// A disabled row with an action is dimmed by `.buttonStyle(.plain)` +
    /// `.disabled` in `body` already -- measured at meanLum 0.820 / darkest
    /// 0.794 against a bare `.secondary`'s 0.663 / 0.574, and an isolated
    /// `Button { .secondary }.plain.disabled(true)` reproduces the row's
    /// numbers exactly. Returning `.secondary` here on top of that halved the
    /// ink strength again. A disabled row with NO action has no Button to dim
    /// it at all, so it still has to do its own dimming here.
    private var rowForeground: Color {
        if !isEnabled && action == nil { return .secondary }
        return isHovering && isInteractive ? .white : .primary
    }
}
