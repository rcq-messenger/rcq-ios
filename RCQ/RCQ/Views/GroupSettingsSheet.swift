import SwiftUI

/// All owner/moderator group controls in one sheet: name, description,
/// photo, pinned announcement, and the owner-only rules of the room: who
/// may post, whether it is closed, whether the roster is hidden, whether
/// links and files are allowed, and the slowmode step. Group Info used to
/// scatter these inline (rename in the header, description block, an "owner
/// settings" block); the list grew long enough to deserve its own surface,
/// reached via the gear button in Group Info.
///
/// The gates are the island's own (`patch_group`): the `info` capability
/// edits name / description / picture / pin, and only the OWNER decides who
/// posts, whether the group is closed, whether the roster is hidden, and the
/// content policy. Section order mirrors the desktop's GroupSettingsModal so
/// the same room reads the same on both.
struct GroupSettingsSheet: View {
    let groupID: Int

    @Environment(\.dismiss) private var dismiss
    @StateObject private var groups = GroupService.shared

    @State private var nameDraft: String = ""
    @State private var descriptionDraft: String = ""
    @State private var pinnedDraft: String = ""
    @State private var savingName = false
    @State private var savingDescription = false
    @State private var savingPin = false
    @State private var avatarUploading = false
    @State private var confirmAvatarRemove = false
    @State private var error: String?

    /// Live positions of the three content-policy controls.
    ///
    /// Held here rather than read straight off `GroupService.rules` because
    /// that map is only written when the PATCH comes back. Driving a Toggle
    /// from it means the knob shows the OLD rule until the round trip lands,
    /// and any emission from the service in between (a group-list poll, an
    /// unread bump) re-evaluates this body and visibly snaps the knob back.
    /// So: write the control's position immediately, roll it back and say why
    /// if the island refuses.
    @State private var noLinks = false
    @State private var noFiles = false
    @State private var slowmode = 0
    @State private var ageGate = 0

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
                        // Photo first, above the name (founder request).
                        avatarSection(g)
                        nameSection(g)
                        descriptionSection(g)
                        pinSection(g)
                        if amOwner {
                            audienceSection(g)
                            contentPolicySection()
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
                pinnedDraft = g.pinnedText ?? ""
            }
            // The rules of the room do not live on the group row (see
            // `GroupService.RoomRules`), and the toggles here must never draw
            // a permissive default over a room that has them switched off.
            // This is the roster-less list, not a per-group fetch.
            //
            // Seeded twice on purpose: once from whatever the service already
            // holds so the controls open in the right position, once from the
            // island's answer.
            .task {
                seedRules()
                await groups.refreshRules()
                seedRules()
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
    private func pinSection(_ g: RCQGroup) -> some View {
        Section {
            TextField(
                "group.pin.placeholder".localized,
                text: $pinnedDraft,
                axis: .vertical,
            )
            .lineLimit(2...6)
            .foregroundColor(Theme.Color.textPrimary)
            // The slot is 500 characters and the server refuses a longer body
            // outright, so the field stops growing there instead of letting a
            // save fail for a reason nobody could see.
            .onChange(of: pinnedDraft) { newValue in
                let capped = GroupService.cappedPinnedInput(newValue)
                if capped != newValue { pinnedDraft = capped }
            }
            HStack {
                Text("group.pin.hint".localized)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
                // Counter appears only near the ceiling: a running "12/500"
                // over an empty field is noise.
                if pinnedDraft.unicodeScalars.count > GroupService.pinnedTextLimit - 60 {
                    Text(String(pinnedDraft.unicodeScalars.count) + "/" + String(GroupService.pinnedTextLimit))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Theme.Color.textSecondary)
                        .padding(.trailing, 6)
                }
                Group {
                    if savingPin {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("common.save".localized) {
                            Task { await savePin() }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                        .disabled(pinnedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                  == (g.pinnedText ?? ""))
                    }
                }
                .frame(height: 20)
            }
        } header: {
            Text("group.section.pin".localized)
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

            Toggle(isOn: Binding(
                get: { g.inCatalog },
                set: { v in Task { try? await groups.setInCatalog(groupID: groupID, listed: v) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("group.settings.catalog".localized)
                        .foregroundColor(Theme.Color.textPrimary)
                    Text("group.settings.catalog.hint".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Theme.Color.accent)
        } header: {
            Text("group.section.settings".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    /// Owner-only rules of the room: what may be posted in it and how often.
    /// The two toggles read as RESTRICTIONS ("disable links") while the wire
    /// carries the allowed-flags, hence the inversion. Same wording and same
    /// inversion as the desktop, so an owner switching between the two does
    /// not have to re-read which way the switch points.
    ///
    /// ⚠ Both are client-honored: the island cannot see inside a sealed
    /// envelope, so it publishes the rule and every client obeys it. Slowmode
    /// is the one the island enforces itself.
    @ViewBuilder
    private func contentPolicySection() -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { noLinks },
                set: { off in applyLinks(off) }
            )) {
                settingLabel("group.settings.no_links", hint: "group.settings.no_links.hint")
            }
            .tint(Theme.Color.accent)

            Toggle(isOn: Binding(
                get: { noFiles },
                set: { off in applyFiles(off) }
            )) {
                settingLabel("group.settings.no_files", hint: "group.settings.no_files.hint")
            }
            .tint(Theme.Color.accent)

            VStack(alignment: .leading, spacing: 8) {
                settingLabel("group.settings.slowmode", hint: "group.settings.slowmode.hint")
                Picker(
                    "group.settings.slowmode".localized,
                    selection: Binding(
                        get: { slowmode },
                        set: { v in applySlowmode(v) }
                    )
                ) {
                    ForEach(GroupService.RoomRules.slowmodeSteps, id: \.self) { step in
                        Text(Self.slowmodeLabel(step)).tag(step)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 2)

            // Anti-spam age floor (#803): accounts younger than the step
            // read but cannot post; the island enforces it.
            VStack(alignment: .leading, spacing: 8) {
                settingLabel("group.settings.age_gate", hint: "group.settings.age_gate.hint")
                Picker(
                    "group.settings.age_gate".localized,
                    selection: Binding(
                        get: { ageGate },
                        set: { v in applyAgeGate(v) }
                    )
                ) {
                    ForEach(GroupService.RoomRules.ageGateSteps, id: \.self) { step in
                        Text(Self.ageGateLabel(step)).tag(step)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 2)
        } header: {
            Text("group.section.content_policy".localized)
        }
        .listRowBackground(Theme.Color.bgSecondary)
    }

    /// One step of the slowmode picker. The menu is fixed (`_SLOWMODE_STEPS`
    /// on the island) so every client shows the same five buttons.
    private static func slowmodeLabel(_ seconds: Int) -> String {
        if seconds <= 0 { return "group.settings.slowmode.off".localized }
        if seconds < 60 { return String(format: "group.settings.slowmode.sec".localized, seconds) }
        return "group.settings.slowmode.min".localized
    }

    /// Fixed menu (`_AGE_GATE_STEPS`), unit-neutral like the Android row.
    private static func ageGateLabel(_ hours: Int) -> String {
        if hours <= 0 { return "group.settings.slowmode.off".localized }
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private func settingLabel(_ title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.localized)
                .foregroundColor(Theme.Color.textPrimary)
            Text(hint.localized)
                .font(.caption2)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Content policy

    /// Put the three controls where the room's rules say they belong.
    private func seedRules() {
        let r = groups.rules(groupID)
        noLinks = !r.linksAllowed
        noFiles = !r.filesAllowed
        slowmode = r.slowmodeSec
        ageGate = r.minAccountAgeHours
    }

    /// One shape for all three: move the control now, PATCH, and on a refusal
    /// (offline, not the owner any more, a step the island does not take) put
    /// it back where it was and say what happened. A switch that reverts on
    /// its own with no message reads as "the room is frozen" when it is not.
    private func applyLinks(_ off: Bool) {
        let previous = noLinks
        noLinks = off
        Task {
            do { try await groups.setLinksAllowed(groupID: groupID, allowed: !off) }
            catch {
                noLinks = previous
                self.error = error.localizedDescription
            }
        }
    }

    private func applyFiles(_ off: Bool) {
        let previous = noFiles
        noFiles = off
        Task {
            do { try await groups.setFilesAllowed(groupID: groupID, allowed: !off) }
            catch {
                noFiles = previous
                self.error = error.localizedDescription
            }
        }
    }

    private func applyAgeGate(_ hours: Int) {
        let previous = ageGate
        guard GroupService.RoomRules.ageGateSteps.contains(hours) else { return }
        ageGate = hours
        Task {
            do { try await groups.setAgeGate(groupID: groupID, hours: hours) }
            catch {
                ageGate = previous
                self.error = error.localizedDescription
            }
        }
    }

    private func applySlowmode(_ seconds: Int) {
        let previous = slowmode
        // The picker only offers `slowmodeSteps`, and `setSlowmode` returns
        // without a PATCH for anything else. Refuse it here too rather than
        // leave the segment sitting on a value nobody stored.
        guard GroupService.RoomRules.slowmodeSteps.contains(seconds) else { return }
        slowmode = seconds
        Task {
            do { try await groups.setSlowmode(groupID: groupID, seconds: seconds) }
            catch {
                slowmode = previous
                self.error = error.localizedDescription
            }
        }
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

    private func savePin() async {
        savingPin = true
        defer { savingPin = false }
        let trimmed = pinnedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try await groups.setPinnedText(groupID: groupID, pinnedText: trimmed) }
        catch { self.error = GroupService.pinFailureMessage(error) }
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
