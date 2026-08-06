import HiDockKit
import SwiftUI

/// Content of the `Window(_:id: MenuBarView.reclaimWindowID)` scene declared by
/// `HiDockApp`, opened from the menu's "Free Up Space on P1…" row.
///
/// A window, not a `.sheet`. See `MenuBarView.open(_:)` for why a sheet
/// presented out of a `MenuBarExtra(.window)` popover could not be dismissed.
/// Because the scene is the app's and not the popover's, `\.dismiss` is again
/// the right way to close it -- it acts on a presentation the popover's teardown
/// cannot take out from under it.
public struct ReclaimView: View {
    @Bindable var model: AppModel

    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []
    @State private var showConfirm = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Title Case, matching the "Free Up Space on P1…" row that opens
            // this sheet. `.headline` is a visual weight, not a semantic
            // header, so the trait has to be stated.
            Text("Free Up Space on P1")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Only recordings verified present on this Mac are listed. "
                 + "Deleting removes them from the device, not from your library.")
                .font(.caption).foregroundStyle(.secondary)

            if model.isLoadingReclaim {
                // An unlabelled indeterminate spinner announces as "in
                // progress" with no subject.
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Loading recordings from the device")
            } else if model.reclaimCandidates.isEmpty {
                Text("Nothing safe to delete.").foregroundStyle(.secondary)
            } else {
                List(model.reclaimCandidates, id: \.signature) { file in
                    Toggle(isOn: binding(for: file)) {
                        HStack {
                            Text(file.name).lineLimit(1)
                            Spacer()
                            Text("\(file.lengthBytes / 1_000_000) MB")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 240)
            }

            HStack {
                Button("Select All") {
                    selected = Set(model.reclaimCandidates.map(\.signature))
                }
                Spacer()
                // `.cancelAction` also stops Return from reaching the delete
                // button below, which is the point: see its comment.
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                // Deliberately NOT .defaultAction. Deleting from the device is
                // irreversible, and Select-all sits one click away — Return
                // should never be able to wipe the P1. A confirmation dialog
                // stands between the button and the deletion.
                Button("Delete \(selected.count) from Device\u{2026}") {
                    showConfirm = true
                }
                .disabled(selected.isEmpty)
            }
            .confirmationDialog(
                "Delete \(selected.count) recording(s) from the P1?",
                isPresented: $showConfirm, titleVisibility: .visible
            ) {
                Button("Delete from Device", role: .destructive) {
                    model.reclaim(model.reclaimCandidates.filter {
                        selected.contains($0.signature)
                    })
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your local copies in the library are not affected. "
                     + "This cannot be undone on the device.")
            }
        }
        .padding()
        .frame(width: 460)
        // Once per appearance of the window, which is once per open: `Window`
        // is a single-instance scene, so opening it while it is already up
        // orders the existing one front rather than building a second copy --
        // no second `.onAppear`, and no second device session stacked behind
        // the first. `loadReclaimable()` also refuses to start while one is
        // already running, so the two guards agree.
        .onAppear { model.loadReclaimable() }
    }

    private func binding(for file: FileInfo) -> Binding<Bool> {
        Binding(
            get: { selected.contains(file.signature) },
            set: { isOn in
                if isOn { selected.insert(file.signature) }
                else { selected.remove(file.signature) }
            })
    }
}
