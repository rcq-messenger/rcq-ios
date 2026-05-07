import SwiftUI

/// Sheet for hosting a new radio room. Sets the name and an
/// optional password (≥ 6 chars). Submitting flips
/// `RadioService.activeRoom`, which the discovery view watches and
/// transitions to `RadioChatView`.
struct CreateRoomView: View {
    @StateObject private var radio = RadioService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var roomName: String = ""
    @State private var passwordEnabled: Bool = false
    @State private var password: String = ""

    private var canCreate: Bool {
        !roomName.trimmingCharacters(in: .whitespaces).isEmpty
            && (!passwordEnabled || password.count >= 6)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("radio.room.name".localized)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.Color.textSecondary)
                                .tracking(2)
                            TextField("radio.room.name_placeholder".localized, text: $roomName)
                                .padding(10)
                                .background(Theme.Color.bgSecondary)
                                .cornerRadius(8)
                                .textInputAutocapitalization(.words)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: $passwordEnabled) {
                                Text("radio.room.password_protected".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                            }
                            .tint(Theme.Color.accent)
                            if passwordEnabled {
                                SecureField("radio.room.password_placeholder".localized, text: $password)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled(true)
                                    .padding(10)
                                    .background(Theme.Color.bgSecondary)
                                    .cornerRadius(8)
                                    .textInputAutocapitalization(.never)
                                Text("radio.room.password_footer".localized)
                                    .font(.caption2)
                                    .foregroundColor(Theme.Color.textSecondary)
                            } else {
                                Text("radio.room.open_footer".localized)
                                    .font(.caption2)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        }
                        Button {
                            radio.createRoom(
                                name: roomName.trimmingCharacters(in: .whitespacesAndNewlines),
                                password: passwordEnabled ? password : nil,
                            )
                            dismiss()
                        } label: {
                            Text("radio.room.create".localized)
                                .font(.system(.body, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                                .background(canCreate ? Theme.Color.accent : Theme.Color.divider)
                                .cornerRadius(8)
                        }
                        .disabled(!canCreate)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("radio.room.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                }
            }
        }
    }
}
