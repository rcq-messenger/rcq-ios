import SwiftUI

/// Short sheet for entering the proxy URL — replaces the inline
/// TextField that used to live in Settings → Network. Edits a local
/// draft and only commits to `UserDefaults` on Save so a half-typed
/// URL doesn't get picked up by `APIClient.baseURL` mid-edit.
struct ProxyURLSheet: View {
    @AppStorage("rcq.proxyURL") private var proxyURL: String = ""
    @State private var draft: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    TextField("https://rcq-proxy.workers.dev", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .font(.callout.monospaced())
                        .foregroundColor(Theme.Color.textPrimary)
                        .padding(12)
                        .background(Theme.Color.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("settings.network.proxy.footer".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("settings.network.proxy".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save".localized) {
                        proxyURL = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                    }
                }
            }
            .onAppear { draft = proxyURL }
        }
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
    }
}
