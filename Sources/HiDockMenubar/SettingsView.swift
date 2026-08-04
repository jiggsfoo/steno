import SwiftUI

/// Not part of the Task 10 brief's code blocks — `HiDockApp.swift` references
/// `SettingsView(model:)` but the brief never defines it. Filled in here,
/// minimally: the one setting the app actually has is the library folder.
public struct SettingsView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            LabeledContent("Library folder") {
                Text(model.libraryRoot.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Button("Choose...") { chooseFolder() }
                Button("Rebuild index") { model.rebuildIndex() }
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.libraryRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.libraryRoot = url
    }
}
