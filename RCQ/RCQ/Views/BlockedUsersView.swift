import SwiftUI

/// Settings → Blocked Users. Read-only list of every contact the
/// local user has currently blocked, with a one-tap unblock action
/// per row. Apple's UGC guidance (1.2) expects users to be able to
/// inspect + manage their block list from a discoverable place;
/// this is the surface for that.
///
/// Source of truth is `ContactService.shared.contacts.filter
/// { $0.blocked }` — same `Contact` rows the rest of the app uses,
/// just filtered down. Unblock fires the existing
/// `ContactService.toggleBlock(_:)` endpoint, which the rest of the
/// app already trusts.
struct BlockedUsersView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var contacts = ContactService.shared
    @State private var pendingUnblock: Int?
    @State private var refreshTick = 0

    private var blocked: [Contact] {
        _ = refreshTick  // recompute after a local blocked-set change (stranger unblock)
        // `BlockedContactsStore` is device-global, not per-account, so a decoy
        // session read the REAL blocked set straight out of it — a list of real
        // uins, and an Unblock button that would really unblock them on the
        // real account. The store is left exactly as it is (it is safety state
        // the real session must keep); the duress view simply has no blocked
        // users, which is what an account with a handful of seeded chats looks
        // like anyway.
        if PanicPINService.shared.isDecoy { return [] }
        let byUin = Dictionary(contacts.contacts.map { ($0.uin, $0) }, uniquingKeysWith: { a, _ in a })
        // Union of server-blocked contacts + the LOCAL blocked set (covers
        // blocked strangers with no contact row, shown as #uin stubs).
        let uins = Set(BlockedContactsStore.shared.all())
            .union(contacts.contacts.filter { $0.blocked }.map { $0.uin })
        return uins
            .map { byUin[$0] ?? Contact.blockedStub(uin: $0) }
            .sorted { $0.nickname.localizedCaseInsensitiveCompare($1.nickname) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if blocked.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("settings.blocked_users".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .confirmationDialog(
                "blocked_users.unblock.confirm.title".localized,
                isPresented: Binding(
                    get: { pendingUnblock != nil },
                    set: { if !$0 { pendingUnblock = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let uin = pendingUnblock {
                    Button("blocked_users.unblock.confirm.cta".localized) {
                        let u = uin
                        pendingUnblock = nil
                        Task { @MainActor in
                            try? await contacts.toggleBlock(u)
                            refreshTick += 1
                        }
                    }
                    Button("common.cancel".localized, role: .cancel) {
                        pendingUnblock = nil
                    }
                }
            } message: {
                if let uin = pendingUnblock,
                   let contact = blocked.first(where: { $0.uin == uin }) {
                    Text(String(
                        format: "blocked_users.unblock.confirm.body".localized,
                        contact.nickname
                    ))
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(blocked) { contact in
                    HStack(spacing: 12) {
                        StatusIcon(status: contact.status, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contact.nickname)
                                .font(.system(.body, weight: .medium))
                                .foregroundColor(Theme.Color.textPrimary)
                            Text(verbatim: "\(contact.uin)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                        Spacer()
                        Button {
                            pendingUnblock = contact.uin
                        } label: {
                            Text("blocked_users.unblock".localized)
                                .font(.system(.caption, weight: .semibold))
                                .foregroundColor(Theme.Color.accent)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(
                                    Capsule().fill(Theme.Color.accent.opacity(0.15))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Theme.Color.bgSecondary)
                }
            } footer: {
                Text("blocked_users.footer".localized)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.raised.slash")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(Theme.Color.divider)
            Text("blocked_users.empty.title".localized)
                .font(.headline)
                .foregroundColor(Theme.Color.textPrimary)
            Text("blocked_users.empty.body".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
