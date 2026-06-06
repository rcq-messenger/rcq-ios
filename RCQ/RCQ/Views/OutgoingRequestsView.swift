import SwiftUI

/// "Sent requests" — contact requests we sent that are still pending or were
/// declined by the recipient. Declined ones surface here because there's no
/// push telling the sender the outcome (sealed sender / no FCM). Revoke a
/// pending request or dismiss a declined one. Reached from the contact-list
/// 3-dot menu.
struct OutgoingRequestsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var contacts = ContactService.shared

    var body: some View {
        NavigationStack {
            Group {
                if contacts.outgoingRequests.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("outgoing.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .task { await contacts.refresh() }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "paperplane")
                .font(.system(size: 36))
                .foregroundColor(Theme.Color.textSecondary)
            Text("outgoing.empty".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(contacts.outgoingRequests) { req in
                    row(req)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ req: ContactService.OutgoingRequest) -> some View {
        let declined = req.state == "declined"
        HStack(spacing: 12) {
            Image(systemName: declined ? "nosign" : "clock")
                .font(.system(size: 18))
                .foregroundColor(declined ? .red : Theme.Color.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(req.nickname)
                    .font(.system(.body, weight: .medium))
                    .foregroundColor(Theme.Color.textPrimary)
                HStack(spacing: 8) {
                    Text(verbatim: "#\(req.to_uin)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.Color.textMono)
                    Text((declined ? "outgoing.state.declined" : "outgoing.state.pending").localized)
                        .font(.system(size: 12))
                        .foregroundColor(declined ? .red : Theme.Color.textSecondary)
                }
            }
            Spacer()
            Button {
                Task { try? await contacts.cancelOutgoing(toUIN: req.to_uin) }
            } label: {
                Text((declined ? "outgoing.dismiss" : "outgoing.cancel").localized)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundColor(declined ? Theme.Color.textSecondary : .red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
