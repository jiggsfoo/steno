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
        MenuRow(Self.statusTitle(for: model.status), detail: statusDetail,
                lineLimit: statusDetailLineLimit)

        if case let .syncing(_, _, percent) = model.status {
            // Unlabelled, a ProgressView announces only a bare percentage --
            // no indication of what is at that percentage.
            ProgressView(value: Double(percent), total: 100)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
                .accessibilityLabel("Sync progress")
        }

        // Rendered regardless of status -- the idle-poll loop can notice a
        // recording start while the menu shows any connected/syncing state.
        if let recording = model.recordingInProgress {
            MenuRow(Self.recordingLabel(for: recording))
        }

        // Rendered regardless of status. Clock-drift warnings and "N recordings
        // failed to sync" were being written and never shown to anyone.
        if let error = model.lastError {
            MenuRow("", detail: error, lineLimit: 3)
        }

        // Neutral outcome, e.g. "Freed N recording(s) from the P1." -- a
        // fully-successful reclaim otherwise had no way to tell the user
        // anything happened at all.
        if let notice = model.lastNotice {
            MenuRow("", detail: notice, lineLimit: 3)
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

    private var statusDetailLineLimit: Int? {
        if case .unavailable = model.status { return 2 }
        return nil
    }

    // MARK: - Recent

    @ViewBuilder
    private var recentSection: some View {
        // The all-caps spelling is a visual convention for a menu section
        // header. VoiceOver should get the word and the header trait, not the
        // shouting -- an all-caps string is a candidate for being spelled out
        // letter by letter.
        Text("RECENT")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
            .accessibilityLabel("Recent")
            .accessibilityAddTraits(.isHeader)

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

    private func reveal(_ item: Sidecar) {
        let url = model.libraryRoot.appendingPathComponent(item.relativePath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

    /// GET_RECORDING_FILE's body layout beyond "empty means idle" is
    /// unverified, so a name containing anything other than printable ASCII
    /// is shown as a bare "Recording…" rather than risking mangled text.
    ///
    /// `nonisolated`: see `statusTitle(for:)` above.
    nonisolated static func recordingLabel(for filename: String) -> String {
        let sensible = !filename.isEmpty && filename.count < 48
            && filename.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
        return sensible ? "Recording: \(filename)" : "Recording…"
    }
}
