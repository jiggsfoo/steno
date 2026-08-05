import AppKit
import HiDockMenubar
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
struct HiDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("HiDock", systemImage: "waveform.circle") {
            MenuBarView(model: appDelegate.model)
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
    }
}
