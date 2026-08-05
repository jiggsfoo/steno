import ServiceManagement
import SwiftUI

public struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    /// Suppresses the onChange that the revert below would otherwise re-trigger,
    /// issuing a spurious opposite-direction register/unregister.
    @State private var isSyncingToggle = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            Section("Library") {
                HStack {
                    // The path is the only thing on this line, so on its own
                    // it announces as a bare path with no hint of what it is.
                    Text(model.libraryRoot.path)
                        .truncationMode(.middle).lineLimit(1)
                        .accessibilityLabel("Library folder")
                        .accessibilityValue(model.libraryRoot.path)
                    Spacer()
                    // "Change" alone says nothing about what it changes;
                    // VoiceOver reads a button without its neighbouring text.
                    Button("Change…") { chooseFolder() }
                        .accessibilityLabel("Change library folder")
                }
                Button("Rebuild Index") { model.rebuildIndex() }
                Button("Reveal Log in Finder") {
                    let log = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/HiDock/hidock.log")
                    NSWorkspace.shared.activateFileViewerSelecting([log])
                }
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard !isSyncingToggle else { return }
                        setLoginItem(enabled)
                    }
                    // SwiftUI's Settings scene can retain its root view across
                    // window open/close, so a change made in System Settings
                    // would otherwise leave this stale.
                    .onAppear { refreshLoginItemState() }
                if SMAppService.mainApp.status == .requiresApproval {
                    Text("Waiting for approval in System Settings > Login Items.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }

            if let error = model.lastError {
                Section("Last Error") {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.libraryRoot
        // LSUIElement apps are not activated by default, so without this the
        // panel can open behind the frontmost application.
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            model.libraryRoot = url
        }
    }

    private func refreshLoginItemState() {
        isSyncingToggle = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        isSyncingToggle = false
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            refreshLoginItemState()
        }
    }
}
