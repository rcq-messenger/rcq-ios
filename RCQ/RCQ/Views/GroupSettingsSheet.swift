import SwiftUI

/// All owner/admin group controls in one sheet — name, description,
/// photo, post policy, entry price, closed flag, member-roster
/// visibility. Group Info used to scatter these inline (rename in the
/// header, description block, an "owner settings" block); the list
/// grew long enough to deserve its own surface, reached via the gear
/// button in Group Info.
struct GroupSettingsSheet: View {
    let groupID: Int

    @Environment(\.dismiss) private var dismiss
    @StateObject private var groups = GroupService.shared

    @State private var nameDraft: String = ""
    @State private var descriptionDraft: String = ""
    @State private var entryPriceText: String = ""
    @State private var savingName = false
    @State private var savingDescription = false
    @State private var savingPrice = false
    @State private var avatarUploading = false
    @State private var confirmAvatarRemove = false
    @State private var error: String?

    private var currentGroup: RCQGroup? { groups.find(groupID) }

    /// Owner-only fields (post policy / price / closed / hide members)
    /// vs admin-or-owner fields (name / description / avatar) — mirrors
    /// the backend PATCH gates.
    private var amOwner: Bool {
        AuthService.shared.ownUIN == currentGroup?.ownerUIN
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if let g = currentGroup {
                    Form {
                        nameSection(g)
                        descriptionSection(g)
                        avatarSection(g)
                        if amOwner {
                            audienceSection(g)
                        }
                        if let error {
                            Section {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(Theme.Color.statusBusy)
                            }
                            .listRowBackground(Theme.Color.bgSecondary)
                        }
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    Text("group.unavailable".localized)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            .navigationTitle("group.section.settings".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .onAppear {
                guard let g = currentGroup else { return }
                nameDraft = g.name
                descriptionDraft = g.description ?? ""
                entryPriceText = g.entryPriceTokens.map(String.init) ?? ""
            }
            .confirmationDialog(
                "group.avatar.remove.confirm".localized,
                isPresented: $confirmAvatarRemove,
                titleVisibility: .visible,
            ) {
                Button("group.avatar.remove".localized, role: .destructive) {
                    Task { await removeAvatar() }
                }
                Button("common.cancel".localized, role: .cancel) {}
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func nameSection(_ g: RCQGroup) -> some View {
        Section {
            HStack {
                TextField("group.settings.name".localized, text: $nameDraft)
                    .foregroundColor(Theme.Color.textPrimary)
                if savingName {
                    ProgressView().controlSize(.small)
                } else if nameDraft.trimmingCharacters(in: .whitespaces) != g.name {
                    Button("common.save".localized) {
                        Task { await saveName() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
                }
            }
        } header: {
            Text("group.settings.name".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    @ViewBuilder
    private func descriptionSection(_ g: RCQGroup) -> some View {
        Section {
            TextField(
                "group.description.placeholder".localized,
                text: $descriptionDraft,
                axis: .vertical,
            )
            .lineLimit(2...6)
            .foregroundColor(Theme.Color.textPrimary)
            HStack {
                Text("group.description.hint".localized)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
                Group {
                    if savingDescription {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("common.save".localized) {
                            Task { await saveDescription() }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                        .disabled(descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                  == (g.description ?? ""))
                    }
                }
                .frame(height: 20)
            }
        } header: {
            Text("group.section.description".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    @ViewBuilder
    private func avatarSection(_ g: RCQGroup) -> some View {
        Section {
            HStack(spacing: 12) {
                // Tap the avatar itself to change. Pencil glyph reads
                // as edit affordance.
                Button {
                    presentAvatarPicker()
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        GroupAvatarView(
                            mediaID: g.avatarMediaID,
                            keyBase64: g.avatarMediaKey,
                            size: 44,
                            glyphSize: 22,
                        )
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .background(
                                Circle().fill(Theme.Color.accent)
                            )
                            .offset(x: 2, y: 2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(avatarUploading)
                if avatarUploading {
                    ProgressView().controlSize(.small)
                } else {
                    Button("group.settings.change_photo".localized) {
                        presentAvatarPicker()
                    }
                    .foregroundColor(Theme.Color.accent)
                }
                Spacer()
                if g.avatarMediaID != nil && !avatarUploading {
                    Button(role: .destructive) {
                        confirmAvatarRemove = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
        } header: {
            Text("group.settings.photo".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    /// Single entry point for the photo / GIF picker. Imperative
    /// present — `.sheet`-hosted PHPicker trips the iOS-26
    /// cascade-dismiss bug. Same pattern as
    /// PremiumComposerSheet.launchPhotoPicker.
    private func presentAvatarPicker() {
        guard !avatarUploading else { return }
        ImperativePicker.pickPhotoOrGIF { media in
            switch media {
            case .photo(let img):
                Task { await uploadAvatar(image: img) }
            case .gif(let data, _):
                Task { await uploadAvatar(gifData: data) }
            case .video, .none:
                break
            }
        }
    }

    @ViewBuilder
    private func audienceSection(_ g: RCQGroup) -> some View {
        Section {
            Picker(
                "group.settings.post_policy".localized,
                selection: Binding(
                    get: { g.postPolicy },
                    set: { v in Task { try? await groups.setPostPolicy(groupID: groupID, policy: v) } }
                )
            ) {
                Text("group.settings.post_policy.all".localized).tag("all")
                Text("group.settings.post_policy.owner_only".localized).tag("owner_only")
            }
            .foregroundColor(Theme.Color.textPrimary)

            HStack {
                ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                    .frame(width: 18, height: 18)
                TextField("0", text: Binding(
                    get: { entryPriceText },
                    set: { entryPriceText = $0.filter { $0.isNumber } }
                ))
                .keyboardType(.numberPad)
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(Theme.Color.textPrimary)
                Spacer()
                if savingPrice {
                    ProgressView().controlSize(.small)
                } else if (Int(entryPriceText) ?? 0) != (g.entryPriceTokens ?? 0) {
                    Button("common.save".localized) {
                        Task { await saveEntryPrice() }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
                }
            }

            Toggle(isOn: Binding(
                get: { g.isClosed },
                set: { v in Task { try? await groups.setIsClosed(groupID: groupID, isClosed: v) } }
            )) {
                Text("group.settings.closed".localized)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .tint(Theme.Color.accent)

            Toggle(isOn: Binding(
                get: { g.membersHidden },
                set: { v in Task { try? await groups.setMembersHidden(groupID: groupID, hidden: v) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("group.settings.hide_members".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Text("group.settings.hide_members.hint".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.Color.accent)
        } header: {
            Text("group.section.settings".localized)
        } footer: {
            Text("group.settings.entry_price.hint".localized)
                .font(.caption2)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    // MARK: - Actions

    private func saveName() async {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != currentGroup?.name else { return }
        savingName = true
        defer { savingName = false }
        do { try await groups.rename(groupID: groupID, name: trimmed) }
        catch { self.error = error.localizedDescription }
    }

    private func saveDescription() async {
        savingDescription = true
        defer { savingDescription = false }
        let trimmed = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try await groups.setDescription(groupID: groupID, description: trimmed) }
        catch { self.error = error.localizedDescription }
    }

    private func saveEntryPrice() async {
        savingPrice = true
        defer { savingPrice = false }
        do { try await groups.setEntryPrice(groupID: groupID, priceTokens: max(0, Int(entryPriceText) ?? 0)) }
        catch { self.error = error.localizedDescription }
    }

    private func uploadAvatar(image: UIImage) async {
        avatarUploading = true
        defer { avatarUploading = false }
        do {
            let res = try await MediaService.shared.uploadImage(image)
            try await groups.setAvatar(groupID: groupID, mediaID: res.mediaID, keyBase64: res.keyBase64)
        } catch {
            self.error = String(format: "group.avatar.upload_error".localized, error.localizedDescription)
        }
    }

    /// GIF avatar — raw-byte upload so frames survive (the still-image
    /// path JPEG-encodes).
    private func uploadAvatar(gifData: Data) async {
        avatarUploading = true
        defer { avatarUploading = false }
        do {
            let res = try await MediaService.shared.uploadGIF(data: gifData)
            try await groups.setAvatar(groupID: groupID, mediaID: res.mediaID, keyBase64: res.keyBase64)
        } catch {
            self.error = String(format: "group.avatar.upload_error".localized, error.localizedDescription)
        }
    }

    private func removeAvatar() async {
        avatarUploading = true
        defer { avatarUploading = false }
        do { try await groups.setAvatar(groupID: groupID, mediaID: nil, keyBase64: nil) }
        catch { self.error = String(format: "group.avatar.upload_error".localized, error.localizedDescription) }
    }
}
