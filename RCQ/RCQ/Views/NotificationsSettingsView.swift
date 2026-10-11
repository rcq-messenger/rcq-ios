import SwiftUI

/// Per-category push toggles + the muted-senders list. Backed by
/// `NotificationPrefsService`, which writes through to the server's
/// `push_preferences` JSONB column. Toggles are optimistic — flip
/// here, server catches up async; on failure server keeps the old
/// value and the next refresh re-syncs the UI down.
///
/// Sealed-sender messages (1:1 + group) stay out of this list —
/// the server can't filter them by sender without unwrapping the
/// seal, and a global "no message pushes" switch is what iOS
/// Settings → Notifications already provides.
struct NotificationsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var prefs = NotificationPrefsService.shared
    @StateObject private var contacts = ContactService.shared
    /// The muted list is this account's, as the chat list shows it: its own
    /// island's numbers (which the island keeps too) and the people on other
    /// islands muted on this phone.
    @ObservedObject private var sound = SoundService.shared
    /// Row the Settings search sent us to (item 28).
    var highlight: SettingsRow?
    /// The highlight while it is still showing; dropped on a timer so the
    /// wash fades instead of sitting on the row for the life of the sheet.
    @State private var activeHighlight: SettingsRow?

    // MARK: - search index
    //
    // ⚠ A row added below belongs here; the DEBUG check in
    // `SettingsSearchIndex` is what catches one that forgot.
    static let searchEntries: [SettingsSearchEntry] = [
        .init(row: .contactRequests, titleKey: "notifs.contact_requests",
              sectionKey: "settings.notifications", destination: .notifications),
        .init(row: .mutedSenders, titleKey: "notifs.section.muted",
              sectionKey: "settings.notifications", destination: .notifications),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollViewReader { proxy in
                    Form {
                        Section {
                            Toggle(isOn: bind(\.contactRequests, set: prefs.setContactRequests)) {
                                Text("notifs.contact_requests".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                            }
                            .tint(Theme.Color.accent)
                            .settingsSearchRow(.contactRequests, highlight: activeHighlight)
                        } header: {
                            Text("notifs.section.requests".localized)
                        } footer: {
                            Text("notifs.contact_requests.footer".localized)
                        }

                        // The muted list is the row search lands on, so it
                        // needs an anchor even when it is empty: a jump into
                        // an absent section reads as search doing nothing.
                        Section {
                            let muted = sound.mutedPeers
                            if muted.isEmpty {
                                Text("notifs.muted.empty".localized)
                                    .font(.footnote)
                                    .foregroundColor(Theme.Color.textSecondary)
                                    .settingsSearchRow(.mutedSenders, highlight: activeHighlight)
                            } else {
                                ForEach(muted, id: \.self) { peer in
                                    if peer == muted.first {
                                        // The anchor rides the first entry:
                                        // `.id` on a ForEach is not a row of
                                        // its own, and a row background hung
                                        // there paints every muted sender.
                                        mutedRow(peer)
                                            .settingsSearchRow(.mutedSenders, highlight: activeHighlight)
                                    } else {
                                        mutedRow(peer)
                                            .listRowBackground(Theme.Color.bgSecondary)
                                    }
                                }
                            }
                        } header: {
                            Text("notifs.section.muted".localized)
                        } footer: {
                            Text("notifs.muted.footer".localized)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    // The sheet has to be on screen before a scroll means
                    // anything, so the jump waits a beat rather than firing
                    // into a list that has not laid out yet.
                    .onAppear {
                        guard let highlight else { return }
                        activeHighlight = highlight
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation { proxy.scrollTo(highlight, anchor: .center) }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
                            if activeHighlight == highlight {
                                withAnimation { activeHighlight = nil }
                            }
                        }
                    }
                }
            }
            .navigationTitle("notifs.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.done".localized) { dismiss() }
                }
            }
            .task { await prefs.refresh() }
        }
    }

    @ViewBuilder
    private func mutedRow(_ peer: SoundService.Chat) -> some View {
        if case .peer(let uin, let host) = peer {
            // Pull the nickname from contacts if we have it; fall back to the
            // number (with its island, for somebody on another one) so
            // muted-non-contacts still render something readable. The row of
            // exactly this person: the same number elsewhere is somebody else.
            let address = host.map { "\(uin)@\($0)" } ?? "\(uin)"
            let nickname = contacts.contacts.first {
                $0.uin == uin && $0.host.flatMap(AppGroup.canonicalHost) == host
            }?.nickname ?? address
            HStack(spacing: 10) {
                Image(systemName: "bell.slash.fill")
                    .foregroundColor(Theme.Color.textSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(nickname)
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(verbatim: address)
                        .font(Theme.Font.monoSmall)
                        .foregroundColor(Theme.Color.textMono)
                }
                Spacer()
                // Through SoundService, the one writer: the chat list, the
                // extension and the island hear it together.
                Button(role: .destructive) {
                    sound.setNotifyMode(.all, peer)
                } label: {
                    Text("notifs.unmute".localized)
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Two-way binding between a Prefs key path and the matching
    /// async setter. SwiftUI Toggle wants a `Binding<Bool>`; we
    /// hand back a getter that reads from the published value
    /// + a setter that fires the async update.
    private func bind(
        _ keyPath: KeyPath<NotificationPrefsService.Prefs, Bool>,
        set: @escaping (Bool) async -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { prefs.prefs[keyPath: keyPath] },
            set: { newValue in Task { await set(newValue) } }
        )
    }
}
