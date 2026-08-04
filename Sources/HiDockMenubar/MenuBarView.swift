import HiDockKit
import SwiftUI

public struct MenuBarView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusSection
            Divider()
            recentSection
            Divider()
            actionsSection
        }
        .padding(12)
        .frame(width: 260)
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.status {
        case .disconnected:
            Label("No device", systemImage: "circle")
                .foregroundStyle(.secondary)
        case let .connected(battery, freeMiB, capacityMiB):
            Label("P1 connected", systemImage: "circle.fill")
                .foregroundStyle(.green)
            Text("\(freeMiB / 1024) GB free of \(capacityMiB / 1024) GB")
                .font(.caption).foregroundStyle(.secondary)
            if let battery {
                Text("Battery \(battery)%").font(.caption).foregroundStyle(.secondary)
            }
        case let .syncing(done, total, percent):
            Label(total > 0 ? "Syncing \(done) of \(total)" : "Reading device",
                  systemImage: "arrow.down.circle")
            ProgressView(value: Double(percent), total: 100)
        case .busy:
            Label("P1 busy", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
            Text("Recording, or in Vibe Mic mode")
                .font(.caption).foregroundStyle(.secondary)
        case let .unavailable(detail):
            Label("P1 unavailable", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        Text("Recent").font(.caption).foregroundStyle(.secondary)
        if model.recent.isEmpty {
            Text("Nothing synced yet").font(.caption).foregroundStyle(.tertiary)
        } else {
            ForEach(model.recent, id: \.signature) { item in
                Button { reveal(item) } label: {
                    HStack {
                        Text(Self.dateLabel(item.recordedAt))
                        Spacer()
                        Text(Self.durationLabel(item.durationSeconds))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.open(model.libraryRoot)
        }
        SettingsLink { Text("Settings...") }
        Button("Quit HiDock") { NSApplication.shared.terminate(nil) }
    }

    private func reveal(_ item: Sidecar) {
        let url = model.libraryRoot.appendingPathComponent(item.relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func dateLabel(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let f = DateFormatter()
        f.dateFormat = "MMM d  HH:mm"
        return f.string(from: date)
    }

    private static func durationLabel(_ seconds: Double?) -> String {
        guard let seconds else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
