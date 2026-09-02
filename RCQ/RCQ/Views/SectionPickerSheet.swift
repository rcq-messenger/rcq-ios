import SwiftUI

/// "Add chats to this section": the plus button in a user section's header.
///
/// One write for the whole sheet, on Save. Contacts, cross-island peers and
/// groups are one pick list keyed the way the slot keys them, so a person who
/// is both a roster row and a local cross-island record is one candidate rather
/// than two.
///
/// ⚠ THE SHEET WRITES WHAT THE USER DID, not the list it ended up showing: the
/// keys they ticked and the keys they unticked, both relative to the membership
/// the sheet OPENED on. Its checkboxes are seeded once and the tree moves under
/// an open sheet (the desktop files a chat into the same section, the nudge
/// folds it into the cache), so diffing the sheet's list against the tree as it
/// stands on Save turns a row the user never touched into a removal, with a
/// tombstone newer than the other device's add. The merge then keeps the undo
/// and neither user is told.
struct SectionPickerSheet: View {
    let sectionID: String
    let title: String
    let contacts: [Contact]
    let crossIsland: [Contact]
    let groups: [RCQGroup]
    var onError: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    /// The membership this sheet opened on. Seeded once, never re-read.
    @State private var opening: Set<String> = []
    @State private var ticked: Set<String> = []
    @State private var candidates: [Candidate] = []
    @State private var seeded = false

    private struct Candidate: Identifiable {
        let key: String
        let title: String
        let subtitle: String
        let isGroup: Bool
        /// What the row draws on the left. The sheet used to put a generic
        /// person glyph next to every name, which is the one place in the app
        /// where a contact appears without the face and the status dot the
        /// roster gives them, and it made a list of people unreadable at a
        /// glance. Carried on the candidate rather than looked up in the row:
        /// the list is built once, off contacts we already hold.
        let avatarID: String?
        let avatarKey: String?
        let status: UserStatus
        let host: String?
        var id: String { key }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if candidates.isEmpty {
                    Text("sections.picker.nobody".localized)
                        .font(.footnote)
                        .foregroundColor(Theme.Color.textSecondary)
                } else {
                    List {
                        ForEach(filtered) { candidate in
                            Button {
                                if ticked.contains(candidate.key) {
                                    ticked.remove(candidate.key)
                                } else {
                                    ticked.insert(candidate.key)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    if candidate.isGroup {
                                        GroupAvatarView(
                                            mediaID: candidate.avatarID,
                                            keyBase64: candidate.avatarKey,
                                            host: candidate.host,
                                            size: 28,
                                            glyphSize: 13,
                                        )
                                    } else {
                                        PersonAvatarView(
                                            mediaID: candidate.avatarID,
                                            keyBase64: candidate.avatarKey,
                                            status: candidate.status,
                                            host: candidate.host,
                                            size: 28,
                                            crossIsland: candidate.host != nil,
                                        )
                                    }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(candidate.title)
                                            .font(Theme.Font.nickname)
                                            .foregroundColor(Theme.Color.textPrimary)
                                            .lineLimit(1)
                                        Text(candidate.subtitle)
                                            .font(Theme.Font.monoSmall)
                                            .foregroundColor(Theme.Color.textMono)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if ticked.contains(candidate.key) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(Theme.Color.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.Color.bgPrimary)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .searchable(text: $search, prompt: Text("sections.picker.search".localized))
                }
            }
            .navigationTitle(String(format: "sections.picker.title".localized, title))
            .navigationBarTitleDisplayMode(.inline)
            // Glyphs, not words. The title is a FORMAT ("Add to %@") that
            // carries a section name of the user's own choosing, so two word
            // buttons either squeeze it or truncate it. The labels stay on as
            // accessibility text, which is what VoiceOver reads either way.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("common.cancel".localized)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Image(systemName: "checkmark") }
                        .accessibilityLabel("sections.picker.save".localized)
                }
            }
        }
        .task {
            guard !seeded else { return }
            seeded = true
            candidates = buildCandidates()
            let held = Set(Sections.membersOf(SectionsStore.shared.tree, sectionID))
            opening = held
            ticked = held
        }
    }

    private var filtered: [Candidate] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    /// ⚠ Keys carry the HOST, and a foreign group is keyed by (remoteId, host)
    /// rather than by its local negative alias, which means nothing on another
    /// device.
    private func buildCandidates() -> [Candidate] {
        var byKey: [String: Candidate] = [:]
        var order: [String] = []
        func add(_ c: Candidate) {
            if byKey[c.key] == nil { order.append(c.key) }
            byKey[c.key] = byKey[c.key] ?? c
        }
        let myUIN = AuthService.shared.ownUIN
        for contact in contacts {
            guard !(contact.uin == myUIN && Multihome.isOwnHost(contact.host)) else { continue }
            let key = Sections.peerKey(contact.uin, host: contact.host)
            add(Candidate(
                key: key,
                title: ContactAliasStore.shared.displayName(
                    for: contact.uin, fallback: contact.nickname, host: contact.host
                ),
                subtitle: contact.host.map { "\(contact.uin) · \($0)" } ?? "\(contact.uin)",
                isGroup: false,
                avatarID: contact.avatarMediaID,
                avatarKey: contact.avatarKeyResolved,
                status: contact.status,
                host: contact.host,
            ))
        }
        for contact in crossIsland where !Multihome.isOwnHost(contact.host) {
            let key = Sections.peerKey(contact.uin, host: contact.host)
            add(Candidate(
                key: key,
                title: ContactAliasStore.shared.displayName(
                    for: contact.uin, fallback: contact.nickname, host: contact.host
                ),
                subtitle: contact.host.map { "\(contact.uin) · \($0)" } ?? "\(contact.uin)",
                isGroup: false,
                avatarID: contact.avatarMediaID,
                avatarKey: contact.avatarKeyResolved,
                status: contact.status,
                host: contact.host,
            ))
        }
        for group in groups {
            guard let key = Sections.key(forGroup: group) else { continue }
            add(Candidate(
                key: key,
                title: group.name,
                subtitle: group.host ?? "contact_list.section.groups".localized,
                isGroup: true,
                avatarID: group.avatarMediaID,
                avatarKey: group.avatarMediaKey,
                status: .offline,
                host: group.host,
            ))
        }
        return order.compactMap { byKey[$0] }
    }

    private func save() {
        let added = Array(ticked.subtracting(opening))
        let gone = Array(opening.subtracting(ticked))
        guard !added.isEmpty || !gone.isEmpty else { dismiss(); return }
        do {
            _ = try SectionsVault.mutate { tree in
                var out = tree
                if !added.isEmpty {
                    out = try Sections.addMembers(out, sectionID, keys: added)
                }
                for key in gone {
                    out = Sections.removeMemberFrom(out, sectionID, key: key)
                }
                return out
            }
        } catch let e as SectionsError {
            onError("sections.err.\(e.code)".localized)
        } catch {
            onError("common.error".localized)
        }
        dismiss()
    }
}
