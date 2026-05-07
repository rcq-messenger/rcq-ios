import SwiftUI

/// Single-field rename sheet for the active audio room. Opens
/// from `AudioRoomScreen.topBar` when the owner taps the room
/// name (pencil affordance). Trim is server-side too; we just
/// gate the Save button on a non-empty trimmed value here.
struct RenameAudioRoomSheet: View {
    @Binding var draft: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var fieldFocused: Bool

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("audio_room.rename.placeholder".localized, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .focused($fieldFocused)
                    .onSubmit {
                        if !trimmed.isEmpty { onSave(trimmed) }
                    }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("audio_room.rename.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save".localized) { onSave(trimmed) }
                        .disabled(trimmed.isEmpty)
                }
            }
            .onAppear {
                // Auto-focus the field — the user came here to type,
                // not to look at the sheet chrome.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    fieldFocused = true
                }
            }
        }
    }
}
