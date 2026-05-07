import SwiftUI

struct StatusPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var presence = PresenceService.shared
    @State private var draftMessage: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(UserStatus.allCases) { status in
                        Button {
                            Task {
                                await presence.setStatus(status, message: draftMessage.isEmpty ? nil : draftMessage)
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 10) {
                                StatusIcon(status: status, size: 18)
                                Text(status.label)
                                    .font(.body)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Spacer()
                                if status == presence.status {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Theme.Color.accent)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        }
                        Divider().background(Theme.Color.divider)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("STATUS MESSAGE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.Color.textSecondary)
                            .padding(.top, 16)
                        TextField("Out for lunch…", text: $draftMessage)
                            .textFieldStyle(.roundedBorder)
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                    .padding(.horizontal, 16)

                    Spacer()
                }
            }
            .navigationTitle("Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear { draftMessage = presence.statusMessage ?? "" }
        }
        
    }
}
