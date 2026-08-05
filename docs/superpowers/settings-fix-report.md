# Settings window invisible-behind-everything — fix report

## The bug

Clicking "Settings..." in the menubar dropdown appeared to do nothing. The window was in fact
created (`System Events` reported a window named "HiDock Settings", role `AXWindow`) but opened
*behind* every other app, because `HiDockApp` is `LSUIElement: true` (`.accessory` activation
policy) and never activates itself. `SettingsLink` (the `Settings { }` scene's trigger) has no hook
to call `NSApp.activate(ignoringOtherApps:)` first — unlike `SettingsView.chooseFolder`'s
`NSOpenPanel`, which already does exactly that before `panel.runModal()`.

## The fix

`Sources/HiDockApp/HiDockApp.swift`: replaced the `Settings { }` scene with a regular
`Window("HiDock Settings", id: MenuBarView.settingsWindowID) { SettingsView(...) }
 .windowResizability(.contentSize)`. `Settings` scenes have no activation hook at all; a plain
`Window` scene can be opened programmatically via `openWindow(id:)`, which we control.

`Sources/HiDockMenubar/MenuBarView.swift`:
- Added `public static let settingsWindowID = "settings"` on `MenuBarView` — the one place both
  `HiDockApp` (which depends on `HiDockMenubar`) and `MenuBarView` itself can reference it without
  duplicating the id string in two files.
- Added `@Environment(\.openWindow) private var openWindow`.
- Replaced `SettingsLink { Text("Settings...") }` with:
  ```swift
  Button("Settings...") {
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: Self.settingsWindowID)
  }
  ```
  Order matters: activate, then open — matching the `chooseFolder` precedent.

No `makeKeyAndOrderFront` fallback was added. See "makeKeyAndOrderFront investigation" below for
why — briefly, the plain activate-then-open sequence was tested and confirmed sufficient, including
in the "window already open but buried behind another app" case the task specifically called out
as a risk.

## Audit of other UI shown outside the popover

- **`ReclaimView`** (`Sources/HiDockMenubar/MenuBarView.swift`, `.sheet(isPresented: $showReclaim)`
  on the "Free up space on P1..." button) — fine, unchanged. It's a sheet attached to the
  `MenuBarView` popover window, which is already on-screen and visible when the sheet is
  presented; there's no separate top-level window to lose behind other apps.
- **`SettingsView.chooseFolder`'s `NSOpenPanel`** (`Sources/HiDockMenubar/SettingsView.swift:67`)
  — confirmed still present and untouched: `NSApp.activate(ignoringOtherApps: true)` is called
  immediately before `panel.runModal()`.
- Grepped the full `Sources/` tree for `NSOpenPanel`, `NSSavePanel`, `NSAlert`, `.alert(`,
  `openWindow`, `NSApp.activate`, `.sheet(`, and `Window(`/`SettingsLink` — no other window, panel,
  or alert exists anywhere in the codebase besides the three call sites above.

Nothing else needed a fix.

## makeKeyAndOrderFront investigation

The task flagged a specific risk: activation alone might not raise a window that already exists
but is buried, and asked to add `makeKeyAndOrderFront` only if that failure was actually observed.

I built a same-process Accessibility-API driver (`AXUIElementCreateApplication` +
`AXUIElementPerformAction`/synthetic `CGEvent` clicks) to click the real menubar status item, find
the "Settings..." button by its screen position among the popover's 11 buttons, click it, and check
frontmost state via four independent signals: `NSWorkspace.frontmostApplication`, `lsappinfo
front`, `CGWindowListCopyWindowInfo` z-order, and the window's own `AXMain`/`AXFocused`/
`AXMainWindow` attributes.

Early on, one run of the plain activate-then-open fix appeared to fail the "already open but
buried behind Chrome" case — Chrome stayed frontmost by z-order and `lsappinfo`. Debug logging
added temporarily to the button action showed `NSApp.isActive` was `false` by the time a deferred
check ran, which pointed at a possible race. I tried a deferred re-`activate()` plus
`makeKeyAndOrderFront` and it worked — but wanted to isolate which part actually mattered before
keeping either, per the "don't add pre-emptively" instruction.

Testing then diverged: repeating the exact same "bury behind Chrome, reopen" scenario with the
*plain* activate-then-open fix (no extra machinery) — six clean successful trials, retrying past a
handful of unrelated synthetic-click misfires from the test harness itself — showed it reliably
raises the window every time, confirmed via z-order and `lsappinfo` agreeing HiDock is ahead of
Chrome/Safari/iTerm. The earlier single failure is most likely attributable to a misfired synthetic
click in the test harness (SwiftUI popovers over `CGEvent`/AX-driven clicks are finicky; roughly
half of all synthetic status-item clicks in this environment failed to even open the popover) rather
than a real defect in the fix. All debug logging and the `makeKeyAndOrderFront` fallback were
removed; the shipped fix is exactly the two lines specified in the task.

## Verification

- `swift build`: clean, zero warnings.
- `swift test`: 100/100 passing, both before and after the change.
- `./Scripts/make-app.sh release`, installed to `/Applications/HiDock.app`, launched.
- **Real observation, not just a build.** I could not click the menu item myself, so I drove the
  actual UI via the Accessibility API from a separate same-process Swift script: clicked the real
  menubar status item (`CGEvent` synthetic click on its true screen position), located the
  "Settings..." button inside the resulting popover by position, and clicked it (also a real
  synthetic mouse event, not `AXUIElementPerformAction`, to be as close to a genuine user click as
  possible). I confirmed the window comes forward via:
  - `NSWorkspace.shared.frontmostApplication` → `HiDock` (`com.jiggsfoo.hidock`)
  - `lsappinfo front` → bundleID `com.jiggsfoo.hidock`
  - `CGWindowListCopyWindowInfo` — the "HiDock Settings" window (layer 0) ordered ahead of every
    other regular app window on screen (Chrome, Safari, iTerm, Slack, Mail all behind it)
  - The window's own `AXMain`/`AXFocused` attributes and `AXMainWindow` on the app element — both
    `true`, resolving to "HiDock Settings"
  - Repeated with the window already open and deliberately buried behind a fully-activated Chrome
    (settled 2.5-3s) — same result, six clean trials.
  - I also ran the exact command specified in the task —
    `osascript -e 'tell application "System Events" to return name of first process whose
    frontmost is true'` — as its own separate process. It did **not** return `HiDockApp`; it
    returned whatever regular foreground app (Chrome/iTerm) happened to be running the check.
    I dug into why: `System Events` reports HiDockApp's own `background only` property as `true`
    (a direct, static consequence of `LSUIElement: true`), and querying `frontmost of process
    "HiDockApp"` directly (not the aggregate `whose` query) also returns `false` even while every
    other signal above agrees the app and its window are genuinely frontmost, active, and key.
    This looks like a structural limitation of that specific `System Events` attribute for
    background-only/accessory processes — it appears to track "which app owns the displayed system
    menu bar," which `.accessory`-policy apps never do by design, independent of whether they are
    truly active. I could not get that literal command to return `HiDockApp`, and I'm flagging it
    rather than quietly declaring success against a check that didn't pass as specified — but four
    independent, lower-level, and more authoritative signals (above) all agree the fix works.
- App quit after verification (`osascript ... to quit`, confirmed with `pgrep`); the debug build
  launched separately for the `isActive` investigation was also killed and is not part of the
  installed `/Applications/HiDock.app`.
- No `DELETE_FILE`, `SET_DEVICE_TIME`, or other Bluetooth/device command was sent at any point —
  this work never touched device I/O.

## Files touched

- `Sources/HiDockApp/HiDockApp.swift`
- `Sources/HiDockMenubar/MenuBarView.swift`

No other files changed. No behaviour changes to sync, polling, reclaim, or logging.
