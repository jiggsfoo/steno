import SwiftUI
import Testing
@testable import HiDockMenubar

/// A `Binding` over real storage, so these tests observe the write the way
/// `MenuBarView.showReclaim` does rather than through a stub that only records
/// that *something* was called.
@MainActor
private final class PresentationBox {
    var isPresented = true
    var binding: Binding<Bool> {
        Binding(get: { self.isPresented }, set: { self.isPresented = $0 })
    }
}

/// The phantom-sheet bug: Cancel closed the sheet, but the popover tearing down
/// at the same moment meant `@Environment(\.dismiss)` never wrote `false` back
/// to the `@State` that presents it. Re-opening the menu re-evaluated
/// `MenuBarView` with `showReclaim` still `true` and re-presented the sheet.
///
/// Both exits are covered because both were broken: Cancel is the one the user
/// hit, but the confirmed-delete path dismissed the same way and would have
/// left the same phantom behind.
@MainActor
@Test func cancellingTheReclaimSheetClearsThePresentingState() {
    let box = PresentationBox()
    let view = ReclaimView(model: AppModel(), isPresented: box.binding)

    // Fails open otherwise: a box that started `false` would "pass" without the
    // view writing anything at all.
    #expect(box.isPresented, "precondition -- the sheet must start presented")

    view.cancel()

    #expect(box.isPresented == false,
            "Cancel must write false to the state presenting the sheet, or re-opening the popover re-presents it")
}

@MainActor
@Test func confirmingTheDeleteClearsThePresentingState() {
    let box = PresentationBox()
    let model = AppModel()
    // `start()` is never called, so `AppModel.index` is nil and `reclaim(_:)`
    // returns at its own guard. No device is touched by this test.
    let view = ReclaimView(model: model, isPresented: box.binding)

    #expect(box.isPresented, "precondition -- the sheet must start presented")

    view.confirmDelete()

    #expect(box.isPresented == false,
            "the confirmed-delete path must dismiss through the same binding")
}
