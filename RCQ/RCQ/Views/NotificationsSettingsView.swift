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

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                Form {
                    Section {
                        Toggle(isOn: bind(\.contactRequests, set: prefs.setContactRequests)) {
                            Text("notifs.contact_requests".localized)
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        .tint(Theme.Color.accent)
                    } header: {
                        Text("notifs.section.requests".localized)
                    } footer: {
                        Text("notifs.contact_requests.footer".localized)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    if !prefs.prefs.mutedUINs.isEmpty {
                        Section {
                            ForEach(prefs.prefs.mutedUINs, id: \.self) { uin in
                                mutedRow(uin: uin)
                            }
                        } header: {
                            Text("notifs.section.muted".localized)
                        } footer: {
                            Text("notifs.muted.footer".localized)
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                    }
                }
                .scrollContentBackground(.hidden)
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
        let nickname = contacts.contacts.first(where: { $0.uin == uin })?.nickname ?? "#\(uin)"
        return HStack(spacing: 10) {
            Image(systemName: "bell.slash.fill")
                .foregroundColor(Theme.Color.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(nickname)
                    .foregroundColor(Theme.Color.textPrimary)
                Text(String(uin))
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
