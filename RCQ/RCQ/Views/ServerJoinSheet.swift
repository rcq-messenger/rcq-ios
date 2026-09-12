import SwiftUI

/// Confirmation sheet for an `rcq://server/<host>?invite=<code>` deep link — the
/// QR/link an operator of an invite-only island shares. Adds the island as a new
/// account (threading the invite token through register for closed servers).
struct ServerJoinSheet: View {
    let request: AppState.ServerJoinRequest
    var onJoined: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var joining = false
    @State private var error: String?
    /// Typed here when the link carried no code and the island turns out to
    /// want one. A shared `rcq://server/<host>` without `?invite=` is an
    /// ordinary thing for an operator to hand out, and this sheet used to send
    /// it at a shut door and report "could not connect".
    @State private var code: String = ""
    @State private var detent: PresentationDetent = .medium
    /// The island's own description, asked of the island. Both fields have been
    /// served forever and shown nowhere, so an operator could name their island
    /// and set house rules that no one could ever read. This is the screen they
    /// are for.
    @State private var info: ServerInfoResponse?

    /// The island wants a code and the link did not bring one.
    private var asksForCode: Bool {
        request.invite == nil && (info?.capabilities.needsAccessCode ?? false)
    }

    /// The island SELLS entry rather than keeping a guest list. Same field,
    /// same button, different sentence: "a code from its operator" is an
    /// errand nobody can run on a $15 island.
    ///
    /// ⚠ The policy counts as well as the price, so an island that sells entry
    /// without publishing what it costs still gets the right words.
    private var paidDoor: Bool {
        guard let caps = info?.capabilities else { return false }
        return caps.entryPriceCents > 0 || caps.registrationPolicy.lowercased() == "paid"
    }

    private var typedCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// What register is handed: the link's code when it had one, otherwise
    /// whatever was typed, and nil when there is neither.
    private var effectiveInvite: String? {
        if let fromLink = request.invite, !fromLink.isEmpty { return fromLink }
        return typedCode.isEmpty ? nil : typedCode
    }

    /// Bare domain from the link → a full https URL the app can register against.
    private var serverURL: String {
        let h = request.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("http://") || h.hasPrefix("https://") { return h }
        return "https://\(h)"
    }

    var body: some View {
        VStack(spacing: 16) {
            // Was `server.rack`: the same drawing on every island, on the one
            // screen where somebody decides whether to go to THIS one. The
            // island's own logo now, or its lettered tile while the reply is in
            // the air, for an island that set none, and for one that never
            // answers at all.
            IslandAvatarView(
                name: info?.name ?? "",
                host: request.host,
                logoVersion: info?.logoVersion ?? "",
                size: 56
            )
            .padding(.top, 8)

            Text(info?.name.isEmpty == false ? (info?.name ?? "") : "serverjoin.title".localized)
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)
                .multilineTextAlignment(.center)

            Text(request.host)
                .font(.callout.weight(.medium))
                .foregroundColor(Theme.Color.accent)
                .lineLimit(1)
                .truncationMode(.middle)

            Text((asksForCode ? (paidDoor ? "reg.entry.required" : "island.door.body")
                  : request.invite == nil ? "serverjoin.body_open"
                  : "serverjoin.body").localized)
                .font(.footnote)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if asksForCode {
                TextField("reg.invite.label".localized, text: $code)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(Theme.Color.textPrimary)
                    .padding(12)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(10)
            }

            // House rules, if the operator wrote any. Scrolls under a cap: a
            // long set is exactly what pushes the buttons off a sheet.
            if let rules = info?.welcome, !rules.isEmpty {
                ScrollView {
                    Text(rules)
                        .font(.footnote)
                        .foregroundColor(Theme.Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 180)
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            Button {
                Task { await join() }
            } label: {
                Group {
                    if joining { ProgressView().tint(.white) }
                    else { Text("serverjoin.join".localized).fontWeight(.semibold) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.Color.accent)
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .disabled(joining || (asksForCode && typedCode.isEmpty))

            Button("common.cancel".localized) { dismiss() }
                .foregroundColor(Theme.Color.textSecondary)
                .disabled(joining)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
        // ⚠ Draggable to full height, and taken there by hand when the code
        // field appears: that field brings the keyboard with it and a fixed
        // `.medium` leaves the keyboard sitting on the two buttons (#867 is
        // what that looks like). The SET stays constant and only the selection
        // moves — swapping the set itself while the sheet is up is what makes
        // it jump.
        .presentationDetents([.medium, .large], selection: $detent)
        .task {
            // Asked of the island being joined, not of the one we are on.
            info = await ServerInfoService.fetch(host: request.host)
            if asksForCode { detent = .large }
        }
    }

    private func join() async {
        if AccountManager.shared.isAtAccountLimit {
            error = String(format: "add_account.limit".localized, AccountManager.maxAccounts)
            return
        }
        joining = true
        error = nil
        // ⚠ Read BEFORE the add: `AccountManager.add` makes the new account
        // active immediately, so afterwards this would name the dangling one.
        let previousActiveID = AccountManager.shared.activeAccountID
        let ok = await AppState.shared.addAccount(serverURL: serverURL, invite: effectiveInvite)
        joining = false
        if !ok {
            error = String(format: "add_account.limit".localized, AccountManager.maxAccounts)
            return
        }
        if let failure = AppState.shared.bootError {
            // Register failed (wrong/expired invite, server unreachable). Undo
            // it whole: remove the dangling account, put the person back on the
            // one they were using, reboot it. Removing alone fell back to the
            // OLDEST account on the device and never rebooted — see
            // `AppState.rollbackFailedAdd`.
            await AppState.shared.rollbackFailedAdd(previousActiveID: previousActiveID)
            if failure.contains("invite_invalid") {
                error = "reg.invite.invalid".localized
            } else if failure.contains("entry_required") {
                // A PAID door refused, not a closed one. "Get a code from the
                // operator" sends a buyer looking for a person; the island is
                // selling entry and the sentence has to say so. Reached
                // whenever the door probe did not land before the tap: the
                // /server/info request still in the air, a probe that failed
                // or failed to decode, a link carrying an empty `?invite=`.
                error = "reg.entry.required".localized
            } else if failure.contains("invite_required") {
                error = "reg.invite.required".localized
            } else {
                error = "serverjoin.error".localized
            }
            return
        }
        onJoined()
        dismiss()
    }
}

/// Confirmation sheet for a scanned `rcq://link?t=&k=` QR (connect to web). On
/// confirm it seals THIS account into the one-time relay so chat.rcq.app logs in
/// as the same identity. The blob carries recovery material, so it confirms
/// first — only continue if the user opened the QR on chat.rcq.app themselves.
struct WebLinkSheet: View {
    let request: AppState.WebLinkRequest
    var onClose: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var error: String?
    @State private var done = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Theme.Color.accent)
                .padding(.top, 8)

            Text(String(format: "weblink.title".localized, request.clientLabel))
                .font(.title3.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)

            Text(done ? "weblink.done".localized : String(format: "weblink.body".localized, request.clientLabel))
                .font(.footnote)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 0)

            if done {
                Button("common.close".localized) { onClose(); dismiss() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.Color.accent)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            } else {
                Button {
                    Task { await connect() }
                } label: {
                    Group {
                        if working { ProgressView().tint(.white) }
                        else { Text("weblink.confirm".localized).fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.Color.accent)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                }
                .disabled(working)

                Button("common.cancel".localized) { onClose(); dismiss() }
                    .foregroundColor(Theme.Color.textSecondary)
                    .disabled(working)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    private func connect() async {
        working = true
        error = nil
        let ok = await AppState.shared.linkWeb(request)
        working = false
        if ok { done = true } else { error = "weblink.error".localized }
    }
}
