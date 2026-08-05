import HiDockKit
import SwiftUI

public struct MenuBarView: View {
    @Bindable var model: AppModel
    @State private var showReclaim = false

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

        // Rendered regardless of status -- the idle-poll loop can notice a
        // recording start while the menu shows any connected/syncing state.
        if let recording = model.recordingInProgress {
            Label(Self.recordingLabel(for: recording), systemImage: "mic.fill")
                .foregroundStyle(.red)
        }

        // Rendered regardless of status. Clock-drift warnings and "N recordings
        // failed to sync" were being written and never shown to anyone.
        if let error = model.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
        }

        // Neutral outcome, e.g. "Freed N recording(s) from the P1." — a
        // fully-successful reclaim otherwise had no way to tell the user
        // anything happened at all.
        if let notice = model.lastNotice {
            Text(notice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
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
        Button("Sync now") { model.syncNow() }
            .disabled(model.status == .disconnected)
        Button("Reveal log") { revealLog() }
        Button("Free up space on P1...") { showReclaim = true }
            .disabled(model.status == .disconnected)
            .sheet(isPresented: $showReclaim) { ReclaimView(model: model) }
        SettingsLink { Text("Settings...") }
        Button("Quit HiDock") { NSApplication.shared.terminate(nil) }
    }

    private func reveal(_ item: Sidecar) {
        let url = model.libraryRoot.appendingPathComponent(item.relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The log may not exist yet (nothing has synced since the folder was
    /// last cleared), so the containing directory is created first --
    /// `activateFileViewerSelecting` on a nonexistent path is unreliable.
    private func revealLog() {
        let folder = DiagnosticLog.defaultURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.defaultURL])
    }

    private static func dateLabel(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let f = DateFormatter()
        // en_US_POSIX for the same reason Library's formatters set it: under a
        // non-Gregorian Locale.current the fixed format can render unexpected
        // digits/characters.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d  HH:mm"
        return f.string(from: date)
    }

    /// GET_RECORDING_FILE's body layout beyond "empty means idle" is
    /// unverified, so a name containing anything other than printable ASCII
    /// is shown as a bare "Recording..." rather than risking mangled text.
    private static func recordingLabel(for filename: String) -> String {
        let sensible = !filename.isEmpty
            && filename.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
        return sensible ? "Recording: \(filename)" : "Recording..."
    }

    private static func durationLabel(_ seconds: Double?) -> String {
        guard let seconds else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
