import SwiftUI

/// Pick which real conversations get copied into the decoy account.
///
/// Reachable only from a REAL session (PIN settings re-auths first): it reads
/// the real history, and the decoy session must never be able to discover what
/// it was built from. What lands in the decoy is a rewritten copy — synthetic
/// uins, fresh row ids, shifted timestamps — see `DecoySeeder`.
struct DecoySeedPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [DecoySeeder.Selection] = []
    @State private var picked: Set<Int> = []
    @State private var busy = false
    @State private var loaded = false
    @State private var errorMsg: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if !loaded {
                    ProgressView()
                } else if candidates.isEmpty {
                    emptyState
                } else {
                    Form {
                        Section {
                            ForEach(candidates) { item in
                                row(item)
                            }
                        } header: {
                            Text("panic_pin.decoy.seed.section".localized)
                        } footer: {
                            Text("panic_pin.decoy.seed.footer".localized)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("panic_pin.decoy.seed.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("common.save".localized) { save() }
                            .disabled(!loaded || candidates.isEmpty)
                    }
                }
            }
            .alert("panic_pin.error.title".localized,
                   isPresented: Binding(get: { errorMsg != nil },
                                        set: { if !$0 { errorMsg = nil } })) {
                Button("common.ok".localized, role: .cancel) {}
            } message: {
                Text(errorMsg ?? "")
            }
            .task {
                guard !loaded else { return }
                candidates = PanicPINService.shared.decoySeedCandidates()
                loaded = true
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 36))
                .foregroundColor(Theme.Color.textSecondary)
            Text("panic_pin.decoy.seed.empty".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    private func row(_ item: DecoySeeder.Selection) -> some View {
        Button {
            if picked.contains(item.peerUIN) {
                picked.remove(item.peerUIN)
            } else {
                picked.insert(item.peerUIN)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(String(format: "panic_pin.decoy.seed.count".localized, item.messageCount))
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Spacer()
                if picked.contains(item.peerUIN) {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.Color.accent)
                }
            }
        }
    }

    private func save() {
        busy = true
        let chosen = candidates.filter { picked.contains($0.peerUIN) }
        do {
            try PanicPINService.shared.seedDecoy(with: chosen)
            busy = false
            dismiss()
        } catch {
            busy = false
            errorMsg = error.localizedDescription
        }
    }
}
