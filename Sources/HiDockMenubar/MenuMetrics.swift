import CoreGraphics

/// The metrics a real `NSMenu` lays itself out with.
///
/// `MenuBarExtra` stays `.window` style because `.menu` renders a real NSMenu
/// and cannot host the sync progress bar or a two-line row (see `MenuRow`).
/// That buys the layout freedom this app needs and costs it every metric AppKit
/// would otherwise have supplied -- so the numbers have to be brought back by
/// hand, and none of them are invented here.
///
/// Every value below was read off a real `NSMenu` built with plain
/// `NSMenuItem`s and a separator, popped up offscreen, and measured from the
/// laid-out view tree and its own drawing:
///
/// - `NSTableRowView` heights in the live menu: 24 for an item, 11 for a
///   separator, laid out edge to edge with no gap between them.
/// - `_NSMenuItemTextField.frame.origin.x` = 14 in every item, at every menu
///   width.
/// - The separator's drawn line, rastered out of its own item view: 1pt thick,
///   5pt down from the row top, spanning x 16 to width-16. Confirmed constant
///   at menu widths 58, 122 and 409 -- it is a fixed inset, not a ratio.
/// - An empty `NSMenu.size.height` of 10, i.e. 5 above the first row and 5
///   below the last.
/// - `NSFont.menuFont(ofSize: 0)` is 13pt, the same size as
///   `NSFont.preferredFont(forTextStyle: .body)`, which is what SwiftUI's
///   `.body` resolves to here -- so the rows already use the menu font.
///
/// `MenuMetricsTests` re-derives the item height, the separator height and the
/// font size from AppKit at run time and fails if these drift from them, and
/// measures the rendered menu's pixels against the rest.
enum MenuMetrics {
    /// Height of one menu item.
    static let rowHeight: CGFloat = 24

    /// Total vertical footprint of a separator, line and surrounding space.
    static let separatorHeight: CGFloat = 11

    /// Thickness of the separator's own line.
    static let separatorThickness: CGFloat = 1

    /// Space above and below the separator line, so the pair adds up to
    /// `separatorHeight`.
    static let separatorPadding: CGFloat = (separatorHeight - separatorThickness) / 2

    /// How far the separator line is inset from each edge of the menu. The
    /// most obvious tell of a hand-built menu: AppKit insets it, and a
    /// full-width `Divider` reads as wrong immediately next to a real one.
    static let separatorInset: CGFloat = 16

    /// Leading inset of an item's text from the edge of the menu.
    static let textInset: CGFloat = 14

    /// Space above the first row and below the last, as AppKit lays a real menu
    /// out: an empty `NSMenu.size.height` of 10, split evenly.
    /// `MenuMetricsTests` re-derives this from AppKit at run time.
    static let contentInset: CGFloat = 5

    /// What the popover actually pads its top and bottom edge by.
    ///
    /// **Three of these numbers are measured and the fourth is not.** A real
    /// `NSMenu` whose first item carries a two-line attributed title -- the same
    /// shape as our status row -- was popped up and rastered: it leaves 11.0pt
    /// between the top of the menu and the first pixel of ink, and 11.0pt below
    /// the last. This popover measured 11.0 / 10.5 at `contentInset`, i.e. it
    /// already matched AppKit.
    ///
    /// It still read as cramped against other menu bar apps, whose popovers are
    /// not `NSMenu`s and are more generous than one. **The extra 3pt is by eye,
    /// not measured** -- it is the one number on this type that AppKit did not
    /// supply. Applied to `.vertical`, so the bottom moves with the top and the
    /// popover stays balanced.
    static let popoverInset: CGFloat = contentInset + 3

    /// Gap between adjacent rows. AppKit lays menu rows edge to edge.
    static let rowSpacing: CGFloat = 0

    /// Space above and below a row's single line of text. A native item centres
    /// a 16pt label in its 24pt row; `.body` is that same 16pt line here, so
    /// this is what makes `rowHeight` come out of the layout rather than being
    /// imposed on it.
    static let rowVerticalPadding: CGFloat = 4
}
