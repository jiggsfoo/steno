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

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}
