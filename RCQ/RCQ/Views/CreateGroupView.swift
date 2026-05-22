import SwiftUI

struct CreateGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var contacts = ContactService.shared
    @State private var name: String = ""
    @State private var selected: Set<Int> = []
    @State private var creating = false
    @State private var error: String?
    let onCreated: (RCQGroup) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "person.3.fill")
                            .foregroundColor(Theme.Color.accent)
                        TextField("create_group.name_placeholder".localized, text: $name)
                            .foregroundColor(Theme.Color.textPrimary)
                            .submitLabel(.done)
                    }
                    .padding(10).background(Theme.Color.bgSecondary).cornerRadius(4)
                    .padding(12)

                    Text(String(format: "create_group.members_section".localized, selected.count))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Theme.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(contacts.contacts) { contact in
                                Button {
                                    if selected.contains(contact.uin) { selected.remove(contact.uin) }
                                    else { selected.insert(contact.uin) }
                                } label: {
                                    row(contact)
                                }
                                Divider().background(Theme.Color.divider)
                            }
                        }
                    }
                    if let error {
                        Text(error)
                            .font(.caption).foregroundColor(Theme.Color.statusBusy)
                            .padding(.horizontal, 16)
                    }
                    Button {
                        Task { await create() }
                    } label: {
                        Text(creating ? "create_group.cta.creating".localized : "create_group.cta.create".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(canCreate ? Theme.Color.accent : Theme.Color.textSecondary.opacity(0.5))
                            .cornerRadius(4)
                    }
                    .disabled(!canCreate)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            .navigationTitle("create_group.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
        }
    }

    private var canCreate: Bool {
        !creating && !name.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty
    }

    private func row(_ contact: Contact) -> some View {
        HStack(spacing: 10) {
            StatusIcon(status: contact.status, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.nickname).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                Text(String(contact.uin)).font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
            }
            Spacer()
            Image(systemName: selected.contains(contact.uin) ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selected.contains(contact.uin) ? Theme.Color.accent : Theme.Color.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func create() async {
        creating = true
        defer { creating = false }
        do {
            let g = try await GroupService.shared.create(
                name: name.trimmingCharacters(in: .whitespaces),
                memberUINs: Array(selected)
            )
            onCreated(g)
            dismiss()
        } catch {
            self.error = Self.friendlyCreateError(error)
        }
    }

    private static func friendlyCreateError(_ error: Error) -> String {
        if let apiErr = error as? APIError, case .http(403, let body) = apiErr,
           (body ?? "").contains("invite") {
            return "create_group.error.invites_blocked".localized
        }
        return String(format: "create_group.error".localized, APIErrorPresenter.friendly(error))
    }
}
