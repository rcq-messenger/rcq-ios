import SwiftUI

/// Sheet that shows ONE specific trade — used when the user taps
/// the inline trade card inside a chat. Action row is the same
/// as `TradesListView`'s incoming/outgoing cells (Accept/Decline
/// for incoming, Cancel for outgoing). Distinct from the unified
/// list view which surfaces every pending trade across all peers.
struct SingleTradeSheet: View {
    let trade: Trade

    @StateObject private var trades = TradesService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var working = false
    @State private var lastError: String?
    @State private var inspectingItem: Item?

    private var liveTrade: Trade? {
        trades.incoming.first(where: { $0.id == trade.id })
            ?? trades.outgoing.first(where: { $0.id == trade.id })
            ?? trade
    }

    private var isIncoming: Bool {
        let myUIN = AuthService.shared.ownUIN ?? -1
        return liveTrade?.toUIN == myUIN
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let live = liveTrade {
                            InlineTradeCard(
                                trade: live,
                                isFromMe: !isIncoming,
                                onItemTap: { inspectingItem = $0 },
                            )
                            if let note = live.note, !note.isEmpty {
                                noteLine(note)
                            }
                            if let err = lastError {
                                Text(err)
                                    .font(Theme.Font.statusLabel)
                                    .foregroundColor(.red)
                            }
                            actionRow(for: live)
                            openChatRow(for: live)
                        } else {
                            Text("trade.resolved".localized)
                                .font(Theme.Font.nickname)
                                .foregroundColor(Theme.Color.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                }
            }
            .sheet(item: $inspectingItem) { item in
                ItemDetailSheet(item: item, readOnly: true)
                    .presentationDetents([.large])
            }
        }
    }

    @ViewBuilder
    private func actionRow(for live: Trade) -> some View {
        if isIncoming {
            HStack(spacing: 8) {
                Button {
                    Task { await act(live, accept: false) }
                } label: {
                    Text("trade.cta.decline".localized)
                        .font(.system(.body, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .foregroundColor(Theme.Color.textPrimary)
                        .background(Theme.Color.bgSecondary)
                        .cornerRadius(6)
                }
                .disabled(working)
                Button {
                    Task { await act(live, accept: true) }
                } label: {
                    Text(working
                         ? "…"
                         : (live.isGift
                            ? "trade.cta.accept_gift".localized
                            : "trade.cta.accept".localized))
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(working ? Theme.Color.divider : Theme.Color.accent)
                        .cornerRadius(6)
                }
                .disabled(working)
            }
        } else {
            Button {
                Task { await cancel(live) }
            } label: {
                Text(working ? "…" : "trade.cta.cancel".localized)
                    .font(.system(.body, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(6)
            }
            .disabled(working)
        }
    }

    /// "Open chat with X" link — surfaces only when the
    /// counterparty is in the user's contact list (we have a
    /// nickname to show + the contact actually exists for the
    /// chat to push). Routes via `AppState.pendingOpenChatUIN`
    /// so ContactListView can dismiss this sheet + push the chat
    /// onto its NavigationStack.
    @ViewBuilder
    private func openChatRow(for live: Trade) -> some View {
        let myUIN = AuthService.shared.ownUIN ?? -1
        let peerUIN = isIncoming ? live.fromUIN : live.toUIN
        if peerUIN != myUIN,
           let contact = ContactService.shared.contacts.first(where: { $0.uin == peerUIN }) {
            Button {
                AppState.shared.pendingOpenChatUIN = peerUIN
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    StatusIcon(status: contact.status, size: 22)
                    Text(String(format: "trade.open_chat".localized, contact.nickname))
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.Color.textMono)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    private func noteLine(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "quote.opening")
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
            Text(note)
                .font(.callout.italic())
                .foregroundColor(Theme.Color.textPrimary)
            Spacer(minLength: 0)
        }
    }

    @MainActor
    private func act(_ live: Trade, accept: Bool) async {
        working = true
        defer { working = false }
        lastError = nil
        let result: Trade?
        if accept {
            result = await trades.accept(live)
        } else {
            result = await trades.decline(live)
        }
        if result == nil {
            lastError = (accept
                ? "trade.error.accept"
                : "trade.error.decline").localized
        } else {
            // Resolved — close after a beat so user sees the
            // disappear, then dismiss.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                dismiss()
            }
        }
    }

    @MainActor
    private func cancel(_ live: Trade) async {
        working = true
        defer { working = false }
        lastError = nil
        if await trades.cancel(live) == nil {
            lastError = "trade.error.cancel".localized
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                dismiss()
            }
        }
    }
}
