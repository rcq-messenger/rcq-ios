import SwiftUI

struct ProxyURLSheet: View {
    @AppStorage("rcq.proxyURL") private var proxyURL: String = ""
    @AppStorage("rcq.autoProxyActive") private var autoProxyActive: Bool = false
    @AppStorage("rcq.singbox.enabled") private var singboxEnabled: Bool = false
    @State private var draft: String = ""
    @Environment(\.dismiss) private var dismiss

    private var hasManual: Bool {
        !proxyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusText: String {
        if hasManual { return "settings.network.proxy.status.manual".localized }
        return autoProxyActive
            ? "settings.network.proxy.status.auto".localized
            : "settings.network.proxy.status.direct".localized
    }

    private var statusColor: Color {
        if hasManual { return Theme.Color.accent }
        return autoProxyActive ? .orange : .green
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("settings.network.proxy.intro".localized)
                            .font(.callout)
                            .foregroundColor(Theme.Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 7) {
                            Circle().fill(statusColor).frame(width: 8, height: 8)
                            Text(statusText)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.Color.bgSecondary))

                        Divider().background(Theme.Color.divider.opacity(0.3))

                        Toggle(isOn: $singboxEnabled) {
                            Text("settings.network.singbox.label".localized)
                                .font(.callout.weight(.semibold))
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        .tint(Theme.Color.accent)
                        .onChange(of: singboxEnabled) { newValue in
                            Task { await SingBoxTransport.shared.setEnabled(newValue) }
                        }
                        Text("settings.network.singbox.note".localized)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider().background(Theme.Color.divider.opacity(0.3))

                        Text("settings.network.proxy.manual_label".localized)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.Color.textSecondary)
                        TextField("settings.network.proxy.placeholder".localized, text: $draft)
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
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("settings.network.title".localized)
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
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
