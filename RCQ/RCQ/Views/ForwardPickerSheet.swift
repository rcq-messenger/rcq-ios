import SwiftUI

/// Forward-message picker. Long-press on a bubble → "Forward" →
/// this sheet opens with a flat scroll of forward destinations:
/// Saved Messages on top, then groups, then contacts (online before
/// offline). Tap one and the sheet dismisses; the caller fires the
/// actual `MessageService.forward(...)`.
///
/// Reuses the avatar/row layout from the main contact list so the
/// picker reads as the same surface, just in a sheet instead of a
/// navigation stack.
struct ForwardPickerSheet: View {
    /// What we're about to forward. Only used here for a short header
    /// preview ("Forward this message to…"). The actual forward
    /// payload lives on the closure side.
    let message: Message
    let onPick: (Destination) -> Void
    let onCancel: () -> Void

    enum Destination: Hashable {
        case contact(Contact)
        case group(RCQGroup)
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var contactSvc = ContactService.shared
    @StateObject private var groupSvc = GroupService.shared
    @StateObject private var auth = AuthService.shared
    @State private var query: String = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        savedMessagesRow
                        if !filteredGroups.isEmpty {
                            sectionHeader("GROUPS", count: filteredGroups.count)
                            ForEach(filteredGroups) { group in
                                Button { onPick(.group(group)) } label: {
                                    DestinationRow.group(group)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if !filteredContacts.isEmpty {
                            sectionHeader("CONTACTS", count: filteredContacts.count)
                            ForEach(filteredContacts) { contact in
                                Button { onPick(.contact(contact)) } label: {
                                    DestinationRow.contact(contact)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Spacer().frame(height: 12)
                    }
                }
                .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "common.search".localized)
            }
            .navigationTitle("forward.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { onCancel() }
                }
            }
        }
    }

    // MARK: - rows

    @ViewBuilder
    private var savedMessagesRow: some View {
        if let ownUIN = auth.ownUIN, query.isEmpty || "saved messages".contains(query.lowercased()) {
            let saved = Contact.savedMessagesSelf(ownUIN: ownUIN)
            Button { onPick(.contact(saved)) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Theme.Color.accent))
                        .frame(width: 36)
                    Text("contact_list.saved_messages".localized)
                        .font(Theme.Font.nickname)
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, Theme.Metrics.rowHPad)
                .padding(.vertical, Theme.Metrics.rowVPad)
                .background(Theme.Color.bgPrimary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.Color.textSecondary)
            Text("(\(count))")
                .font(.system(size: 11))
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.Color.bgSecondary.opacity(0.7))
    }

    // MARK: - filtering

    private var filteredContacts: [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = contactSvc.contacts
            .filter { !$0.blocked }
            .sorted { lhs, rhs in
                let lOnline = lhs.status != .offline
                let rOnline = rhs.status != .offline
                if lOnline != rOnline { return lOnline }
                return lhs.nickname.lowercased() < rhs.nickname.lowercased()
            }
        if q.isEmpty { return base }
        return base.filter {
            $0.nickname.lowercased().contains(q) || String($0.uin).contains(q)
        }
    }

    private var filteredGroups: [RCQGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = groupSvc.groups.sorted { $0.name.lowercased() < $1.name.lowercased() }
        if q.isEmpty { return base }
        return base.filter { $0.name.lowercased().contains(q) }
    }
}

private enum DestinationRow {
    static func contact(_ c: Contact) -> some View {
        HStack(spacing: 10) {
            StatusIcon(status: c.status, size: 28)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.nickname)
                    .font(Theme.Font.nickname)
                    .foregroundColor(c.status == .offline ? Theme.Color.textSecondary : Theme.Color.textPrimary)
                Text(String(c.uin))
                    .font(Theme.Font.monoSmall)
                    .foregroundColor(Theme.Color.textMono)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Metrics.rowHPad)
        .padding(.vertical, Theme.Metrics.rowVPad)
        .background(Theme.Color.bgPrimary)
        .contentShape(Rectangle())
    }

    static func group(_ g: RCQGroup) -> some View {
        HStack(spacing: 10) {
            GroupAvatarView(
                mediaID: g.avatarMediaID,
                keyBase64: g.avatarMediaKey,
                size: 28,
            )
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(g.name).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                Text("\(g.members.count) member\(g.members.count == 1 ? "" : "s")")
                    .font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Metrics.rowHPad)
        .padding(.vertical, Theme.Metrics.rowVPad)
        .background(Theme.Color.bgPrimary)
        .contentShape(Rectangle())
    }
}
