import AppKit
import StenoUI
import SwiftUI

/// `MenuBarExtra(.menuBarExtraStyle(.window))` builds its content closure
/// lazily — `.task` inside it does not run until the user opens the menu at
/// least once. Device discovery has to start at launch regardless of whether
/// anyone has ever clicked the icon, so `start()` is called from
/// `applicationDidFinishLaunching` instead, which fires unconditionally.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }
}

@main
struct StenoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: appDelegate.model)
        } label: {
            // Deliberately just a view reference: no model state is read HERE.
            // This closure is part of `App.body`, whose dependency tracking on
            // `@Observable` state is undocumented; `MenuBarIconLabel` does the
            // reading from a real `View.body`, where it is defined behaviour.
            MenuBarIconLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        // A regular Window, not `Settings { }`: `SettingsLink` has no hook to
        // activate the app first, and this is an LSUIElement (.accessory) app
        // that never activates on its own -- the window would open behind
        // every other app and be effectively invisible. MenuBarView activates
        // the app before calling openWindow(id: MenuBarView.settingsWindowID).
        Window("HiDock Settings", id: MenuBarView.settingsWindowID) {
            SettingsView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)

        // Reclaim is a window for a second reason on top of that one: a
        // `.sheet` presented from inside the `MenuBarExtra(.window)` popover
        // above cannot be dismissed reliably, because AppKit tears that popover
        // down as it loses focus to the sheet. See `MenuBarView.open(_:)`.
        // `Window` is single-instance, so opening it twice orders the existing
        // one front instead of stacking a second device read behind the first.
        Window("Free Up Space on P1", id: MenuBarView.reclaimWindowID) {
            ReclaimView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
    }
}
