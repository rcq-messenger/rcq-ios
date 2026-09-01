import SwiftUI

struct AddContactView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var groupSvc = GroupService.shared
    @State private var query: String = ""
    @State private var results: [UserProfile] = []
    @State private var loading = false
    @State private var sentTo: Set<Int> = []
    @State private var foreignGroups: [GroupService.Preview] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var joinPreview: GroupService.Preview?
    @State private var ciBusy = false
    @State private var ciToken = ""        // optional access token for a foreign PRIVATE island
    @State private var ciTokenErr: String?
    /// Pre-filled UIN from an `rcq://add/{uin}` deep link.
    var prefillUIN: Int? = nil
    /// Island host from the link's `?h=` (spec §5): pre-fills `uin@host` so
    /// the Cross-island row surfaces immediately — one scan, one tap.
    var prefillHost: String? = nil
    var onSelectGroup: ((RCQGroup) -> Void)? = nil

    private var groupMatches: [RCQGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return groupSvc.groups.filter {
            $0.name.lowercased().contains(q) || String($0.id).contains(q)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// Federation (F2): the query parsed as an explicit `uin@host` whose host
    /// is NOT our OWN island, or nil otherwise. Compared to our own island, not
    /// the flagship: a self-hoster on is2 adding `911@api.rcq.app` must see the
    /// flagship as cross-island. Requires an explicit `@` so a bare UIN stays a
    /// normal local search.
    private var crossIsland: RcqFederation.Address? {
        guard trimmedQuery.contains("@"),
              let a = try? RcqFederation.parseAddress(trimmedQuery),
              !Multihome.isOwnHost(a.host) else { return nil }
        return a
    }

    /// True when [a] is one of MY OWN backup-island homes — a backup is the
    /// SAME identity, so "adding" your own copy just hangs as a self-request
    /// (the "four numbers" confusion). Show "this is you" instead.
    private func isOwnAddress(_ a: RcqFederation.Address) -> Bool {
        guard let me = AuthService.shared.ownUIN else { return false }
        return MultihomeStore.shared.list(ownUin: me).contains { $0.host == a.host && $0.uin == a.uin }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundColor(Theme.Color.textSecondary)
                        TextField("add.search.placeholder".localized, text: $query)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit { Task { await search() } }
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(8)
                    .padding(12)

                    if loading {
                        ProgressView().tint(Theme.Color.accent).padding(.top, 32)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if !foreignGroups.isEmpty {
                                    sectionHeader("add.section.join_group".localized)
                                    ForEach(foreignGroups) { preview in
                                        Button {
                                            joinPreview = preview
                                        } label: {
                                            GroupPreviewHit(preview: preview)
                                        }
                                        Divider().background(Theme.Color.divider)
                                    }
                                }
                                if !groupMatches.isEmpty {
                                    sectionHeader("add.section.groups".localized)
                                    ForEach(groupMatches) { g in
                                        Button {
                                            if let onSelectGroup {
                                                onSelectGroup(g)
                                                dismiss()
                                            }
                                        } label: {
                                            GroupHit(group: g)
                                        }
                                        Divider().background(Theme.Color.divider)
                                    }
                                }
                                if let ci = crossIsland, isOwnAddress(ci) {
                                    // Your own backup-island copy — not a contact.
                                    sectionHeader("Cross-island")
                                    HStack(spacing: 12) {
                                        Image(systemName: "person.crop.circle.badge.checkmark").foregroundColor(Theme.Color.textSecondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: "\(ci.uin)@\(ci.host)").foregroundColor(Theme.Color.textPrimary)
                                            Text("ci.add_self".localized)
                                                .font(.caption).foregroundColor(Theme.Color.textSecondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    Divider().background(Theme.Color.divider)
                                } else if let ci = crossIsland {
                                    sectionHeader("Cross-island")
                                    // Optional access token for a foreign PRIVATE (closed) island.
                                    TextField("access_token.label".localized, text: $ciToken)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled(true)
                                        .foregroundColor(Theme.Color.textPrimary)
                                        .padding(.horizontal, 16).padding(.vertical, 8)
                                    if let e = ciTokenErr {
                                        Text(e).font(.caption).foregroundColor(Theme.Color.statusBusy)
                                            .padding(.horizontal, 16)
                                    }
                                    Button {
                                        ciBusy = true; ciTokenErr = nil
                                        Task {
                                            // Redeem the access token for the host FIRST (stores the
                                            // durable token so fetchCard/deposit pass the gate); a bad
                                            // token aborts so the user can fix it.
                                            if !ciToken.trimmingCharacters(in: .whitespaces).isEmpty {
                                                let r = await AccessRedeemer.redeem(host: ci.host, entered: ciToken)
                                                if r == .badToken {
                                                    ciTokenErr = "access_token.bad".localized
                                                    ciBusy = false
                                                    return
                                                }
                                            }
                                            // §5f: this also deposits `act:"request"`
                                            // to their island. If the local row landed
                                            // but the request didn't, say so instead of
                                            // silently implying they were told.
                                            let r = await ContactService.shared.addCrossIslandContact(
                                                uin: ci.uin, host: ci.host, announce: .request
                                            )
                                            ciBusy = false
                                            if r.added && r.announced {
                                                dismiss()
                                            } else if r.added {
                                                ciTokenErr = "ci.request_not_sent".localized
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "globe").foregroundColor(Theme.Color.accent)
                                            VStack(alignment: .leading, spacing: 2) {
                                                // verbatim: LocalizedStringKey would group the uin ("618,917,107").
                                                Text(verbatim: "\(ci.uin)@\(ci.host)").foregroundColor(Theme.Color.textPrimary)
                                                Text("ci.add_row.subtitle".localized)
                                                    .font(.caption).foregroundColor(Theme.Color.textSecondary)
                                            }
                                            Spacer()
                                            if ciBusy { ProgressView().tint(Theme.Color.accent) }
                                        }
                                        .padding(.horizontal, 16).padding(.vertical, 12)
                                        .contentShape(Rectangle())
                                    }
                                    Divider().background(Theme.Color.divider)
                                }
                                if !results.isEmpty {
                                    sectionHeader("add.section.people".localized)
                                    ForEach(results, id: \.uin) { user in
                                        NavigationLink(destination: AddDetailView(user: user, alreadySent: sentTo.contains(user.uin)) {
                                            sentTo.insert(user.uin)
                                        }) {
                                            AddRow(user: user, alreadySent: sentTo.contains(user.uin))
                                        }
                                        Divider().background(Theme.Color.divider)
                                    }
                                }
                            }
                        }
                    }
                    Spacer()
                }
            }
            .navigationTitle("add.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close".localized) { dismiss() } }
            }
            .task {
                if let uin = prefillUIN {
                    if let host = prefillHost, !Multihome.isOwnHost(host) {
                        query = "\(uin)@\(host)"   // surfaces the Cross-island row
                    } else {
                        query = String(uin)
                        await search()
                    }
                }
            }
            .onChange(of: query) { _ in
                scheduleForeignGroupSearch()
            }
            .sheet(item: $joinPreview) { preview in
                JoinGroupSheet(preview: preview, onJoined: { group in
                    joinPreview = nil
                    if let onSelectGroup {
                        onSelectGroup(group)
                    }
                    dismiss()
                })
                .presentationDetents([.fraction(0.5), .large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private func scheduleForeignGroupSearch() {
        searchTask?.cancel()
        let q = trimmedQuery
        guard q.count >= 2 else {
            foreignGroups = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let rows = await groupSvc.search(query: q)
            if !Task.isCancelled, q == trimmedQuery {
                foreignGroups = rows
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(Theme.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Theme.Color.bgSecondary.opacity(0.7))
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        defer { loading = false }
        // `#911` means THAT number and nothing else. A plain `911` keeps the
        // fuzzy search, which is what you want when half-remembering a number or
        // looking for a name — searching for a UIN you already know used to bury
        // it under every account that merely contained those digits (user
        // report). Android parity.
        if q.hasPrefix("#"), let exact = Int(q.dropFirst().trimmingCharacters(in: .whitespaces)), exact > 0 {
            let me = AuthService.shared.ownUIN
            if exact == me { self.results = []; return }
            let hit: UserProfile? = try? await APIClient.shared.request("GET", "/users/\(exact)/info")
            self.results = [hit].compactMap { $0 }
            return
        }
        do {
            let rows: [UserProfile] = try await APIClient.shared.request(
                "GET", "/users/search", query: ["q": q, "limit": "30"]
            )
            // Defensive filter; server should also exclude self.
            let me = AuthService.shared.ownUIN
            self.results = rows.filter { $0.uin != me }
        } catch { }
    }
}

private struct GroupPreviewHit: View {
    let preview: GroupService.Preview

    var body: some View {
        HStack(spacing: 10) {
            GroupAvatarView(
                mediaID: preview.avatarMediaID,
                keyBase64: preview.avatarMediaKey,
                size: 28,
                glyphSize: 14,
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.name)
                    .font(Theme.Font.nickname)
                    .foregroundColor(Theme.Color.textPrimary)
                HStack(spacing: 4) {
                    Text(MemberCountLabel.text(preview.memberCount))
                        .font(Theme.Font.monoSmall)
                        .foregroundColor(Theme.Color.textMono)
                    if let nick = preview.ownerNickname, !nick.isEmpty {
                        Text("·").foregroundColor(Theme.Color.textMono)
                        Image(systemName: "crown.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.Color.textSecondary)
                        Text(nick).font(.caption2).foregroundColor(Theme.Color.textSecondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(Theme.Color.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct JoinGroupSheet: View {
    let preview: GroupService.Preview
    var onJoined: (RCQGroup) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var groups = GroupService.shared
    @State private var busy: Bool = false
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                        .frame(width: 96, height: 96)
                        .background(Circle().fill(Theme.Color.accent))
                        .padding(.top, 12)
                    VStack(spacing: 6) {
                        Text(preview.name).font(.title3.bold())
                            .foregroundColor(Theme.Color.textPrimary)
                            .multilineTextAlignment(.center)
                        Text(MemberCountLabel.text(preview.memberCount))
                            .font(.callout)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    Button {
                        Task { await join() }
                    } label: {
                        Text("join_group.cta.free".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.Color.accent)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("join_group.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
            .alert("join_group.alert.title".localized,
                   isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(alertMessage ?? "") })
        }
    }

    private func join() async {
        busy = true
        defer { busy = false }
        let result = await groups.join(groupID: preview.id)
        switch result {
        case .success(let g):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onJoined(g)
        case .blocked:
            alertMessage = "join_group.error.blocked".localized
        case .closed:
            alertMessage = "group_join.closed_hint".localized
        case .other(let m):
            alertMessage = m.isEmpty ? "join_group.error.generic".localized : m
        }
    }
}

private struct GroupHit: View {
    let group: RCQGroup

    var body: some View {
        HStack(spacing: 10) {
            GroupAvatarView(
                mediaID: group.avatarMediaID,
                keyBase64: group.avatarMediaKey,
                size: 28,
                glyphSize: 14,
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                Text(MemberCountLabel.text(group.memberCount))
                    .font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(Theme.Color.textSecondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct AddRow: View {
    let user: UserProfile
    let alreadySent: Bool
    @StateObject private var contacts = ContactService.shared

    private var alreadyInList: Bool {
        contacts.contacts.contains(where: { $0.uin == user.uin })
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(status: user.status, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.nickname).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                Text(verbatim: "#\(user.uin)").font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
                let parts = [user.city, user.country].compactMap { $0?.isEmpty == false ? $0 : nil }
                if !parts.isEmpty {
                    Text(parts.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            Spacer()
            if alreadyInList {
                Text("add.row.added".localized).font(.caption2).foregroundColor(Theme.Color.statusOnline)
            } else if alreadySent {
                Text("add.row.pending".localized).font(.caption2).foregroundColor(Theme.Color.statusAway)
            } else {
                Image(systemName: "chevron.right").foregroundColor(Theme.Color.textSecondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct AddDetailView: View {
    let user: UserProfile
    let alreadySent: Bool
    let onSent: () -> Void
    @StateObject private var contacts = ContactService.shared
    @State private var sending = false
    @State private var sent = false
    @State private var errorMessage: String? = nil

    private var alreadyInList: Bool {
        contacts.contacts.contains(where: { $0.uin == user.uin })
    }

    private var buttonState: (text: String, disabled: Bool, color: SwiftUI.Color) {
        if alreadyInList { return ("add.cta.in_list".localized, true, Theme.Color.textSecondary.opacity(0.5)) }
        if sending       { return ("add.cta.sending".localized, true, Theme.Color.textSecondary.opacity(0.5)) }
        if sent || alreadySent { return ("add.cta.sent".localized, true, Theme.Color.statusAway) }
        return ("add.cta.add".localized, false, Theme.Color.accent)
    }

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            VStack(spacing: 16) {
                StatusIcon(status: user.status, size: 64)
                Text(user.nickname).font(.title2.bold()).foregroundColor(Theme.Color.textPrimary)
                Text(verbatim: "#\(user.uin)").font(Theme.Font.mono).foregroundColor(Theme.Color.textMono)
                if let about = user.about, !about.isEmpty {
                    Text(about).font(.body).foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
                Button {
                    Task { await sendRequest() }
                } label: {
                    Text(buttonState.text)
                        .font(.system(.body, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(buttonState.color)
                        .cornerRadius(4)
                }
                .padding(.horizontal, 24)
                .disabled(buttonState.disabled)

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(Theme.Color.statusBusy)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer()
            }
            .padding(.top, 24)
        }
        .navigationTitle("add.contact_info".localized)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sendRequest() async {
        sending = true
        errorMessage = nil
        defer { sending = false }
        do {
            try await ContactService.shared.sendAddRequest(to: user.uin)
            onSent()
            sent = true
            // Server may have auto-accepted — refresh without waiting for the WS event.
            await ContactService.shared.refresh()
        } catch let APIError.http(code, _) where code == 409 {
            errorMessage = "add.error.duplicate".localized
            await ContactService.shared.refresh()
        } catch {
            errorMessage = String(format: "add.error.generic".localized, error.localizedDescription)
        }
    }
}

struct PendingRequestsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var contacts = ContactService.shared
    // Variant A: cross-island "message requests" (consent) — held locally.
    @State private var ciRequests: [CrossIslandRequestsStore.Request] = []
    @State private var ciBusy: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if contacts.pendingRequests.isEmpty && ciRequests.isEmpty {
                    emptyState
                } else {
                    List {
                        if !ciRequests.isEmpty {
                            Section("ci.section".localized) {
                                ForEach(ciRequests) { r in
                                    ciRow(r).listRowBackground(Theme.Color.bgSecondary)
                                }
                            }
                        }
                        if !contacts.pendingRequests.isEmpty {
                            Section {
                                ForEach(contacts.pendingRequests) { req in
                                    requestRow(req)
                                        .listRowBackground(Theme.Color.bgSecondary)
                                        .transition(.asymmetric(
                                            insertion: .opacity,
                                            removal: .opacity.combined(with: .move(edge: .trailing))
                                        ))
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .animation(.easeInOut(duration: 0.25), value: contacts.pendingRequests.count)
                }
            }
            .navigationTitle("pending.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.close".localized) { dismiss() } }
            }
            .navigationDestination(for: Int.self) { uin in
                UserInfoView(uin: uin, isOwn: false)
            }
            .onAppear { ciRequests = CrossIslandRequestsStore.shared.list() }
        }
        .presentationDetents([.fraction(0.32), .large])
        .presentationDragIndicator(.visible)
    }

    private func ciRow(_ r: CrossIslandRequestsStore.Request) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // §5f: a real contact request leads with the sender's self-asserted
            // name; the island tag stays on the line below so a lookalike can't
            // pass as a local contact.
            if let nick = r.reqNickname, !nick.isEmpty {
                Text(nick)
                    .font(.body)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            // verbatim: LocalizedStringKey interpolation would render the uin
            // with locale grouping separators ("618,917,107").
            // host "" = a same-island stranger from the Privacy quarantine:
            // render a plain #uin, not a dangling "@".
            Text(verbatim: r.host.isEmpty ? "#\(r.uin)" : "\(r.uin)@\(r.host)")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(r.isContactRequest ? Theme.Color.textSecondary : Theme.Color.textPrimary)
            if r.isContactRequest {
                Text("ci.contactreq.subtitle".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            if let note = r.reqNote, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(2)
            }
            if !r.preview.isEmpty {
                Text(r.preview)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            // Glyphs, not words. Three worded buttons under an address as long
            // as `618917107@is2.rcq.app` wrapped and truncated on anything
            // narrower than a Pro Max, and "Заблокировать" never fit at all.
            // The words stay as the accessibility labels.
            HStack(spacing: 10) {
                RequestActionButton(
                    system: "checkmark",
                    label: "pending.cta.accept".localized,
                    tint: Theme.Color.statusOnline,
                    prominent: true,
                    disabled: ciBusy == r.id
                ) { acceptCI(r) }
                // Decline only makes sense against a §5f request — it deposits
                // `act:"decline"` back so the requester stops waiting. A plain
                // quarantined message has no requester to answer.
                if r.isContactRequest {
                    RequestActionButton(
                        system: "xmark",
                        label: "pending.cta.decline".localized,
                        tint: Theme.Color.textSecondary,
                        disabled: ciBusy == r.id
                    ) { declineCI(r) }
                }
                RequestActionButton(
                    system: "nosign",
                    label: "ci.block".localized,
                    tint: Theme.Color.statusBusy,
                    disabled: ciBusy == r.id
                ) { blockCI(r) }
            }
        }
    }

    private func acceptCI(_ r: CrossIslandRequestsStore.Request) {
        // A SAME-ISLAND stranger (host "" - the opt-in Privacy quarantine):
        // no key card to pin, no §5f dance. Accepting means "let this person
        // talk": remember the allowance, release what they already wrote,
        // surface them in the contact-driven chat list, open the chat.
        if r.host.isEmpty {
            ciBusy = r.id
            StrangerQuarantine.shared.allow(r.uin)
            if let held = CrossIslandRequestsStore.shared.clear(uin: r.uin, host: "") {
                MessageService.shared.releaseHeldStranger(held)
            }
            // My other devices hold their own copy of this row (it arrives
            // without a device id) and would offer to accept it again.
            Task { await MessageService.shared.sendCIAck(uin: r.uin, host: "", act: "accept") }
            ciRequests = CrossIslandRequestsStore.shared.list()
            Task {
                // The quarantine gate deliberately skipped the auto-surface;
                // do it now so the thread renders, then navigate into it via
                // the same pending-open path a push tap uses.
                await ContactService.shared.upsertStranger(uin: r.uin)
                await MainActor.run {
                    ciBusy = nil
                    AppState.shared.pendingOpenChatUIN = r.uin
                    dismiss()
                }
            }
            return
        }
        ciBusy = r.id
        Task {
            // Save the sender as a cross-island contact FIRST, so the held
            // payloads pass the ingest consent-gate (now an accepted contact)
            // and file with the correct sender + kind when replayed.
            //
            // §5f: the add now also deposits `act:"accept"` back to the
            // requester's island, so BOTH sides end up holding the other as
            // accepted — the mutual state §5d's call gate already checks.
            let ok = await ContactService.shared.addCrossIslandContact(
                uin: r.uin, host: r.host, announce: .accept
            ).added
            await MainActor.run {
                if ok, let held = CrossIslandRequestsStore.shared.clear(uin: r.uin, host: r.host) {
                    for h in held.msgs {
                        let packet = WebSocketService.EnvelopePacket(
                            type: "message", payload: h.payload, serverTime: Date(),
                            offline: true, groupID: nil
                        )
                        _ = MessageService.shared.ingest(envelope: packet)
                    }
                }
                ciBusy = nil
                ciRequests = CrossIslandRequestsStore.shared.list()
            }
            // ⚠ The card this device just pinned goes with the ack. Without it
            // the other device would accept a second time and re-TOFU the peer,
            // overwriting the very keys every cross-island message to them is
            // encrypted under.
            if ok, let c = CrossIslandStore.shared.all().first(where: { $0.uin == r.uin && $0.host == r.host }) {
                await MessageService.shared.sendCIAck(
                    uin: r.uin, host: r.host, act: "accept",
                    card: CICard(nick: c.nickname, ik: c.identityKey, sk: c.signingKey,
                                 sik: c.signalIdentityKey, gender: c.gender, status: c.statusMessage)
                )
            }
        }
    }

    /// §5f decline: tell the requester's island, then drop the row. No local
    /// contact is written and no pinned key is touched.
    private func declineCI(_ r: CrossIslandRequestsStore.Request) {
        ciBusy = r.id
        Task {
            await CrossIslandSender.depositContactReq(act: "decline", uin: r.uin, host: r.host)
            await MainActor.run {
                CrossIslandRequestsStore.shared.clear(uin: r.uin, host: r.host)
                ciBusy = nil
                ciRequests = CrossIslandRequestsStore.shared.list()
            }
            await MessageService.shared.sendCIAck(uin: r.uin, host: r.host, act: "decline")
        }
    }

    private func blockCI(_ r: CrossIslandRequestsStore.Request) {
        CrossIslandRequestsStore.shared.block(uin: r.uin, host: r.host)
        Task { await MessageService.shared.sendCIAck(uin: r.uin, host: r.host, act: "block") }
        // A same-island stranger (host "") also joins the native block list:
        // that is the set the ingest drop and the Blocked screen (with its
        // unblock affordance) read, and a blocked stranger with no contact
        // row is dropped silently there - the sender is told nothing.
        if r.host.isEmpty {
            BlockedContactsStore.shared.set(r.uin, blocked: true)
        }
        ciRequests = CrossIslandRequestsStore.shared.list()
    }

    private func requestRow(_ req: ContactService.PendingRequest) -> some View {
        // `String(req.from_uin)` bypasses Text's locale-aware grouping separators.
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink(value: req.from_uin) {
                Text(String(format: "pending.row.body".localized, req.nickname, String(req.from_uin)))
                    .font(.body)
                    .foregroundColor(Theme.Color.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            HStack(spacing: 10) {
                RequestActionButton(
                    system: "checkmark",
                    label: "pending.cta.accept".localized,
                    tint: Theme.Color.statusOnline,
                    prominent: true
                ) {
                    Task { try? await contacts.respond(requestID: req.id, accept: true) }
                }
                RequestActionButton(
                    system: "xmark",
                    label: "pending.cta.decline".localized,
                    tint: Theme.Color.textSecondary
                ) {
                    Task { try? await contacts.respond(requestID: req.id, accept: false) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundColor(Theme.Color.textSecondary)
            Text("pending.empty.title".localized)
                .font(.headline)
                .foregroundColor(Theme.Color.textPrimary)
            Text("pending.empty.body".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var auth = AuthService.shared

    var body: some View {
        NavigationStack {
            if let uin = auth.ownUIN {
                UserInfoView(uin: uin, isOwn: true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("common.close".localized) { dismiss() } }
                    }
            } else {
                Text("add.no_identity".localized).foregroundColor(Theme.Color.textSecondary)
            }
        }
        
    }
}

/// One glyph-sized action on a request row.
///
/// A 44pt square is the smallest thing Apple will call a tap target, and these
/// three sit next to each other under an address, so the icon is drawn small
/// and the frame is padded out to that floor. The word the button used to show
/// becomes its accessibility label, so VoiceOver still says "Принять".
struct RequestActionButton: View {
    let system: String
    let label: String
    let tint: Color
    var prominent: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .foregroundColor(prominent ? tint : tint)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}
