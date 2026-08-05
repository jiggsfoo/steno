import SwiftUI

/// One row of the menu.
///
/// `MenuBarExtra` stays `.window` style because `.menu` renders a real NSMenu
/// and cannot host the sync progress bar or a two-line row. That means the menu
/// *appearance* is hand-built, and this is where it lives — so it is built once
/// and every row inherits it.
///
/// `detail` is unused today. It exists because spec 2 adds transcript titles to
/// the recent rows, and a second line should be an extension rather than a
/// rewrite.
public struct MenuRow: View {
    private let title: String
    private let value: String?
    private let detail: String?
    private let lineLimit: Int?
    private let isEnabled: Bool
    private let action: (() -> Void)?

    @State private var isHovering = false

    public init(
        _ title: String,
        value: String? = nil,
        detail: String? = nil,
        lineLimit: Int? = nil,
        isEnabled: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.lineLimit = lineLimit
        self.isEnabled = isEnabled
        self.action = action
    }

    /// What VoiceOver reads. Pure, and therefore the testable part.
    ///
    /// `nonisolated`: `MenuRow` conforms to `View` whose only requirement,
    /// `body`, is `@MainActor`. Swift 6 infers that isolation onto every
    /// member of a type that conforms directly (not just `body`), which would
    /// otherwise make this pure string function unreachable from a plain,
    /// non-isolated `@Test func` without a runtime trap.
    nonisolated static func composedAccessibilityLabel(
        title: String, value: String?, detail: String?
    ) -> String {
        [title, value, detail]
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

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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
                        .lineLimit(lineLimit)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(rowForeground)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering && isInteractive ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if isInteractive { action?() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.composedAccessibilityLabel(
            title: title, value: value, detail: detail))
        .accessibilityValue(Self.composedAccessibilityValue(
            hasAction: action != nil, isEnabled: isEnabled))
        .accessibilityAddTraits(isInteractive ? .isButton : [])
        .accessibilityRemoveTraits(isInteractive ? [] : .isButton)
    }

    private var rowForeground: Color {
        if !isEnabled { return .secondary }
        return isHovering && isInteractive ? .white : .primary
    }
}
