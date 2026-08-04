import HiDockKit
import SwiftUI

struct ReclaimView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var showConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Free up space on P1").font(.headline)
            Text("Only recordings verified present on this Mac are listed. "
                 + "Deleting removes them from the device, not from your library.")
                .font(.caption).foregroundStyle(.secondary)

            if model.isLoadingReclaim {
                ProgressView().frame(maxWidth: .infinity)
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
                Button("Select all") {
                    selected = Set(model.reclaimCandidates.map(\.signature))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                // Deliberately NOT .defaultAction. Deleting from the device is
                // irreversible, and Select-all sits one click away — Return
                // should never be able to wipe the P1. A confirmation dialog
                // stands between the button and the deletion.
                Button("Delete \(selected.count) from device\u{2026}") {
                    showConfirm = true
                }
                .disabled(selected.isEmpty)
            }
            .confirmationDialog(
                "Delete \(selected.count) recording(s) from the P1?",
                isPresented: $showConfirm, titleVisibility: .visible
            ) {
                Button("Delete from device", role: .destructive) {
                    model.reclaim(model.reclaimCandidates.filter { selected.contains($0.signature) })
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
