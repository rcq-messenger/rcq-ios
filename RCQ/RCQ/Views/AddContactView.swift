import SwiftUI

struct AddContactView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var groupSvc = GroupService.shared
    @State private var query: String = ""
    @State private var results: [UserProfile] = []
    @State private var loading = false
    @State private var sentTo: Set<Int> = []
    /// Server-fetched previews of foreign (non-member) groups matching
    /// the query — by exact id when numeric, by name substring otherwise.
    /// Drives the "Join group" affordances at the top of the result list.
    @State private var foreignGroups: [GroupService.Preview] = []
    /// Debounce token so per-keystroke searches don't fan out a request
    /// for every typed character. Replaced on each query change; the
    /// previous task self-cancels via the equality guard inside.
    @State private var searchTask: Task<Void, Never>?
    /// Active "Join group" sheet target. Set on tap of the preview row.
    @State private var joinPreview: GroupService.Preview?
    /// Pre-filled UIN from an `rcq://add/{uin}` deep link. When set, the search
    /// is kicked off immediately on appear so the user lands on the target row.
    var prefillUIN: Int? = nil
    /// Optional callback so the caller (ContactListView) can dismiss this sheet
    /// and push the group chat onto its NavigationStack when a group result is
    /// tapped — Telegram-style mixed search.
    var onSelectGroup: ((RCQGroup) -> Void)? = nil

    /// Local-filter my groups by name or id substring.
    private var groupMatches: [RCQGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return groupSvc.groups.filter {
            $0.name.lowercased().contains(q) || String($0.id).contains(q)
        }
    }

    /// Trimmed-and-lowercased query — used both for the local
    /// groups filter and as the cancellation key on the debounced
    /// foreign-group search.
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces)
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
                    query = String(uin)
                    await search()
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

    /// Debounced foreign-group search. Cancels any in-flight task on
    /// each keystroke and waits 300ms before hitting the server, so
    /// fast typists don't fan out one request per character. Local
    /// own-group matches are excluded server-side via the caller-uin
    /// filter on `/groups/search`.
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
            // Race guard — query may have changed during the request.
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
        do {
            let rows: [UserProfile] = try await APIClient.shared.request(
                "GET", "/users/search", query: ["q": q, "limit": "30"]
            )
            // Defensive: hide the caller from their own search even if an older
            // backend forgets. Server-side filter is the real fix; this is a belt.
            let me = AuthService.shared.ownUIN
            self.results = rows.filter { $0.uin != me }
        } catch { }
    }
}

/// Foreign-group preview row — surfaced when the user types a
/// numeric id we don't already belong to. Shows the price tag prominently
/// when the group is paid; tap routes to `JoinGroupSheet`.
private struct GroupPreviewHit: View {
    let preview: GroupService.Preview

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.Color.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.name)
                    .font(Theme.Font.nickname)
                    .foregroundColor(Theme.Color.textPrimary)
                HStack(spacing: 4) {
                    Text(String(
                        format: (preview.memberCount == 1
                            ? "contact_list.members_one"
                            : "contact_list.members_many").localized,
                        preview.memberCount,
                    ))
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
            // Price chip when paid, else a join chevron.
            if let price = preview.entryPriceTokens, price > 0 {
                HStack(spacing: 3) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 14, height: 14)
                    Text("\(price)")
                        .font(.system(.callout, weight: .bold).monospacedDigit())
                        .foregroundColor(Theme.Color.textPrimary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.Color.accent.opacity(0.15))
                .cornerRadius(6)
            } else {
                Image(systemName: "chevron.right").foregroundColor(Theme.Color.textSecondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Modal sheet shown when the user taps a foreign-group preview row.
/// Renders the deal one more time + the explicit Join CTA. On
/// success the parent dismisses itself and routes the user into the
/// group's chat.
struct JoinGroupSheet: View {
    let preview: GroupService.Preview
    var onJoined: (RCQGroup) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var groups = GroupService.shared
    @StateObject private var items = ItemsService.shared
    @State private var busy: Bool = false
    @State private var alertMessage: String?

    private var price: Int { preview.entryPriceTokens ?? 0 }
    private var canAfford: Bool { items.wallet.tokens >= price }

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
                        Text(String(
                            format: (preview.memberCount == 1
                                ? "contact_list.members_one"
                                : "contact_list.members_many").localized,
                            preview.memberCount,
                        ))
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary)
                    }
                    if price > 0 {
                        priceBlock
                    }
                    Button {
                        Task { await join() }
                    } label: {
                        Text(price > 0
                             ? (canAfford
                                ? "join_group.cta.pay".localized
                                : "join_group.cta.insufficient".localized)
                             : "join_group.cta.free".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(price > 0 && !canAfford
                                        ? Theme.Color.divider
                                        : Theme.Color.accent)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || (price > 0 && !canAfford))
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

    private var priceBlock: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("join_group.entry_price".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                HStack(spacing: 4) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 18, height: 18)
                    Text("\(price)")
                        .font(.system(.title2, weight: .bold).monospacedDigit())
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("join_group.your_balance".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                HStack(spacing: 3) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 14, height: 14)
                    Text("\(items.wallet.tokens)")
                        .font(.system(.callout, weight: .semibold).monospacedDigit())
                        .foregroundColor(canAfford ? Theme.Color.textPrimary : .red)
                }
            }
        }
        .padding(14)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(8)
    }

    private func join() async {
        busy = true
        defer { busy = false }
        let result = await groups.join(groupID: preview.id)
        switch result {
        case .success(let g):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onJoined(g)
        case .insufficientTokens(let req, let have):
            alertMessage = String(format: "join_group.error.insufficient".localized, req, have)
        case .blocked:
            alertMessage = "join_group.error.blocked".localized
        case .other(let m):
            alertMessage = m.isEmpty ? "join_group.error.generic".localized : m
        }
    }
}

private struct GroupHit: View {
    let group: RCQGroup

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 14))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.Color.accent))
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(Theme.Font.nickname).foregroundColor(Theme.Color.textPrimary)
                Text(String(
                    format: (group.members.count == 1
                        ? "contact_list.members_one"
                        : "contact_list.members_many").localized,
                    group.members.count
                ))
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
                Text(String(user.uin)).font(Theme.Font.monoSmall).foregroundColor(Theme.Color.textMono)
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
    @State private var showInventory = false
    @State private var showTrade = false

    /// True if `user` is already in our contact list — the backend will reject a
    /// duplicate Add anyway, but we hide the button preemptively for a cleaner UX.
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
                Text(String(user.uin)).font(Theme.Font.mono).foregroundColor(Theme.Color.textMono)
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

                // Inventory + Propose-trade affordances. The trade
                // system is open by default — anyone can propose
                // (subject to the recipient's `trade_policy`), so a
                // user can be encountered via search and exchange
                // gifts without being a mutual contact first.
                HStack(spacing: 8) {
                    Button {
                        showInventory = true
                    } label: {
                        Label("add.inventory".localized, systemImage: "shippingbox")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.Color.bgSecondary)
                            .foregroundColor(Theme.Color.textPrimary)
                            .cornerRadius(4)
                    }
                    // Trade button — accent green to match the
                    // primary "propose trade" CTA on UserInfoView.
                    // Inventory stays neutral; Trade is the affordance
                    // we're nudging toward.
                    Button {
                        showTrade = true
                    } label: {
                        Label("add.trade".localized, systemImage: "arrow.left.arrow.right")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.Color.accent)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                }
                .padding(.horizontal, 24)

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
        .fullScreenCover(isPresented: $showInventory) {
            PublicInventoryView(uin: user.uin, nickname: user.nickname)
        }
        .sheet(isPresented: $showTrade) {
            TradeProposeView(recipientUIN: user.uin, recipientNickname: user.nickname)
        }
    }

    private func sendRequest() async {
        sending = true
        errorMessage = nil
        defer { sending = false }
        do {
            try await ContactService.shared.sendAddRequest(to: user.uin)
            onSent()
            sent = true
            // The auto-accept branch on the backend may have already made us mutual
            // contacts; refresh to reflect that without waiting for a presence event.
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

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if contacts.pendingRequests.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(contacts.pendingRequests) { req in
                            requestRow(req)
                                .listRowBackground(Theme.Color.bgSecondary)
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .opacity.combined(with: .move(edge: .trailing))
                                ))
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
        }
        // Compact by default — most users have 0–1 pending requests at a
        // time, so the half-screen `.medium` was too tall. Drag-up to expand
        // when the queue actually has volume.
        .presentationDetents([.fraction(0.32), .large])
        .presentationDragIndicator(.visible)
    }

    private func requestRow(_ req: ContactService.PendingRequest) -> some View {
        // `String(req.from_uin)` bypasses Text's locale-aware number
        // formatting — without it, "100,000,000" renders with grouping
        // separators (spaces in RU, commas in US, etc.) which reads as
        // junk inside parentheses.
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "pending.row.body".localized, req.nickname, String(req.from_uin)))
                .font(.body)
                .foregroundColor(Theme.Color.textPrimary)
            HStack(spacing: 12) {
                Button("pending.cta.accept".localized) {
                    Task { try? await contacts.respond(requestID: req.id, accept: true) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.Color.statusOnline)
                Button("pending.cta.decline".localized) {
                    Task { try? await contacts.respond(requestID: req.id, accept: false) }
                }
                .buttonStyle(.bordered).tint(Theme.Color.statusBusy)
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
