import AppKit
import SwiftUI
import Testing
@testable import HiDockMenubar

/// `MenuBarIconLabel` exists so the menu bar icon's state read happens inside
/// a real `View.body`, where Observation's invalidation contract is defined —
/// rather than inside `App.body`, where it is not (see the type's own doc
/// comment). Before this test, it had zero coverage: every other icon test in
/// this target goes through `MenuBarIcon` directly, so a `MenuBarIconLabel`
/// that read the wrong property, or ignored `model` entirely and always drew
/// `.disconnected`, would leave every existing test green.
///
/// What this proves: given different `AppModel` states, the view produces
/// different pixels — i.e. it maps state to image correctly. What it does
/// NOT prove, and cannot: that a live `NSStatusItem` actually repaints when
/// `AppModel.status` changes later. There is no display in this environment,
/// no way to watch a real status item, and no snapshot dependency in play —
/// `ImageRenderer` renders headlessly here, confirmed empirically, which is
/// what makes this test possible without one. Nobody should read a pass here
/// as proof the icon updates live; that still needs a human at a real menu
/// bar (see `docs/superpowers/follow-ups.md`).
@MainActor
@Test func menuBarIconLabelDrawsDifferentPixelsForDifferentDeviceStatus() {
    // One status per distinct icon state `MenuBarIcon.state(for:recording:)`
    // maps to when nothing is recording. `.busy` and `.unavailable` are
    // deliberately excluded together -- both legitimately map to the same
    // `.attention` icon, so including both would make this test assert a
    // collision that is correct, not a defect. `.busy` stands in for that
    // shared state; `recordingInProgress` can't be set from outside `AppModel`
    // (private(set)), so the `.recording` icon isn't reachable here.
    let statuses: [DeviceStatus] = [
        .disconnected,
        .connected(battery: nil, freeMiB: 1, capacityMiB: 2),
        .syncing(done: 1, total: 2, percent: 50),
        .busy,
    ]

    let renders = statuses.map { status -> Data? in
        let model = AppModel()
        model.status = status
        return renderedTIFF(of: MenuBarIconLabel(model: model))
    }

    for (status, render) in zip(statuses, renders) {
        #expect(render != nil, Comment(rawValue: "\(status) failed to render at all"))
    }

    // Every status must produce pixels distinct from every other status --
    // not merely "some pair differs", which a broken mapping could satisfy
    // by accident (e.g. reading a different but still status-shaped field).
    let distinctRenders = Set(renders.compactMap { $0 })
    #expect(distinctRenders.count == statuses.count,
            Comment(rawValue: "expected \(statuses.count) distinct renders, got \(distinctRenders.count)"))
}

@MainActor
private func renderedTIFF(of view: some View) -> Data? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    return renderer.nsImage?.tiffRepresentation
}
