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
                            if prefs.prefs.mutedUINs.isEmpty {
                                Text("notifs.muted.empty".localized)
                                    .font(.footnote)
                                    .foregroundColor(Theme.Color.textSecondary)
                                    .settingsSearchRow(.mutedSenders, highlight: activeHighlight)
                            } else {
                                ForEach(prefs.prefs.mutedUINs, id: \.self) { uin in
                                    if uin == prefs.prefs.mutedUINs.first {
                                        // The anchor rides the first entry:
                                        // `.id` on a ForEach is not a row of
                                        // its own, and a row background hung
                                        // there paints every muted sender.
                                        mutedRow(uin: uin)
                                            .settingsSearchRow(.mutedSenders, highlight: activeHighlight)
                                    } else {
                                        mutedRow(uin: uin)
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

    private func mutedRow(uin: Int) -> some View {
        // Pull the nickname from contacts if we have it; fall back
        // to a `#UIN` tag so muted-non-contacts still render
        // something readable.
        let nickname = contacts.contacts.first(where: { $0.uin == uin })?.nickname ?? "\(uin)"
        return HStack(spacing: 10) {
            Image(systemName: "bell.slash.fill")
                .foregroundColor(Theme.Color.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(nickname)
                    .foregroundColor(Theme.Color.textPrimary)
                Text(verbatim: "\(uin)")
                    .font(Theme.Font.monoSmall)
                    .foregroundColor(Theme.Color.textMono)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await prefs.setMuted(uin, muted: false) }
            } label: {
                Text("notifs.unmute".localized)
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.vertical, 2)
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
