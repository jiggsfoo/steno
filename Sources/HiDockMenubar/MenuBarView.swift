import HiDockKit
import SwiftUI

public struct MenuBarView: View {
    /// Shared with `HiDockApp`, which declares the `Window(_:id:)` scene this
    /// opens. Defined here so the executable target can reference it without
    /// duplicating the id string.
    public static let settingsWindowID = "settings"

    @Bindable var model: AppModel
    @State private var showReclaim = false
    @Environment(\.openWindow) private var openWindow

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusSection
            Divider().padding(.vertical, 4)
            recentSection
            Divider().padding(.vertical, 4)
            actionsSection
        }
        .padding(.vertical, 6)
        .frame(width: 272)
        .sheet(isPresented: $showReclaim) { ReclaimView(model: model) }
    }

    // MARK: - Status

    /// `nonisolated`: a static member of a type inferred `@MainActor` (via its
    /// `View` conformance) is MainActor-isolated by default, which would force
    /// every caller — including the synchronous tests below — onto the main
    /// actor for no reason. This is a pure function with no actor-isolated
    /// state to protect. Same rationale as `MenuRow.composedAccessibilityLabel`
    /// and `AppModel.shouldSyncAfterPoll`.
    nonisolated static func statusTitle(for status: DeviceStatus) -> String {
        switch status {
        case .disconnected:                     return "No Device"
        case .connected:                        return "P1 Connected"
        case let .syncing(done, total, _):      return total > 0 ? "Syncing \(done) of \(total)"
                                                                : "Reading Device"
        case .busy:                             return "P1 Busy"
        case .unavailable:                      return "P1 Unavailable"
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        MenuRow(Self.statusTitle(for: model.status), detail: statusDetail)

        if case let .syncing(_, _, percent) = model.status {
            ProgressView(value: Double(percent), total: 100)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
        }

        if let recording = model.recordingInProgress {
            MenuRow(Self.recordingLabel(for: recording))
        }
        if let error = model.lastError {
            MenuRow("", detail: error)
        }
        if let notice = model.lastNotice {
            MenuRow("", detail: notice)
        }
    }

    private var statusDetail: String? {
        switch model.status {
        case let .connected(_, freeMiB, capacityMiB):
            let synced = model.recent.isEmpty ? "" : " · \(model.recent.count) recent"
            return "\(freeMiB / 1024) GB free of \(capacityMiB / 1024) GB\(synced)"
        case .busy:
            return "Recording, or in Vibe Mic mode"
        case let .unavailable(detail):
            return detail
        default:
            return nil
        }
    }

    // MARK: - Recent

    @ViewBuilder
    private var recentSection: some View {
        Text("RECENT")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

        if model.recent.isEmpty {
            MenuRow("", detail: "Nothing synced yet")
        } else {
            ForEach(model.recent, id: \.signature) { item in
                MenuRow(Self.dateLabel(item.recordedAt),
                        value: Self.durationLabel(item.durationSeconds)) {
                    reveal(item)
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        MenuRow("Sync Now", isEnabled: model.status != .disconnected) { model.syncNow() }
        MenuRow("Show in Finder") { NSWorkspace.shared.open(model.libraryRoot) }
        MenuRow("Free Up Space on P1…", isEnabled: model.status != .disconnected) {
            showReclaim = true
        }
        Divider().padding(.vertical, 4)
        // `SettingsLink` has no hook to activate the app first, and this is an
        // LSUIElement (.accessory) app that never activates on its own — the
        // window would open behind everything. Activate, then open.
        MenuRow("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: Self.settingsWindowID)
        }
        MenuRow("Quit HiDock") { NSApplication.shared.terminate(nil) }
    }
    // Keep the existing `.sheet(isPresented: $showReclaim)` attached to the
    // outermost VStack rather than to a MenuRow.

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

    // MARK: - Formatting

    /// `nonisolated`: see `statusTitle(for:)` above -- same rationale, tests
    /// call this synchronously from a nonisolated context.
    nonisolated static func dateLabel(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return dateFormatter.string(from: date)
    }

    /// `nonisolated`: see `statusTitle(for:)` above.
    nonisolated static func durationLabel(_ seconds: Double?) -> String {
        guard let seconds else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Fixed-format, so `en_US_POSIX` — the same reason `Library`'s formatters
    /// pin it. A non-Gregorian `Locale.current` would otherwise change this.
    ///
    /// `nonisolated`: `DateFormatter` is `Sendable`, so a plain `nonisolated`
    /// constant is enough for `dateLabel(_:)` above to read it synchronously
    /// -- no `(unsafe)` needed.
    nonisolated private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "MMM d  HH:mm"
        return f
    }()

    /// `nonisolated`: see `statusTitle(for:)` above.
    nonisolated static func recordingLabel(for filename: String) -> String {
        let sensible = filename.count < 48
            && filename.allSatisfy { $0.isASCII && !$0.isNewline }
        return sensible ? "Recording: \(filename)" : "Recording…"
    }
}
