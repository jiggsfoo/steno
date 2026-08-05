import SwiftUI

/// The menu bar's icon, as a real `View`.
///
/// This exists for one reason: `MenuBarExtra`'s `label:` closure is evaluated
/// as part of `App.body`, not a `View.body`. Reading `@Observable` state from
/// a `View` body is the documented path for registering a dependency and
/// getting invalidated when it changes; whether an `App` body does the same,
/// and whether SwiftUI re-renders an already-installed `NSStatusItem` when it
/// does, is not documented and cannot be observed headlessly — there is no
/// display here to watch. If it does not, the icon pins to whatever state the
/// app launched in and the whole point of the icon quietly does nothing while
/// every test still passes.
///
/// So the state read moves here, where the rules are known. Same failure shape
/// as the `MenuBarExtra(.window)` lazy-content bug that kept `.task` from ever
/// running until someone clicked the menu: the fix in both cases is to stop
/// depending on behaviour SwiftUI never promised.
///
/// A plain `let` rather than `@Bindable`: nothing here writes to the model, and
/// Observation tracks the *access* inside `body`, not the property wrapper.
public struct MenuBarIconLabel: View {
    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        let state = MenuBarIcon.state(for: model.status,
                                      recording: model.recordingInProgress)
        // The NSImage carries `accessibilityDescription`, but SwiftUI does not
        // reliably promote that to the accessibility label of an
        // `Image(nsImage:)` -- an unlabelled image is treated as decorative.
        // Stating it here means the icon announces its state whichever of the
        // two the status item ends up exposing.
        Image(nsImage: MenuBarIcon.image(for: state))
            .accessibilityLabel(MenuBarIcon.accessibilityLabel(for: state))
    }
}
