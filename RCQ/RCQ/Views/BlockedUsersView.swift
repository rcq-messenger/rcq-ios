import SwiftUI

/// Settings → Blocked Users. Read-only list of every contact the
/// local user has currently blocked, with a one-tap unblock action
/// per row. Apple's UGC guidance (1.2) expects users to be able to
/// inspect + manage their block list from a discoverable place;
/// this is the surface for that.
///
/// Source of truth is `ContactService.blockedPeople()`: every block record
/// of the account, one row per person. Our own island's people show their
/// number; somebody on another island shows `uin@host`, because the number
/// alone names a different person on every island (report 1065). Unblock
/// lifts exactly that row's block (`ContactService.setBlocked`).
///
/// A block made from a request on another island is listed too. Nothing
/// showed it before and nothing could lift it, so that person's messages
/// were dropped for good (report 1064).
struct BlockedUsersView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var contacts = ContactService.shared
    @ObservedObject private var requests = CrossIslandRequestsStore.shared
    @State private var pendingUnblock: ContactService.BlockedPerson?
    @State private var refreshTick = 0

    private var blocked: [ContactService.BlockedPerson] {
        _ = refreshTick  // recompute after a local blocked-set change (stranger unblock)
        _ = requests.revision  // and after a cross-island block lands from another device
        // A decoy session has no blocked users (`blockedPeople` says so too):
        // the list and its Unblock buttons are the real account's safety
        // state, and an account with a handful of seeded chats has none.
        if PanicPINService.shared.isDecoy { return [] }
        return contacts.blockedPeople()
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
                if let person = pendingUnblock {
                    Button("blocked_users.unblock.confirm.cta".localized) {
                        let p = person
                        pendingUnblock = nil
                        Task { @MainActor in
                            await contacts.setBlocked(false, uin: p.uin, host: p.host)
                            refreshTick += 1
                        }
                    }
                    Button("common.cancel".localized, role: .cancel) {
                        pendingUnblock = nil
                    }
                }
            } message: {
                if let person = pendingUnblock {
                    Text(String(
                        format: "blocked_users.unblock.confirm.body".localized,
                        person.name
                    ))
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(blocked) { person in
                    HStack(spacing: 12) {
                        StatusIcon(status: person.status, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.name)
                                .font(.system(.body, weight: .medium))
                                .foregroundColor(Theme.Color.textPrimary)
                            Text(verbatim: person.address)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(Theme.Color.textSecondary)
                        }
                        Spacer()
                        Button {
                            pendingUnblock = person
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
