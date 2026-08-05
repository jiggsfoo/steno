# HiDock menubar app: HIG polish (spec 1.5)

- **Date:** 2026-08-05
- **Status:** approved, ready for implementation planning
- **Scope:** visual and accessibility polish of the shipped app. No behaviour changes.
- **Sits between:** spec 1 (foundation, shipped) and spec 2 (transcription + AI filing).

## Context

The app works and is in daily use: it syncs recordings off the P1 byte-exact, notices
recordings made while docked, and never deletes anything. But the UI was built to be
correct rather than to be looked at, and it shows.

An audit against Apple's Human Interface Guidelines found the following. Everything here
was read from the actual source, not assumed.

**Mechanical violations**

- Sentence case on controls ("Sync now", "Reveal log", "Free up space on P1...") where
  macOS uses Title Case. iOS uses sentence case; macOS does not.
- `"..."` (three periods) instead of the ellipsis character `…` (U+2026).
- No keyboard shortcuts anywhere.
- No `accessibilityLabel` on any control. VoiceOver reads visual shorthand.
- No app icon, so Login Items, Finder and the Settings window show a generic placeholder.

**Structural problems**

- The menu bar icon is a static `waveform.circle` in every state. Whether the P1 is
  absent, syncing, recording or broken, the icon is identical — so the menu must be
  opened to learn anything at all. This is the largest single miss.
- The popover is assembled rather than designed: recent items are `.plain` buttons with
  no hover feedback, action items are default-styled buttons, and six ungrouped actions
  stack vertically. It reads as a debug panel.

## Goals

1. The menu bar icon conveys device state without opening the menu.
2. The popover looks and behaves like a native macOS menu.
3. VoiceOver can describe every control and every state.
4. Nothing about sync, polling, reclaim or logging behaviour changes.

## Non-goals

- No library window. Spec 1 deferred that until transcripts exist; that still holds.
- No snapshot testing — it needs a dependency and would pin pixels spec 2 will move.
- No App Store readiness, notarization, Help menu, or About window.
- No new device commands. This spec touches no protocol code.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Full polish now, not just compliance | Angelo's call, made knowing spec 2 will revisit the recent rows. `MenuRow` is built to absorb that. |
| 2 | Native menu appearance (chosen from three mockups) | Behaves like every other menubar app; least likely to feel dated. Rejected: a richer status panel, and a compact variant. |
| 3 | Keep `.menuBarExtraStyle(.window)` | `.menu` would give hover and shortcuts free, but renders a real `NSMenu` and cannot host the sync `ProgressView` or two-line rows. The menu *look* is therefore hand-built. |
| 4 | One shared icon silhouette; only the right-hand element changes | Distinguishes state by **shape**, so it survives a tinted menu bar and colour-blind vision. Rejected: a different symbol per state (silhouette jumps, hard to locate) and a coloured status dot (encodes state in colour alone, which HIG explicitly warns against). |
| 5 | Graphite app icon sharing the waveform | Ties the app and its menu bar status into one product, and matches the P1's dark aluminium. Rejected a record-disc icon: it would be indistinguishable from the menu bar's *recording* state. |
| 6 | "Reveal Log" moves from the menu into Settings | It is a diagnostic, not a daily action. |

## Menu structure

```
┌─────────────────────────────────┐
│ ● P1 connected                  │   status: symbol + text, never colour alone
│   58 GB free · 10 synced        │
├─────────────────────────────────┤
│ RECENT                          │
│ Today 13:00              66:24  │   hover highlight; click reveals in Finder
│ Today 12:00              57:15  │
│ Today 11:28               0:03  │
├─────────────────────────────────┤
│ Sync Now                    ⌘R  │
│ Show in Finder             ⌘⇧R  │
│ Free Up Space on P1…            │
├─────────────────────────────────┤
│ Settings…                    ⌘, │
│ Quit HiDock                  ⌘Q │
└─────────────────────────────────┘
```

All labels Title Case; all ellipses U+2026.

**Keyboard shortcuts fire only while the popover is open.** An accessory app
(`LSUIElement`) has no menu bar of its own, so there is nowhere to register a global ⌘Q
or ⌘,. This is a platform constraint, documented here so it is not later mistaken for a
defect.

## Menu bar icon

| State | Icon | Accessibility label |
|---|---|---|
| Disconnected | waveform, dimmed | "HiDock: no device" |
| Connected, idle | waveform | "HiDock: connected" |
| Syncing | waveform + down arrow | "HiDock: syncing" |
| Recording | waveform + red dot | "HiDock: recording" |
| Busy / unavailable | waveform + exclamation | "HiDock: needs attention" |

Recording takes precedence over every other state when both apply.

**Unverified dependency.** The intent is to compose these from SF Symbols
(`waveform`, `waveform.slash`, `waveform.badge.exclamationmark` and similar). **Which of
those exist on macOS 27 has not been checked.** The implementation must verify the symbol
names against the running system before building on them, and fall back to drawing
template images with CoreGraphics if the family is incomplete. Either route produces the
same five silhouettes; only the drawing code differs.

## App icon

Graphite gradient background, white waveform, matching the menu bar silhouette.

Generated by `Scripts/make-icon.swift`, which draws with CoreGraphics, writes a full
`.iconset` (16pt–1024pt, @1x and @2x), and calls `iconutil` to produce `AppIcon.icns`.
`make-app.sh` copies it to `Contents/Resources/` and `Info.plist` gains
`CFBundleIconFile`.

No binary asset is committed; the icon is reproducible from source.

## Components

| File | Responsibility |
|---|---|
| `Sources/HiDockMenubar/MenuRow.swift` *(new)* | One menu row: label, optional trailing text, optional second line, hover state, disabled state, accessibility label. Every menu item uses it. |
| `Sources/HiDockMenubar/MenuBarIcon.swift` *(new)* | Pure mapping from `(DeviceStatus, recordingInProgress)` to symbol name and accessibility label, plus the image builder. |
| `Sources/HiDockMenubar/MenuBarView.swift` | Rewritten to compose `MenuRow`s. Ad-hoc buttons removed. |
| `Sources/HiDockMenubar/SettingsView.swift` | Gains "Reveal Log"; labels corrected to Title Case. |
| `Sources/HiDockApp/HiDockApp.swift` | Menu bar label driven by `MenuBarIcon` rather than a fixed `systemImage`. |
| `Scripts/make-icon.swift` *(new)* | Draws and emits `AppIcon.icns`. |
| `Scripts/make-app.sh` | Copies the icon into the bundle. |

`MenuRow` is where the HIG actually lives — hover, spacing, disabled appearance, trailing
shortcut. Getting it right once makes every row right. It takes an optional second line
from the outset so spec 2's transcript titles are an extension rather than a rewrite.

## Accessibility

The current app has none of this; it is the substance of "following the HIG".

- **Every row carries an explicit `accessibilityLabel`.** A recent item announces
  "Today 13:00, 66 minutes 24 seconds, recording" rather than the visual shorthand
  VoiceOver would otherwise read as "Today 13:00 66:24".
- **The menu bar icon announces its state**, per the table above. It currently announces
  nothing useful.
- **No state is conveyed by colour alone.** Each status already carries a distinct symbol
  and its own text; the coloured dot is reinforcement.
- **Dynamic Type**: existing `.caption`/`.body` styles already scale. Verify the popover
  grows rather than clipping at the largest accessibility sizes.

## Testing

**Testable, and will be tested:**
- `MenuBarIcon.symbol(for:recording:)` — every status maps to the expected symbol, and
  recording takes precedence when combined with any other state.
- `MenuBarIcon.accessibilityLabel(for:recording:)` — every state yields a distinct,
  non-empty label.
- `MenuBarView.dateLabel(_:)` and `durationLabel(_:)` — existing formatters with no
  coverage today, including nil inputs.

**Not testable, verified by hand and reported honestly:**
- Hover highlight, popover dismissal, live rendering.
- The icon actually changing in a running menu bar — verified by forcing each state and
  capturing it, the same way the Settings-window activation was verified.

**Explicitly excluded:** snapshot tests.

## Risks

1. **The SF Symbol family may be incomplete on macOS 27.** Fallback is CoreGraphics
   template images: more code, identical result. Must be verified before building.
2. **Spec 2 will revisit the recent rows.** `MenuRow`'s optional second line is the
   mitigation; accepted knowingly when full polish was chosen over compliance-only.
3. **Keyboard shortcuts are popover-scoped only.** Documented above; not a defect.

## Build order

1. `MenuBarIcon` — pure mapping plus tests. Verify SF Symbol availability first and
   record what was found.
2. `MenuRow` — the reusable row, with hover, disabled and accessibility.
3. `MenuBarView` rewritten on top of both.
4. `SettingsView` text and "Reveal Log".
5. `Scripts/make-icon.swift` and the `make-app.sh` change.
6. Hand verification: each icon state captured, VoiceOver pass, Dynamic Type pass.
