import SwiftUI

/// Borderless, blur-backed search surface invoked from the
/// top-bar magnifier. Slides in over the contact list, hosts
/// a single airy text field at the top, and renders live
/// results below in three sections: Contacts, Groups,
/// Messages.
///
/// Tap on any result invokes the matching `onSelect…`
/// callback; `ContactListView` closes the overlay and
/// pushes the destination onto its NavigationPath. Tap on
/// the empty area outside the field/results dismisses.
struct SearchOverlay: View {
    let onClose: () -> Void
    let onSelectContact: (Contact) -> Void
    let onSelectGroup: (RCQGroup) -> Void

    @StateObject private var contactSvc = ContactService.shared
    @StateObject private var groupSvc = GroupService.shared
    @StateObject private var messageStore = MessageStore.shared
    @State private var query: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Tappable scrim — tap on any "empty space" closes.
            // The search column itself swallows the tap so it
            // doesn't bubble.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 0) {
                searchField
                Divider().background(Theme.Color.divider.opacity(0.4))
                results
            }
            .background(.ultraThinMaterial)
            .ignoresSafeArea(edges: .bottom)
        }
        .onAppear {
            // Pop the keyboard on the next runloop tick so the
            // overlay's transition is finished before we ask for
            // first responder — avoids the rare "TextField
            // present but unfocused" race on iOS 17.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                fieldFocused = true
            }
        }
    }

    // MARK: - field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.Color.textSecondary)
                .font(.system(size: 17))
            TextField("", text: $query, prompt: Text("search.placeholder".localized)
                .foregroundColor(Theme.Color.textSecondary))
                .focused($fieldFocused)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(Theme.Color.textPrimary)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                    fieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.Color.textSecondary)
                        .font(.system(size: 17))
                }
            }
            Button("search.cta.cancel".localized) { onClose() }
                .font(.system(size: 15))
                .foregroundColor(Theme.Color.accent)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: - results

    private var contactHits: [Contact] {
        let q = normalized
        guard !q.isEmpty else { return [] }
        return contactSvc.contacts.filter { contact in
            contact.nickname.lowercased().contains(q)
                || String(contact.uin).contains(q)
        }
    }

    private var groupHits: [RCQGroup] {
        let q = normalized
        guard !q.isEmpty else { return [] }
        return groupSvc.groups.filter { $0.name.lowercased().contains(q) }
    }

    /// Search hits across every persisted message, paired with
    /// the thread they came from so the row can label "in
    /// {nickname}" / "in {group}". Capped at 50 for the worst
    /// case of a noisy archive — usability beats completeness;
    /// the query field is always there for narrowing.
    private var messageHits: [MessageHit] {
        let q = normalized
        guard !q.isEmpty else { return [] }
        var out: [MessageHit] = []
        for (thread, msgs) in messageStore.threads {
            for m in msgs where m.kind == .text {
                if m.text.lowercased().contains(q) {
                    out.append(MessageHit(thread: thread, message: m))
                }
            }
        }
        return Array(out.sorted(by: { $0.message.sentAt > $1.message.sentAt }).prefix(50))
    }

    private var normalized: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @ViewBuilder
    private var results: some View {
        if normalized.isEmpty {
            VStack(spacing: 6) {
                Spacer().frame(height: 60)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30))
                    .foregroundColor(Theme.Color.textSecondary)
                Text("search.empty.idle".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
        } else if contactHits.isEmpty && groupHits.isEmpty && messageHits.isEmpty {
            VStack(spacing: 6) {
                Spacer().frame(height: 60)
                Text("search.empty.no_match".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !contactHits.isEmpty {
                        Section { contactSection } header: { sectionHeader("search.section.contacts".localized) }
                    }
                    if !groupHits.isEmpty {
                        Section { groupSection } header: { sectionHeader("search.section.groups".localized) }
                    }
                    if !messageHits.isEmpty {
                        Section { messageSection } header: { sectionHeader("search.section.messages".localized) }
                    }
                }
                .padding(.bottom, 30)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundColor(Theme.Color.textSecondary)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
    }

    private var contactSection: some View {
        ForEach(contactHits) { contact in
            Button { onSelectContact(contact) } label: {
                HStack(spacing: 10) {
                    StatusIcon(status: contact.status, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(contact.nickname)
                            .font(Theme.Font.nickname)
                            .foregroundColor(Theme.Color.textPrimary)
                        Text(String(contact.uin))
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textMono)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var groupSection: some View {
        ForEach(groupHits) { group in
            Button { onSelectGroup(group) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name)
                            .font(Theme.Font.nickname)
                            .foregroundColor(Theme.Color.textPrimary)
                        Text(String(
                            format: (group.members.count == 1
                                ? "contact_list.members_one"
                                : "contact_list.members_many").localized,
                            group.members.count
                        ))
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textMono)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var messageSection: some View {
        ForEach(messageHits) { hit in
            Button {
                switch hit.thread {
                case .peer(let uin):
                    if let c = contactSvc.contacts.first(where: { $0.uin == uin }) {
                        onSelectContact(c)
                    } else {
                        onClose()
                    }
                case .group(let id):
                    if let g = groupSvc.find(id) {
                        onSelectGroup(g)
                    } else {
                        onClose()
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: hit.thread.isGroup ? "person.3.fill" : "bubble.left")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        // Same emoticon-aware renderer the chat
                        // bubbles use, so `:)` / `;)` etc. show
                        // up animated in the search hit instead
                        // of leaking the raw shortcode through.
                        EmoticonText(text: hit.message.text, font: .body, emoticonSize: 18)
                            .lineLimit(2)
                        Text(threadLabel(hit.thread))
                            .font(Theme.Font.monoSmall)
                            .foregroundColor(Theme.Color.textMono)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func threadLabel(_ thread: ThreadID) -> String {
        switch thread {
        case .peer(let uin):
            if let c = contactSvc.contacts.first(where: { $0.uin == uin }) {
                return String(format: "search.thread.in_named".localized, c.nickname)
            }
            return String(format: "search.thread.in_uin".localized, uin)
        case .group(let id):
            if let g = groupSvc.find(id) {
                return String(format: "search.thread.in_named".localized, g.name)
            }
            return "search.thread.in_group".localized
        }
    }
}

private struct MessageHit: Identifiable {
    let thread: ThreadID
    let message: Message
    var id: UUID { message.id }
}
