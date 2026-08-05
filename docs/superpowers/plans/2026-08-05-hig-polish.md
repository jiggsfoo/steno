# HiDock HIG Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the menu bar icon convey device state without opening the menu, make the popover look and behave like a native macOS menu, and give the app a VoiceOver-usable interface and a real icon.

**Architecture:** Two new files carry the work. `MenuBarIcon` is a pure mapping from app state to an `NSImage` plus an accessibility label. `MenuRow` is one reusable row that every menu item uses, owning hover, disabled appearance and accessibility. `MenuBarView` is rewritten to compose them. Nothing about sync, polling, reclaim or logging behaviour changes.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSImage`), CoreGraphics (icon generation), Swift Testing. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-08-05-hig-polish-design.md`

## Global Constraints

- `swift-tools-version: 6.0`, Swift 6 language mode, strict concurrency, **zero warnings**.
- Platform floor `.macOS(.v15)`.
- **Zero third-party dependencies.** Foundation, AppKit, CoreGraphics, SwiftUI, ServiceManagement, IOKit, IOUSBHost, SQLite3, AVFoundation, Testing only.
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), never XCTest.
- **No test may require an attached P1**, and **no test may write to `~/Library/Logs/HiDock/`.**
- **No behaviour changes.** Do not touch `SyncEngine`, `JensenDevice`, `Library`, `LibraryIndex`, `DeviceMonitor`, or any polling/retry/guard logic. This plan is presentation only.
- **Never send `DELETE_FILE`, `SET_DEVICE_TIME`, or any Bluetooth command.** The user has real recordings on the device and AirPods paired via BlueCatch.
- All user-facing strings use **Title Case** and the **U+2026 ellipsis character** (`…`), never three periods.
- **No keyboard shortcuts.** Deliberate — see the spec. Do not add them.
- Every task ends with a commit.

## Verified facts

Checked against this machine on 2026-08-05. Do not re-derive or "correct" from memory.

**SF Symbols that exist on macOS 27:** `waveform`, `waveform.slash`, `waveform.circle`, `waveform.badge.mic`, `waveform.badge.exclamationmark`, `waveform.badge.plus`, `waveform.badge.minus`, `waveform.badge.magnifyingglass`, `waveform.badge.checkmark`, `waveform.badge.xmark`, `waveform.and.mic`, `arrow.down.circle`, `record.circle`, `exclamationmark.triangle`, `mic.fill`.

**Do NOT exist:** `waveform.badge.arrow.down`, `waveform.arrow.down`, `waveform.badge.arrow.up`, `waveform.badge.clock`, `waveform.badge.questionmark`, `waveform.badge.gearshape`.

That absence is why the syncing state is composed rather than looked up.

## File structure

```
Sources/HiDockMenubar/
  MenuBarIcon.swift     NEW  state -> NSImage + accessibility label. Pure mapping, drawn compositing.
  MenuRow.swift         NEW  one menu row: label, trailing value, second line, hover, disabled, a11y.
  MenuBarView.swift     REWRITTEN to compose MenuRow. Ad-hoc Buttons removed.
  SettingsView.swift    MODIFIED  Title Case + "Reveal Log".

Sources/HiDockApp/
  HiDockApp.swift       MODIFIED  MenuBarExtra label driven by MenuBarIcon.
  Info.plist            MODIFIED  CFBundleIconFile.

Scripts/
  make-icon.swift       NEW  draws AppIcon.icns with CoreGraphics.
  make-app.sh           MODIFIED  generates + copies the icon.

Tests/HiDockMenubarTests/
  MenuBarIconTests.swift  NEW
  MenuRowTests.swift      NEW
  MenuBarViewTests.swift  NEW  (the existing date/duration formatters, currently uncovered)
```

---

### Task 1: MenuBarIcon

The menu bar icon is a static `waveform.circle` today, identical whether the P1 is absent, syncing, recording or broken. This is the largest miss in the spec and everything visible depends on it.

**Files:**
- Create: `Sources/HiDockMenubar/MenuBarIcon.swift`
- Test: `Tests/HiDockMenubarTests/MenuBarIconTests.swift`

**Interfaces:**
- Consumes: `DeviceStatus` (existing, in `AppModel.swift`), which has cases `.disconnected`, `.connected(battery:freeMiB:capacityMiB:)`, `.syncing(done:total:percent:)`, `.busy`, `.unavailable(String)`
- Produces: `enum MenuBarIcon`, `MenuBarIcon.State`, `MenuBarIcon.state(for:recording:) -> State`, `MenuBarIcon.symbolName(for:) -> String?`, `MenuBarIcon.accessibilityLabel(for:) -> String`, `MenuBarIcon.image(for:) -> NSImage`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/HiDockMenubarTests/MenuBarIconTests.swift
import AppKit
import Testing
@testable import HiDockMenubar

@Test func eachStatusMapsToItsOwnIconState() {
    #expect(MenuBarIcon.state(for: .disconnected, recording: nil) == .disconnected)
    #expect(MenuBarIcon.state(for: .connected(battery: nil, freeMiB: 1, capacityMiB: 2),
                              recording: nil) == .connected)
    #expect(MenuBarIcon.state(for: .syncing(done: 1, total: 2, percent: 50),
                              recording: nil) == .syncing)
    #expect(MenuBarIcon.state(for: .busy, recording: nil) == .attention)
    #expect(MenuBarIcon.state(for: .unavailable("x"), recording: nil) == .attention)
}

/// Recording is the most time-critical thing the icon can tell you, and it can
/// coincide with any other state. It must win.
@Test func recordingOverridesEveryOtherStatus() {
    let statuses: [DeviceStatus] = [
        .disconnected,
        .connected(battery: nil, freeMiB: 1, capacityMiB: 2),
        .syncing(done: 1, total: 2, percent: 50),
        .busy,
        .unavailable("x"),
    ]
    for status in statuses {
        #expect(MenuBarIcon.state(for: status, recording: "a.hda") == .recording)
    }
}

/// Every state must be distinguishable by SHAPE, not colour — that survives a
/// tinted menu bar and colour-blind vision. Distinct symbols (or a composed
/// image) per state is what guarantees it.
@Test func everyStateHasADistinctAppearance() {
    let all = MenuBarIcon.State.allCases
    let names = all.map { MenuBarIcon.symbolName(for: $0) ?? "composed-\($0)" }
    #expect(Set(names).count == all.count)
}

@Test func symbolNamesActuallyExistOnThisSystem() {
    for state in MenuBarIcon.State.allCases {
        guard let name = MenuBarIcon.symbolName(for: state) else { continue }
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "SF Symbol '\(name)' does not exist")
    }
}

/// The syncing state has no SF Symbol — `waveform.badge.arrow.down` does not
/// exist — so it is composed. This pins that fact.
@Test func syncingIsComposedBecauseNoSymbolExists() {
    #expect(MenuBarIcon.symbolName(for: .syncing) == nil)
    #expect(NSImage(systemSymbolName: "waveform.badge.arrow.down",
                    accessibilityDescription: nil) == nil)
}

@Test func everyStateProducesADistinctNonEmptyAccessibilityLabel() {
    let labels = MenuBarIcon.State.allCases.map { MenuBarIcon.accessibilityLabel(for: $0) }
    #expect(labels.allSatisfy { !$0.isEmpty })
    #expect(Set(labels).count == labels.count)
    #expect(labels.allSatisfy { $0.hasPrefix("HiDock") })
}

@Test func everyStateRendersAnImageWithTheAccessibilityLabelAttached() {
    for state in MenuBarIcon.State.allCases {
        let image = MenuBarIcon.image(for: state)
        #expect(image.size.width > 0 && image.size.height > 0)
        #expect(image.accessibilityDescription == MenuBarIcon.accessibilityLabel(for: state))
    }
}

/// Template images invert for light/dark and for a tinted menu bar. Recording
/// is deliberately NOT a template: red is meaningful there and must survive.
@Test func allStatesAreTemplateExceptRecording() {
    for state in MenuBarIcon.State.allCases where state != .recording {
        #expect(MenuBarIcon.image(for: state).isTemplate, "\(state) should be a template image")
    }
    #expect(MenuBarIcon.image(for: .recording).isTemplate == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MenuBarIconTests`
Expected: FAIL, `cannot find 'MenuBarIcon' in scope`

- [ ] **Step 3: Write `MenuBarIcon.swift`**

```swift
import AppKit

/// Maps app state to the menu bar's icon.
///
/// Every state is distinguished by SHAPE rather than colour, so the icon still
/// reads on a tinted menu bar and for a colour-blind user. Red appears only on
/// the recording state, where it reinforces a shape that already reads as
/// recording on its own.
public enum MenuBarIcon {

    public enum State: CaseIterable, Sendable {
        case disconnected
        case connected
        case syncing
        case recording
        case attention
    }

    /// Recording wins over everything else. It is the most time-critical thing
    /// the icon can communicate, and it can coincide with any other status.
    public static func state(for status: DeviceStatus, recording: String?) -> State {
        if recording != nil { return .recording }
        switch status {
        case .disconnected: return .disconnected
        case .connected: return .connected
        case .syncing: return .syncing
        case .busy, .unavailable: return .attention
        }
    }

    /// The SF Symbol for a state, or nil when it must be composed.
    ///
    /// Verified against macOS 27 on 2026-08-05. `waveform.badge.arrow.down`
    /// does NOT exist — nor does any waveform badge meaning "downloading" —
    /// which is why `.syncing` returns nil and is drawn instead.
    public static func symbolName(for state: State) -> String? {
        switch state {
        case .disconnected: return "waveform.slash"
        case .connected:    return "waveform"
        case .syncing:      return nil                              // composed
        case .recording:    return "waveform.badge.mic"
        case .attention:    return "waveform.badge.exclamationmark"
        }
    }

    public static func accessibilityLabel(for state: State) -> String {
        switch state {
        case .disconnected: return "HiDock: no device"
        case .connected:    return "HiDock: connected"
        case .syncing:      return "HiDock: syncing"
        case .recording:    return "HiDock: recording"
        case .attention:    return "HiDock: needs attention"
        }
    }

    private static let pointSize: CGFloat = 16

    public static func image(for state: State) -> NSImage {
        let image = symbolName(for: state).flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        } ?? composedSyncingImage()

        let configured = image.withSymbolConfiguration(
            .init(pointSize: pointSize, weight: .regular)) ?? image

        // Template images invert for light/dark and for a tinted menu bar.
        // Recording opts out so its red survives.
        configured.isTemplate = (state != .recording)
        configured.accessibilityDescription = accessibilityLabel(for: state)
        return configured
    }

    /// `waveform` with a small downward chevron drawn beside it.
    ///
    /// No SF Symbol conveys "downloading" on a waveform, so this is the one
    /// state that is drawn. Keeping the waveform means the silhouette stays
    /// recognisable across every state.
    private static func composedSyncingImage() -> NSImage {
        let size = NSSize(width: 20, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let base = NSImage(systemSymbolName: "waveform",
                                     accessibilityDescription: nil) else { return false }
            base.isTemplate = true
            base.draw(in: NSRect(x: 0, y: 1, width: 14, height: 14))

            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: rect.maxX - 4, y: rect.midY + 4))
            path.line(to: NSPoint(x: rect.maxX - 4, y: rect.midY - 3))
            path.move(to: NSPoint(x: rect.maxX - 6.6, y: rect.midY - 0.6))
            path.line(to: NSPoint(x: rect.maxX - 4, y: rect.midY - 3.2))
            path.line(to: NSPoint(x: rect.maxX - 1.4, y: rect.midY - 0.6))
            NSColor.black.setStroke()      // template mode recolours this
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MenuBarIconTests`
Expected: PASS, 7 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/HiDockMenubar/MenuBarIcon.swift Tests/HiDockMenubarTests/MenuBarIconTests.swift
git commit -m "feat(ui): menu bar icon that conveys device state"
```

---

### Task 2: MenuRow

The reusable row. This is where the HIG actually lives — hover, spacing, disabled appearance, the trailing value slot. Getting it right once makes every row right.

**Files:**
- Create: `Sources/HiDockMenubar/MenuRow.swift`
- Test: `Tests/HiDockMenubarTests/MenuRowTests.swift`

**Interfaces:**
- Produces: `struct MenuRow: View`, `MenuRow.init(_ title: String, value: String?, detail: String?, isEnabled: Bool, action: (() -> Void)?)`, and `MenuRow.composedAccessibilityLabel(title:value:detail:) -> String`

- [ ] **Step 1: Write the failing tests**

The rendering cannot be unit-tested without a snapshot dependency, which the spec excludes. The accessibility label composition is pure and is what VoiceOver actually reads, so that is what gets covered.

```swift
// Tests/HiDockMenubarTests/MenuRowTests.swift
import Testing
@testable import HiDockMenubar

@Test func labelIsJustTheTitleWhenThereIsNothingElse() {
    #expect(MenuRow.composedAccessibilityLabel(title: "Sync Now", value: nil, detail: nil)
            == "Sync Now")
}

/// VoiceOver would otherwise read "Today 13:00 66:24" as visual shorthand.
/// Joining with a comma makes it a sentence.
@Test func valueIsJoinedToTheTitleForVoiceOver() {
    #expect(MenuRow.composedAccessibilityLabel(title: "Today 13:00", value: "66:24", detail: nil)
            == "Today 13:00, 66:24")
}

@Test func detailIsAppendedAfterTheValue() {
    #expect(MenuRow.composedAccessibilityLabel(title: "Today 13:00", value: "66:24",
                                               detail: "48 MB")
            == "Today 13:00, 66:24, 48 MB")
}

@Test func emptyAndWhitespaceOnlyPartsAreSkipped() {
    #expect(MenuRow.composedAccessibilityLabel(title: "Sync Now", value: "", detail: "   ")
            == "Sync Now")
}

@Test func aRowIsNeverAnnouncedAsEmpty() {
    #expect(!MenuRow.composedAccessibilityLabel(title: "Quit HiDock", value: nil, detail: nil)
             .isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MenuRowTests`
Expected: FAIL, `cannot find 'MenuRow' in scope`

- [ ] **Step 3: Write `MenuRow.swift`**

```swift
import SwiftUI

/// One row of the menu.
///
/// `MenuBarExtra` stays `.window` style because `.menu` renders a real NSMenu
/// and cannot host the sync progress bar or a two-line row. That means the menu
/// *appearance* is hand-built, and this is where it lives — so it is built once
/// and every row inherits it.
///
/// `detail` is unused today. It exists because spec 2 adds transcript titles to
/// the recent rows, and a second line should be an extension rather than a
/// rewrite.
public struct MenuRow: View {
    private let title: String
    private let value: String?
    private let detail: String?
    private let isEnabled: Bool
    private let action: (() -> Void)?

    @State private var isHovering = false

    public init(
        _ title: String,
        value: String? = nil,
        detail: String? = nil,
        isEnabled: Bool = true,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.isEnabled = isEnabled
        self.action = action
    }

    /// What VoiceOver reads. Pure, and therefore the testable part.
    static func composedAccessibilityLabel(
        title: String, value: String?, detail: String?
    ) -> String {
        [title, value, detail]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var isInteractive: Bool { action != nil && isEnabled }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isHovering && isInteractive ? .white : .secondary)
                }
            }
            if let value, !value.isEmpty {
                Spacer(minLength: 8)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(isHovering && isInteractive ? .white : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(rowForeground)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering && isInteractive ? Color.accentColor : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if isInteractive { action?() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.composedAccessibilityLabel(
            title: title, value: value, detail: detail))
        .accessibilityAddTraits(isInteractive ? .isButton : [])
        .accessibilityRemoveTraits(isInteractive ? [] : .isButton)
    }

    private var rowForeground: Color {
        if !isEnabled { return .secondary }
        return isHovering && isInteractive ? .white : .primary
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MenuRowTests`
Expected: PASS, 5 tests

- [ ] **Step 5: Commit**

```bash
git add Sources/HiDockMenubar/MenuRow.swift Tests/HiDockMenubarTests/MenuRowTests.swift
git commit -m "feat(ui): reusable MenuRow with hover and accessibility"
```

---

### Task 3: Rewrite MenuBarView

**Files:**
- Modify: `Sources/HiDockMenubar/MenuBarView.swift`
- Modify: `Sources/HiDockApp/HiDockApp.swift`
- Test: `Tests/HiDockMenubarTests/MenuBarViewTests.swift`

**Interfaces:**
- Consumes: `MenuRow`, `MenuBarIcon`, `AppModel` (existing: `status`, `recent`, `recordingInProgress`, `lastError`, `lastNotice`, `libraryRoot`, `syncNow()`, `reclaimCandidates`)
- Produces: `MenuBarView.dateLabel(_:) -> String`, `MenuBarView.durationLabel(_:) -> String` (both already exist; made testable), and `MenuBarView.statusTitle(for:) -> String`

- [ ] **Step 1: Write the failing tests**

These formatters exist today with zero coverage.

```swift
// Tests/HiDockMenubarTests/MenuBarViewTests.swift
import Foundation
import Testing
@testable import HiDockMenubar

@Test func durationIsMinutesAndPaddedSeconds() {
    #expect(MenuBarView.durationLabel(4.464) == "0:04")
    #expect(MenuBarView.durationLabel(397.0) == "6:37")
    #expect(MenuBarView.durationLabel(3984.0) == "66:24")
}

@Test func durationHandlesMissingValue() {
    #expect(MenuBarView.durationLabel(nil) == "--:--")
}

@Test func dateHandlesMissingValue() {
    #expect(MenuBarView.dateLabel(nil) == "Unknown")
}

/// The formatter must be fixed-format, not locale-dependent — the same reason
/// Library's formatters pin en_US_POSIX.
@Test func dateFormatIsStableRegardlessOfLocale() {
    var components = DateComponents()
    components.year = 2026; components.month = 8; components.day = 5
    components.hour = 13; components.minute = 0
    let date = Calendar(identifier: .gregorian).date(from: components)!
    let label = MenuBarView.dateLabel(date)
    #expect(label.contains("13:00"))
    #expect(label.contains("Aug"))
}

@Test func everyStatusHasANonEmptyTitle() {
    let statuses: [DeviceStatus] = [
        .disconnected,
        .connected(battery: nil, freeMiB: 1, capacityMiB: 2),
        .syncing(done: 1, total: 2, percent: 50),
        .busy,
        .unavailable("boom"),
    ]
    for status in statuses {
        #expect(!MenuBarView.statusTitle(for: status).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MenuBarViewTests`
Expected: FAIL — `dateLabel`/`durationLabel` are `private`, `statusTitle` does not exist

- [ ] **Step 3: Rewrite the view**

Replace the whole body of `MenuBarView.swift` with the following, keeping the existing `settingsWindowID`, `init`, `reveal(_:)` and `revealLog()` helpers where they already work.

```swift
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
    }

    // MARK: - Status

    static func statusTitle(for status: DeviceStatus) -> String {
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

    // MARK: - Formatting

    static func dateLabel(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return dateFormatter.string(from: date)
    }

    static func durationLabel(_ seconds: Double?) -> String {
        guard let seconds else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Fixed-format, so `en_US_POSIX` — the same reason `Library`'s formatters
    /// pin it. A non-Gregorian `Locale.current` would otherwise change this.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "MMM d  HH:mm"
        return f
    }()

    static func recordingLabel(for filename: String) -> String {
        let sensible = filename.count < 48
            && filename.allSatisfy { $0.isASCII && !$0.isNewline }
        return sensible ? "Recording: \(filename)" : "Recording…"
    }
}
```

Attach the reclaim sheet to the outer `VStack`:

```swift
        .frame(width: 272)
        .sheet(isPresented: $showReclaim) { ReclaimView(model: model) }
```

- [ ] **Step 4: Drive the menu bar label from `MenuBarIcon`**

In `Sources/HiDockApp/HiDockApp.swift`, replace the fixed `systemImage:` with the state-driven image:

```swift
        MenuBarExtra {
            MenuBarView(model: appDelegate.model)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: MenuBarIcon.state(
                for: appDelegate.model.status,
                recording: appDelegate.model.recordingInProgress)))
        }
        .menuBarExtraStyle(.window)
```

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS — 100 existing plus the new MenuBarIcon, MenuRow and MenuBarView tests

- [ ] **Step 6: Build and look at it**

```bash
./Scripts/make-app.sh release
pkill -f HiDockApp; open build/HiDock.app
```
Confirm the menu opens, rows highlight on hover, and the icon is no longer `waveform.circle`. Quit it afterwards.

- [ ] **Step 7: Commit**

```bash
git add Sources/HiDockMenubar/MenuBarView.swift Sources/HiDockApp/HiDockApp.swift Tests/HiDockMenubarTests/MenuBarViewTests.swift
git commit -m "feat(ui): rebuild the popover as a native-style menu"
```

---

### Task 4: Settings text and Reveal Log

**Files:**
- Modify: `Sources/HiDockMenubar/SettingsView.swift`

**Interfaces:**
- Consumes: `AppModel.rebuildIndex()`, `AppModel.libraryRoot` (both existing)

- [ ] **Step 1: Move "Reveal Log" into Settings and fix the copy**

"Reveal Log" is a diagnostic, not a daily action. Move the button out of the menu (Task 3 already dropped it) and into Settings, and bring every label to Title Case with a real ellipsis.

In `SettingsView.swift`:
- `"Change..."` → `"Change…"`
- `"Rebuild index"` → `"Rebuild Index"`
- `"Launch at login"` → `"Launch at Login"`
- `"Last error"` → `"Last Error"`
- Add, in the Library section under "Rebuild Index":

```swift
                Button("Reveal Log in Finder") {
                    let log = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/HiDock/hidock.log")
                    NSWorkspace.shared.activateFileViewerSelecting([log])
                }
```

- [ ] **Step 2: Verify no three-period ellipsis survives anywhere**

Run: `grep -rn '\.\.\.' Sources/ --include=*.swift | grep -v '^\s*//'`
Expected: no matches in user-facing string literals. Comments and variadics are fine.

- [ ] **Step 3: Build and check Settings opens and reads correctly**

```bash
swift build && ./Scripts/make-app.sh release
pkill -f HiDockApp; open build/HiDock.app
```
Open Settings from the menu. Confirm it comes to the front, every label is Title Case, and "Reveal Log in Finder" opens the log's folder. Quit afterwards.

- [ ] **Step 4: Commit**

```bash
git add Sources/HiDockMenubar/SettingsView.swift
git commit -m "feat(ui): Title Case throughout, move Reveal Log into Settings"
```

---

### Task 5: App icon

**Files:**
- Create: `Scripts/make-icon.swift`
- Modify: `Scripts/make-app.sh`
- Modify: `Sources/HiDockApp/Info.plist`

- [ ] **Step 1: Write the icon generator**

Graphite gradient with the same white waveform as the menu bar icon, so app and status read as one product.

```swift
#!/usr/bin/env swift
// Scripts/make-icon.swift
// Draws AppIcon.icns. No binary asset is committed; the icon is reproducible
// from source. Usage: swift Scripts/make-icon.swift <output-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        // Rounded-rect graphite background, matching macOS icon geometry.
        let radius = size * 0.2237
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.addClip()
        NSGradient(starting: NSColor(calibratedRed: 0.29, green: 0.29, blue: 0.32, alpha: 1),
                   ending:   NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.15, alpha: 1))?
            .draw(in: rect, angle: -70)

        // Waveform: five rounded bars, symmetric about the centre.
        let heights: [CGFloat] = [0.17, 0.42, 0.62, 0.34, 0.11]
        let barWidth = size * 0.077
        let gap = size * 0.153
        let totalWidth = CGFloat(heights.count - 1) * gap
        NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
        for (i, h) in heights.enumerated() {
            let x = rect.midX - totalWidth / 2 + CGFloat(i) * gap
            let bar = NSBezierPath()
            bar.lineWidth = barWidth
            bar.lineCapStyle = .round
            bar.move(to: NSPoint(x: x, y: rect.midY - size * h))
            bar.line(to: NSPoint(x: x, y: rect.midY + size * h))
            bar.stroke()
        }
        return true
    }
    return image
}

func write(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try png.write(to: url)
}

// The exact set `iconutil` requires.
let sizes: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),
                           (256,1),(256,2),(512,1),(512,2)]
for (pt, scale) in sizes {
    let px = CGFloat(pt * scale)
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try write(draw(size: px), to: iconset.appendingPathComponent(name))
}
print("wrote \(iconset.path)")
```

- [ ] **Step 2: Generate and convert**

```bash
swift Scripts/make-icon.swift build
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
ls -la build/AppIcon.icns
```
Expected: an `.icns` of roughly 100–400 KB.

- [ ] **Step 3: Look at it before wiring it in**

```bash
open build/AppIcon.icns
```
Confirm it reads as a waveform on graphite at both large and small sizes. If the bars look cramped or the corner radius wrong, adjust `heights`/`gap`/`radius` and regenerate before continuing.

- [ ] **Step 4: Wire it into the bundle**

In `Sources/HiDockApp/Info.plist`, add inside the top-level `<dict>`:

```xml
    <key>CFBundleIconFile</key><string>AppIcon</string>
```

In `Scripts/make-app.sh`, after the executable is copied and before `codesign`:

```bash
swift "$ROOT/Scripts/make-icon.swift" "$ROOT/build"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
```

- [ ] **Step 5: Rebuild and confirm the icon appears**

```bash
./Scripts/make-app.sh release
ls -la build/HiDock.app/Contents/Resources/AppIcon.icns
```
Then install and check it renders:
```bash
pkill -f HiDockApp
rm -rf /Applications/HiDock.app && cp -R build/HiDock.app /Applications/HiDock.app
codesign --force --deep --sign - /Applications/HiDock.app
open -R /Applications/HiDock.app
```
Confirm Finder shows the graphite waveform rather than a generic placeholder. Quit any running instance afterwards.

- [ ] **Step 6: Commit**

```bash
git add Scripts/make-icon.swift Scripts/make-app.sh Sources/HiDockApp/Info.plist
git commit -m "feat(ui): generate and bundle the app icon"
```

---

### Task 6: Accessibility and Dynamic Type verification

The point of the whole spec. With no keyboard shortcuts and no app menu, VoiceOver is the only non-mouse route into this app, so this is load-bearing rather than decorative.

**Files:**
- Modify: whichever of `MenuBarView.swift` / `MenuRow.swift` / `SettingsView.swift` the checks below expose

- [ ] **Step 1: Confirm every interactive element has a label**

Run: `grep -rn "accessibilityLabel\|accessibilityElement" Sources/HiDockMenubar/*.swift`
Expected: `MenuRow` supplies one for every row; `MenuBarIcon` attaches one to every image. If any control in `SettingsView` or `ReclaimView` has no label and no self-describing `Text`, add one.

- [ ] **Step 2: VoiceOver pass**

Turn VoiceOver on (⌘F5), open the menu, and arrow through it. Confirm each item is announced meaningfully — a recent recording should read like "Aug 5 13:00, 66:24" and not "Aug 5 13:00 66 colon 24". Confirm the menu bar icon announces its state.

Report exactly what was heard for: the icon, one recent row, and one disabled action. If VoiceOver cannot be enabled in this environment, say so plainly rather than claiming the check.

- [ ] **Step 3: Dynamic Type pass**

Set System Settings → Accessibility → Display → Text Size to the largest setting, reopen the menu, and confirm the popover grows rather than clipping. Fix by removing any fixed `height` and letting the `VStack` size itself; the `width: 272` may stay.

- [ ] **Step 4: Capture each icon state**

The icon cannot be unit-tested in a live menu bar. Force each state and capture it:

```bash
swift -e '
import AppKit
@testable import HiDockMenubar
' 2>/dev/null || true
```
If direct forcing is impractical, drive it against real hardware instead — unplug the P1 (disconnected), plug it in (connected then syncing), start a recording (recording) — and capture the menu bar each time with `screencapture -R`. Report which states were observed and which were not. **Do not claim a state you did not see.**

- [ ] **Step 5: Full verification**

```bash
swift build     # clean, zero warnings
swift test      # all passing
./Scripts/make-app.sh release
```
Confirm all recordings are still on the device with `swift run hidock-cli list`, and that `~/Library/Logs/HiDock/` was not written to by the test run.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "fix(a11y): labels and Dynamic Type from the VoiceOver pass"
```

---

## Self-review

**Spec coverage**

| Spec requirement | Task |
|---|---|
| Title Case throughout | 3, 4 |
| U+2026 ellipsis | 3, 4 (verified by grep in 4) |
| No keyboard shortcuts | 3 (none added; constraint states it) |
| Accessibility labels on every control | 2, 6 |
| Menu bar icon conveys state | 1, 3 |
| Recording takes precedence | 1 |
| State distinguished by shape, not colour | 1 |
| App icon, generated not committed | 5 |
| "Reveal Log" moves to Settings | 3 (removed), 4 (added) |
| Native menu appearance, hover | 2, 3 |
| `.window` style retained, progress bar kept | 3 |
| `MenuRow` takes an optional second line for spec 2 | 2 (`detail:`) |
| Dynamic Type | 6 |
| No behaviour changes | Global constraints; no task touches sync/protocol code |
| No snapshot tests | None added |

**Placeholder scan:** clean. Every code step contains complete code. Task 6's steps 2–4 are manual checks with explicit instructions to report what was and was not observed rather than assume.

**Type consistency:** `MenuBarIcon.State` is used identically in Tasks 1 and 3. `MenuRow.init(_:value:detail:isEnabled:action:)` is used with exactly those labels in Task 3. `MenuBarView.dateLabel`/`durationLabel`/`statusTitle` are `static` in both the tests and the implementation. `DeviceStatus` cases match the existing definition in `AppModel.swift`.

**Known deviation from the mockup:** the approved mockup showed the syncing state as "waveform + down arrow" and recording as "waveform + red dot". `waveform.badge.arrow.down` does not exist on macOS 27 (verified), so syncing is composed by drawing. Recording uses `waveform.badge.mic` rendered non-template so its colour survives, rather than a literal dot. Both keep the shared waveform silhouette and remain distinguishable by shape, which was the actual design principle.
