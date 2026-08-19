import os.log
import Intents
import UserNotifications

/// Notification Service Extension. Runs in its own process whenever an
/// APNs push lands with `mutable-content: 1` set. We have ~30s of
/// wallclock and 24MB of memory to:
///
///   1. Pull the encrypted envelope blob out of the push's `userInfo`.
///   2. Decrypt it locally using the X25519/Ed25519 private keys we
///      share with the main app via Keychain Sharing access group
///      `P29Q334JHX.app.rcq.shared`.
///   3. Replace the generic "New message" title/body with the real
///      sender (UIN string for now — contact-name lookup needs a
///      shared-group file we haven't built yet) and the actual message
///      preview.
///
/// If anything goes wrong (no key, malformed payload, decrypt failure)
/// we hand the push back unmodified so the user still sees *something*.
/// Better the generic alert than nothing at all.
///
/// Logs go through `os_log` so they show up in Console.app under the
/// `RCQ.NotificationService` subsystem — main-app `print` output goes to
/// a different log stream.
class NotificationService: UNNotificationServiceExtension {

    private static let log = OSLog(subsystem: "app.rcq.client.notification", category: "NSE")

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.bestAttempt = content

        os_log("didReceive: title=%{public}@ body=%{public}@",
               log: Self.log, type: .default,
               request.content.title, request.content.body)

        let userInfo = request.content.userInfo

        // ⚠ BEFORE anything is rendered, and before the routing below installs
        // a per-account Keychain override. A non-sealed push (contact request,
        // accepted request, trade) carries the SENDER'S NICKNAME in the
        // server-set title, so the no-envelope branch leaks a real name just as
        // readily as a decrypted message does. There is nothing to decrypt on
        // that path and nothing to lose by answering early.
        if userInfo["env"] == nil, AppGroup.pushQuiet() {
            os_log("push-quiet (locked or duress), non-sealed push — generic banner",
                   log: Self.log, type: .default)
            contentHandler(Self.quietContent(from: content))
            return
        }

        guard
            let envB64 = userInfo["env"] as? String,
            let envType = userInfo["envType"] as? String
        else {
            // No `env` field. This is either a non-sealed push
            // (contact_request, trade_received, contact_response_accepted)
            // that we still want to localize off `notif_kind`, or a
            // truly minimal push we just pass through.
            if let kind = userInfo["notif_kind"] as? String {
                applyLocalizedPushBody(kind: kind, to: content)
                os_log("non-env push localized: kind=%{public}@ body=%{public}@",
                       log: Self.log, type: .default, kind, content.body)
            } else {
                os_log("no env/envType/notif_kind in userInfo — passing through unmodified",
                       log: Self.log, type: .default)
            }
            contentHandler(content)
            return
        }
        os_log("env present (len=%d), envType=%{public}@",
               log: Self.log, type: .default, envB64.count, envType)

        // Group mute, checked BEFORE the decrypt: group_id rides in userInfo,
        // so we don't need the plaintext to know the thread. Doing it here
        // means a muted group stays silent even when the decrypt fails (the
        // per-recipient ratchet may already have advanced via the WS path) —
        // the post-decrypt mute check used to be skipped by the catch-block
        // fallthrough, leaking muted-group pushes as the generic banner.
        if let gid = (userInfo["group_id"] as? Int) ?? (userInfo["group_id"] as? NSNumber)?.intValue,
           MutedStore.shared.isGroupMuted(gid) {
            os_log("group %d muted — suppressing", log: Self.log, type: .default, gid)
            contentHandler(UNNotificationContent())
            return
        }

        // Multi-account push routing: the device token is per-device
        // (not per-account), so a push for any local account lands
        // here. If `to_uin` is set on the payload we use it to find
        // which local account owns that UIN, then point KeychainStore
        // + SignalProtocolDB at that account's stores for the
        // decrypt. Without this step a push for a non-active account
        // would resolve to the wrong Keychain prefix and the wrong
        // libsignal local_identity, fail to decrypt, and fall through
        // to the generic "New message" banner.
        //
        // Falls back to the active account if `to_uin` is missing
        // (older backend that doesn't include the field) or no local
        // account owns the value — preserves the pre-multi-account
        // behaviour for any push the lookup can't route.
        let toUIN: Int? = {
            if let v = userInfo["to_uin"] as? Int { return v }
            if let n = userInfo["to_uin"] as? NSNumber { return n.intValue }
            return nil
        }()
        // Capture active before we (possibly) install a per-account
        // override below — comparing target vs original active is
        // what tells us whether this push is for the foreground
        // account or a different one in the local roster.
        let activeBeforeRoute = AppGroup.readActiveAccountID()
        if let toUIN, let targetID = findAccountOwning(uin: toUIN) {
            // Push for a non-foreground account: mark the banner so
            // the user can tell at a glance that this message went
            // to one of their OTHER accounts, not the one they're
            // currently looking at. iOS renders subtitle as the
            // second line below title in the banner. Single-account
            // devices and pushes for the active account skip this —
            // no clutter for the common case.
            if let activeBeforeRoute, activeBeforeRoute != targetID {
                content.subtitle = "#\(toUIN)"
            }
            KeychainStore.setProcessOverrideAccountID(targetID)
            SignalProtocolDB.shared.reload(toAccountID: targetID)
            os_log("routed push to_uin=%d → account=%{public}@",
                   log: Self.log, type: .default, toUIN, targetID.uuidString)
        }

        // A v=2 fan-out copy is sealed to ONE libsignal device, and the push
        // that carries it wakes every install of the account. `toDev` names the
        // one it belongs to; on any other install the decrypt below cannot
        // succeed, and its failure would raise the generic "New message"
        // banner — which is reserved for a ratchet that is actually broken.
        // Read AFTER the account routing above: the device id is per account,
        // and that is where the right account's store gets installed.
        //
        // Only an ADDRESSED copy is suppressed. A decrypt that fails with no
        // `toDev` still surfaces: nothing has said the message is not ours.
        let toDev: Int? = {
            if let v = userInfo["toDev"] as? Int { return v }
            if let n = userInfo["toDev"] as? NSNumber { return n.intValue }
            return nil
        }()
        let myDeviceID = SignalProtocolStores.shared.localDeviceId
        if let toDev, toDev != myDeviceID {
            os_log("fan-out copy for device %d, we are %d — suppressing",
                   log: Self.log, type: .default, toDev, myDeviceID)
            contentHandler(UNNotificationContent())
            return
        }

        guard let crypto = SignalCryptoService.loadFromKeychain(ownUIN: 0) else {
            os_log("no identity in keychain (shared group missing?) — passing through",
                   log: Self.log, type: .error)
            contentHandler(content)
            return
        }

        // Full decrypt is safe to do here as long as we hand the
        // resulting plaintext off to `PushDecryptCache` — the main
        // app's `MessageService.ingest` consults the cache before
        // calling `crypto.decrypt`, so the v=2 libsignal ratchet
        // only advances ONCE (here in the NSE) instead of being
        // double-stepped by NSE + main app and breaking the second
        // decrypt. v=1 envelopes are stateless so the cache is
        // optional for them, but populating it uniformly keeps the
        // ingest-side code path the same for both versions.
        do {
            let decrypted = try crypto.decrypt(envelopeB64: envB64)
            os_log("decrypted OK: from=%d kind=%{public}@",
                   log: Self.log, type: .default,
                   decrypted.senderUIN, envelopeKind(decrypted.envelope))
            // ICQ-style mutual remove: if the user previously dropped this
            // contact, silently suppress the push. PushDecryptCache stays
            // un-touched so the main app's MessageService.ingest can also
            // re-evaluate (and double-drop) when it sees the envelope.
            if RemovedContactsStore.shared.contains(decrypted.senderUIN) {
                contentHandler(UNNotificationContent())
                return
            }
            PushDecryptCache.store(ciphertextB64: envB64, decrypted: decrypted)
            // ⚠ THE DURESS / LOCKED CASE. This process cannot see
            // `PanicPINService` — it is a separate binary in a separate
            // process — so until now it rendered the real sender's name, their
            // avatar thumbnail and a preview of what they wrote regardless of
            // whether the app was PIN-locked or sitting in a decoy session with
            // a coercer holding the phone. The App Group flag is the only thing
            // that crosses the process boundary.
            //
            // The decrypt above still happened and the plaintext is cached, so
            // NOTHING IS LOST: the message threads normally the next time the
            // real session opens. Only the rendering is suppressed, and the
            // fallback is the generic server-side alert — which is exactly what
            // an ordinary account with previews turned off looks like.
            if AppGroup.pushQuiet() {
                os_log("push-quiet (locked or duress) — generic banner",
                       log: Self.log, type: .default)
                contentHandler(Self.quietContent(from: content))
                return
            }
            // Your OWN message coming back to you: a group fan-out from a
            // client that didn't drop the sender, or the same account on a
            // second device. The recipient (`to_uin`) is us, and the
            // decrypted sender is also us. Cached above so the main app
            // still threads it, but we do NOT buzz the user about their
            // own message. (iOS group sends already skip self; this also
            // covers other clients that don't.)
            if let toUIN, decrypted.senderUIN == toUIN {
                contentHandler(UNNotificationContent())
                return
            }
            // secureScreen is the SILENT secure-mode toggle (same "secscreen"
            // push type as a screenshot notice, which we DO want to surface).
            // Cached above so the main app applies the flag, but never buzz the
            // user — only the screenshot-taken notice should alert.
            if case .secureScreen = decrypted.envelope {
                contentHandler(UNNotificationContent())
                return
            }
            // §5f cross-island contact request: not a message, and it must never
            // banner as one. Cached above, so the main app's ingest files it as a
            // pending request (and the pending badge surfaces it) on next launch.
            if case .contactRequest = decrypted.envelope {
                contentHandler(UNNotificationContent())
                return
            }
            // §5e cross-island profile refresh: a name/picture change, not a
            // message, and it must never banner as one. Cached above so the main
            // app's ingest applies it to the stored row on next launch.
            if case .profile = decrypted.envelope {
                contentHandler(UNNotificationContent())
                return
            }
            // Muted: cached above so it still lands in the thread; just no alert.
            let mutedGroupID = (userInfo["group_id"] as? Int) ?? (userInfo["group_id"] as? NSNumber)?.intValue
            let suppressedByMute = mutedGroupID.map { MutedStore.shared.isGroupMuted($0) }
                ?? MutedStore.shared.isMuted(decrypted.senderUIN)
            if suppressedByMute {
                contentHandler(UNNotificationContent())
                return
            }
            // Mentions-only group: alert only when THIS message mentions us
            // (#<our uin>). Cached above so it still threads in-app; just no
            // banner for an ordinary message in a group set to "mentions only".
            if let gid = mutedGroupID, MutedStore.shared.isGroupMentionsOnly(gid),
               !Self.envelopeMentions(decrypted.envelope, uin: toUIN ?? 0) {
                contentHandler(UNNotificationContent())
                return
            }
            apply(decrypted: decrypted, to: content)
            os_log("modified: title=%{public}@ body=%{public}@",
                   log: Self.log, type: .default,
                   content.title, content.body)
            // Communication notification: hands iOS a sender with a picture, so
            // the banner shows the person instead of the app icon (and lands in
            // the Communication section of Focus / Summary). Falls back to the
            // plain content whenever there is no intent to build.
            contentHandler(Self.asCommunication(content, senderUIN: decrypted.senderUIN) ?? content)
        } catch {
            // envType logged too — tells us whether v=1 (stateless ECIES, should
            // never fail) or a v=2 ratchet message is the one failing, for
            // root-causing the "New group message" generic on a device.
            os_log("decrypt failed: envType=%{public}@ %{public}@",
                   log: Self.log, type: .error,
                   envType, String(describing: error))
            // A sender-keys group broadcast (`gmsg`) is NOT decryptable in the
            // NSE process, so the do-block's mute / self-suppress / badge / title
            // never run for it — that was the "RCQ / New group message" banner,
            // no badge, and muted-group-still-alerts report. Reproduce the
            // essentials here for the group fallback.
            if let gid = (userInfo["group_id"] as? Int) ?? (userInfo["group_id"] as? NSNumber)?.intValue {
                // Muted group → no alert (the in-do mute gate isn't reached here).
                if MutedStore.shared.isGroupMuted(gid) {
                    contentHandler(UNNotificationContent())
                    return
                }
                // Mentions-only group + undecryptable gmsg: a mention can't be
                // verified out-of-process, so stay quiet. The in-app path and
                // the home-row @ indicator still surface mentions when the app
                // runs; an offline @mention won't push (sender-keys limit).
                if MutedStore.shared.isGroupMentionsOnly(gid) {
                    contentHandler(UNNotificationContent())
                    return
                }
                // Title with the group name. The backend now sends it plaintext
                // in `group_name` (GroupNameCache is usually empty in the NSE
                // process); fall back to the cache. Localized body.
                let payloadName = userInfo["group_name"] as? String
                let gname = (payloadName?.isEmpty == false ? payloadName : GroupNameCache.name(for: gid))
                if let gname, !gname.isEmpty {
                    content.title = gname
                }
                let localized = Self.pushLocalized("push.group_message.body")
                if !localized.isEmpty && localized != "push.group_message.body" {
                    content.body = localized
                }
                // Bump the icon badge even though we couldn't decrypt — a group
                // message still counts as unread (keyed to the group thread).
                content.badge = NSNumber(value: BadgeCounter.increment(threadKey: "group-\(gid)"))
            }
            contentHandler(content)
        }
    }

    /// Walk the local account roster and return the ID of whichever
    /// account owns the given UIN. Used by the multi-account push
    /// router above. Returns nil if no account matches (push for an
    /// account that's been removed from the device, or for a fresh
    /// install that hasn't run AccountManager yet).
    private func findAccountOwning(uin: Int) -> UUID? {
        let target = String(uin)
        for accountID in AppGroup.readAccountIDs() {
            if KeychainStore.string(KeychainStore.Keys.uin, forAccount: accountID) == target {
                return accountID
            }
        }
        return nil
    }

    /// Sender's name → title; envelope type → body. Falls back to a
    /// non-empty placeholder for any case where the inner content is
    /// empty so iOS doesn't render a notification with a blank body.
    /// Wrap [content] in an INSendMessageIntent so iOS renders it as a message
    /// from a person: their name, their picture, and the Communication grouping.
    ///
    /// The picture comes from the App Group thumbnail the app writes when it
    /// decrypts someone's avatar — the extension cannot decrypt media itself,
    /// and would not have the time budget to if it could. No thumbnail simply
    /// means no image, which is still a communication notification.
    ///
    /// ⚠⚠ DORMANT UNTIL THE App ID GETS "Communication Notifications".
    /// The entitlement is deliberately NOT in the .entitlements files: adding it
    /// before the capability exists on the App ID fails the archive outright
    /// ("Provisioning profile RCQ AppStore Manual doesn't include the
    /// Communication Notifications capability", 2026-08-09), which is worse
    /// than a plain banner. The code stays because it costs nothing while it is
    /// dormant: `updating(from:)` throws without the entitlement and we return
    /// nil, so the notification arrives in its ordinary form.
    ///
    /// To turn it on: enable the capability on app.rcq.client in the developer
    /// portal, regenerate the AppStore profile, then put
    /// `com.apple.developer.usernotifications.communication` back into BOTH
    /// RCQ.entitlements and RCQNotificationService.entitlements.
    private static func asCommunication(
        _ content: UNMutableNotificationContent,
        senderUIN: Int
    ) -> UNNotificationContent? {
        let name = content.title.isEmpty ? "#\(senderUIN)" : content.title
        var image: INImage?
        if let data = AvatarThumbCache.data(for: senderUIN) {
            image = INImage(imageData: data)
        }
        let handle = INPersonHandle(value: String(senderUIN), type: .unknown)
        let sender = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: name,
            image: image,
            contactIdentifier: nil,
            customIdentifier: String(senderUIN)
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: nil,
            conversationIdentifier: content.threadIdentifier,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        return try? content.updating(from: intent)
    }

    private func apply(decrypted: DecryptedEnvelope, to content: UNMutableNotificationContent) {
        // Sender's name. The main app pushes a `uin → nickname` cache
        // into the App Group on every contact-list refresh, so we have
        // a recent value here in most cases. Falls back to a `#UIN`
        // tag when the sender isn't in our contacts (e.g. an open
        // random-chat session, or a contact added on another device).
        let senderNick = NicknameCache.nickname(for: decrypted.senderUIN) ?? "#\(decrypted.senderUIN)"
        content.title = senderNick
        // Group threading by sender so iOS stacks multiple messages
        // from the same UIN into a single notification group AND
        // gives the main app's `didReceive` handler a deterministic
        // `peer-<UIN>` / `group-<GID>` token to parse for tap-routing.
        //
        // Group messages set `group_id` in userInfo (server-side, see
        // apns.send_to_user). When present, thread the notification +
        // badge under `group-<id>` so ChatView.onAppear's per-group
        // reset matches what we just incremented. Without this the
        // increment goes to `peer-<sender>` and never gets cleared.
        let groupID = (content.userInfo["group_id"] as? Int)
            ?? ((content.userInfo["group_id"] as? NSNumber)?.intValue)
        let threadKey: String
        if let gid = groupID {
            threadKey = "group-\(gid)"
        } else {
            threadKey = "peer-\(decrypted.senderUIN)"
        }
        content.threadIdentifier = threadKey

        // User-visible envelopes bump the unread counter so the icon
        // gets a badge. Read receipts / reactions / bounces / edits /
        // delete-for-everyone do NOT bump — they're plumbing the main
        // app handles silently. Setting `content.badge` here is what
        // makes iOS update the icon's red dot; without it iOS leaves
        // the previous value alone (typically 0).
        if Self.envelopeIsUserVisible(decrypted.envelope) {
            let total = BadgeCounter.increment(threadKey: threadKey)
            content.badge = NSNumber(value: total)
        }

        switch decrypted.envelope {
        case .text(_, let text, _, _, _):
            content.body = text.isEmpty ? "Message" : text
        case .photo(_, _, _, let caption, _, _, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "📷 Photo" : "📷 \(cap)"
        case .video(_, _, _, _, _, let caption, _, _, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "🎬 Video" : "🎬 \(cap)"
        case .voice:
            content.body = "🎤 Voice message"
        case .file(_, _, _, let fname, _, _, let caption, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "📎 \(fname)" : "📎 \(fname) — \(cap)"
        case .location(_, _, _, let caption, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "📍 Location" : "📍 Location — \(cap)"
        case .systemNotice(_, let text):
            content.body = text.isEmpty ? "System notice" : text
        case .poll(_, _, let question, _, _, _):
            let q = question.trimmingCharacters(in: .whitespaces)
            content.body = q.isEmpty ? "📊 New poll" : "📊 \(q)"
        case .screenshotTaken:
            content.body = "📸 Screenshot"
        case .relayShare:
            content.body = "🛡️ Shared a connection"
        case .callSignal(_, let sig, _, let ts, _):
            // §5d cross-island call signaling pushed to a backgrounded app.
            // No VoIP push across islands (v1 limit) — at least banner the
            // offer honestly; a stale offer reads as missed.
            if sig == "call_offer" {
                let fresh = Int(Date().timeIntervalSince1970) - ts <= 60
                content.body = fresh ? "📞 Incoming call" : "📞 Missed call"
            } else {
                content.body = "Call update"
            }
        case .deleteForEveryone, .readReceipt, .deliveredReceipt, .reaction, .bounce, .visit, .edit,
             .secureScreen, .carbon, .homeRecord, .skdm, .sknack, .contactRequest,
             .profile,
             // A kind this build cannot read. The generic body is exactly right
             // for it: we know an envelope arrived and nothing more.
             .unknown:
            content.body = "Message"
        }

        // Group message: lead the banner with the GROUP'S name and prefix the
        // body with the sender, so it reads "My Group" / "Alice: hi" instead
        // of just "Alice" / "hi" (founder ask). Falls back to the sender as
        // title when the group name isn't cached yet.
        if let gid = groupID {
            // Title the banner with the group's name so the user can tell WHICH
            // group. Prefer the plaintext name the backend now sends in the push
            // payload (GroupNameCache is usually empty in the NSE process), fall
            // back to the cache, then leave the sender nick as a last resort.
            let payloadName = content.userInfo["group_name"] as? String
            let gname = (payloadName?.isEmpty == false ? payloadName : GroupNameCache.name(for: gid))
            if let gname, !gname.isEmpty {
                content.title = gname
            }
            content.body = "\(senderNick): \(content.body)"
        }
    }

    /// Replace `content.body` with a localized string matching the
    /// `notif_kind` the backend stamped on this push. Reads the
    /// active language from the App Group UserDefaults (mirror of
    /// `LanguageManager.current` written by the main app), then
    /// loads the corresponding lproj from the NSE's own bundle.
    /// Falls back to the development language (en) for any kind we
    /// don't recognise — the original body the backend sent stays
    /// in place as the ultimate fallback if even the en bundle
    /// lookup misses, so the user always sees readable text.
    /// Strip a push down to "something arrived" — no name, no text, no picture,
    /// no per-thread grouping. Used while the app is PIN-locked or in a duress
    /// (decoy) session; see `AppGroup.pushQuiet`.
    ///
    /// The title is scrubbed as hard as the body: the backend puts the SENDER'S
    /// NICKNAME in `content.title` for every non-sealed kind (contact request,
    /// accepted request, trade), so handing the original content back would
    /// have kept the name on the lock screen even with the body replaced.
    /// `threadIdentifier` goes too — "peer-<uin>" is an identifier by itself,
    /// and iOS groups banners visibly by it.
    static func quietContent(from content: UNMutableNotificationContent) -> UNNotificationContent {
        let out = UNMutableNotificationContent()
        let title = pushLocalized("push.quiet.title")
        let body = pushLocalized("push.quiet.body")
        out.title = (title.isEmpty || title == "push.quiet.title") ? "RCQ" : title
        out.body = (body.isEmpty || body == "push.quiet.body") ? "" : body
        out.sound = content.sound
        out.badge = content.badge
        return out
    }

    private func applyLocalizedPushBody(kind: String, to content: UNMutableNotificationContent) {
        let key: String
        // Outbid pushes localize both title + body — every other kind
        // keeps the server-set sender nickname as title.
        var titleKey: String? = nil
        switch kind {
        case "contact_request":           key = "push.contact_request.body"
        case "contact_response_accepted": key = "push.contact_response_accepted.body"
        case "trade_received_gift":       key = "push.trade_received.gift.body"
        case "trade_received_offer":      key = "push.trade_received.offer.body"
        case "uin_auction_outbid":
            key = "push.uin_auction_outbid.body"
            titleKey = "push.uin_auction_outbid.title"
        default: return
        }
        let localized = Self.pushLocalized(key)
        if !localized.isEmpty && localized != key {
            content.body = localized
        }
        if let titleKey {
            let localizedTitle = Self.pushLocalized(titleKey)
            if !localizedTitle.isEmpty && localizedTitle != titleKey {
                content.title = localizedTitle
            }
        }
    }

    /// Look up `key` in NSE's bundled Localizable.strings, using
    /// the language the user picked in the main app (mirrored to
    /// the App Group).
    ///
    /// Resolution order, first hit wins:
    ///   1. `AppGroup.languageFileURL` — flat file the main app's
    ///      `LanguageManager` writes on every set. This is the
    ///      authoritative source. Files are reliable; App Group
    ///      `UserDefaults` is not (cfprefsd "detaches" routinely).
    ///   2. App Group `UserDefaults` mirror — secondary, kept for
    ///      back-compat with already-installed app builds that
    ///      wrote here before we switched to the file mirror.
    ///   3. `Locale.preferredLanguages` — iterate through the
    ///      system's preferred languages until we find one whose
    ///      lproj exists in the NSE bundle. Catches a Russian
    ///      speaker on an English-set iPhone whose Russian sits
    ///      second in the system list (we'd otherwise pick "en"
    ///      from `first` and miss them).
    ///   4. Hardcoded "en" — final fallback.
    ///
    /// Diagnostic logs go through `os_log` at `.default` level so
    /// they show up in Console.app *without* "Include Info Messages"
    /// being toggled on — which is normally off for first-time
    /// debuggers and made the previous `.info` logs invisible in
    /// the user's troubleshooting dump.
    private static func pushLocalized(_ key: String) -> String {
        let stored = readAppGroupLanguage()
        let preferred = Locale.preferredLanguages
        let nseBundle = Bundle(for: NotificationService.self)

        let candidates: [String] = {
            var seen = Set<String>()
            var ordered: [String] = []
            func add(_ raw: String?) {
                guard let raw, !raw.isEmpty else { return }
                let stripped = String(raw.split(separator: "-").first ?? "")
                guard !stripped.isEmpty, !seen.contains(stripped) else { return }
                seen.insert(stripped)
                ordered.append(stripped)
            }
            add(stored)
            for lang in preferred { add(lang) }
            add("en")
            return ordered
        }()

        os_log("pushLocalized: stored=%{public}@ preferred=%{public}@ candidates=%{public}@ key=%{public}@",
               log: Self.log, type: .default,
               stored ?? "nil",
               preferred.joined(separator: ","),
               candidates.joined(separator: ","),
               key)

        for lang in candidates {
            guard let path = nseBundle.path(forResource: lang, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                os_log("pushLocalized: %{public}@.lproj not in NSE bundle, skipping",
                       log: Self.log, type: .default, lang)
                continue
            }
            let s = bundle.localizedString(forKey: key, value: "", table: nil)
            os_log("pushLocalized: tried %{public}@.lproj value=%{public}@",
                   log: Self.log, type: .default, lang, s)
            if !s.isEmpty && s != key {
                return s
            }
        }

        os_log("pushLocalized: no lproj resolved key, returning raw",
               log: Self.log, type: .error)
        return key
    }

    /// Read the active language code from the App Group. Tries the
    /// flat file first (reliable across processes), then the
    /// `UserDefaults(suiteName:)` mirror (cfprefsd-backed, often
    /// stale). Returns nil if the main app has never written
    /// either — caller falls through to the system locale.
    private static func readAppGroupLanguage() -> String? {
        if let data = try? Data(contentsOf: AppGroup.languageFileURL),
           let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let shared = UserDefaults(suiteName: AppGroup.identifier)
        return shared?.string(forKey: "rcq.app_language")
    }

    /// User-visible envelopes drive the badge counter. Silent envelopes
    /// (read receipts, reactions, bounces, edits, delete-for-everyone)
    /// are plumbing — they still come through NSE so the ratchet
    /// advances in the right process, but they must not inflate the
    /// unread count.
    private static func envelopeIsUserVisible(_ envelope: Envelope) -> Bool {
        switch envelope {
        case .text, .photo, .video, .voice, .file, .location,
             .systemNotice, .poll, .screenshotTaken, .relayShare:
            return true
        case .deleteForEveryone, .readReceipt, .deliveredReceipt, .reaction, .bounce, .visit, .edit,
             .secureScreen, .carbon, .callSignal, .homeRecord, .skdm, .sknack,
             .contactRequest, .profile:
            return false
        // A kind this build does not know. Not user-visible on purpose: raising
        // a banner for an envelope we cannot read would announce a message that
        // the app itself will then ignore, and inflate the unread count for it.
        case .unknown:
            return false
        }
    }

    /// True if a decryptable message mentions us by `#<uin>`. Used by the
    /// mentions-only group gate. `@<nick>` mentions aren't checked here (the
    /// NSE has no reliable own-nickname); they still surface in-app. An
    /// undecryptable sender-keys `gmsg` never reaches this (handled in the
    /// catch block).
    private static func envelopeMentions(_ envelope: Envelope, uin: Int) -> Bool {
        guard uin > 0 else { return false }
        let needle = "#\(uin)"
        switch envelope {
        case .text(_, let t, _, _, _):                      return t.contains(needle)
        case .photo(_, _, _, let c, _, _, _, _, _):         return (c ?? "").contains(needle)
        case .video(_, _, _, _, _, let c, _, _, _, _, _):   return (c ?? "").contains(needle)
        case .file(_, _, _, _, _, _, let c, _, _, _):       return (c ?? "").contains(needle)
        case .location(_, _, _, let c, _, _, _):            return (c ?? "").contains(needle)
        default:                                            return false
        }
    }

    private func envelopeKind(_ envelope: Envelope) -> String {
        switch envelope {
        case .text:             return "text"
        case .photo:            return "photo"
        case .video:            return "video"
        case .voice:            return "voice"
        case .file:             return "file"
        case .location:         return "location"
        case .deleteForEveryone: return "delete"
        case .systemNotice:     return "system"
        case .readReceipt:      return "read"
        case .reaction:         return "reaction"
        case .bounce:           return "bounce"
        case .visit:            return "visit"
        case .edit:             return "edit"
        case .poll:             return "poll"
        case .secureScreen:     return "secscreen"
        case .screenshotTaken:  return "shot"
        case .carbon:           return "carbon"
        case .callSignal:       return "call"
        case .contactRequest:   return "contactreq"
        case .profile:          return "profile"
        case .homeRecord:       return "homerec"
        case .skdm:             return "skdm"
        case .sknack:           return "sknack"
        case .relayShare:       return "relay_share"
        case .deliveredReceipt: return "delivered"
        case .unknown(let kind): return kind
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // 30-second wall-clock is up. Hand back whatever we managed to
        // build — the original (generic) content is fine if decryption
        // didn't finish.
        os_log("serviceExtensionTimeWillExpire — handing back best-attempt",
               log: Self.log, type: .error)
        if let handler = contentHandler, let content = bestAttempt {
            // The best attempt may already carry a real name, a preview or a
            // `#uin` subtitle. A timeout is not permission to show them.
            handler(AppGroup.pushQuiet() ? Self.quietContent(from: content) : content)
        }
    }
}
