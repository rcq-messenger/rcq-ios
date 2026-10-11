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

        // The recipient, in plain on every push from an island new enough to
        // route (see the multi-account routing below).
        let toUIN: Int? = {
            if let v = userInfo["to_uin"] as? Int { return v }
            if let n = userInfo["to_uin"] as? NSNumber { return n.intValue }
            return nil
        }()

        // ⚠ A push for an account this phone no longer holds shows NOTHING
        // (report 1066). Deleting an account could leave its push row on the
        // island, and every push for it then fell through to the active
        // account below: no key opened it, so the generic "New message" went
        // up with a sound for a number that is gone. First, before the quiet
        // and mute gates, because no rule of any account here applies to it
        // and none of them should print anything for it either. Nothing is
        // cached: no account here could ever read it.
        if let toUIN, KeychainStore.noLocalAccountHolds(uin: toUIN) {
            os_log("push for an account not on this device - no banner",
                   log: Self.log, type: .default)
            contentHandler(UNNotificationContent())
            return
        }

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

        // The local accounts that hold the recipient's number. Usually one;
        // two when one key was restored onto two islands that both gave it the
        // same number, and then the push cannot say which of them it is for.
        let owners = toUIN.map { accountsOwning(uin: $0) } ?? []
        let activeBeforeRoute = AppGroup.readActiveAccountID()

        // ⚠ THE MUTES OF THE ACCOUNT THIS PUSH IS FOR. They are per account
        // (`MutedStore`): a chat muted in one account says nothing about the
        // same number or group id in another, where it is somebody else. This
        // process used to read ONE list, the active account's, for every push
        // on the phone. With no `to_uin` (an older backend) or no owner the
        // roster can name: the active account's, as before.
        let mutes = MutedStore.shared.mutes(for: owners.isEmpty ? [activeBeforeRoute].compactMap { $0 } : owners)

        // Group mute, checked BEFORE the decrypt: group_id rides in userInfo,
        // so we don't need the plaintext to know the thread. Doing it here
        // means a muted group stays silent even when the decrypt fails (the
        // per-recipient ratchet may already have advanced via the WS path) —
        // the post-decrypt mute check used to be skipped by the catch-block
        // fallthrough, leaking muted-group pushes as the generic banner.
        if let gid = (userInfo["group_id"] as? Int) ?? (userInfo["group_id"] as? NSNumber)?.intValue,
           mutes.silencesGroup(gid) {
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
        // (older backend that doesn't include the field) or the roster
        // could not say whose it is — preserves the pre-multi-account
        // behaviour for any push the lookup can't route. A recipient the
        // roster proves absent never gets here (report 1066, top of this
        // method).
        // `activeBeforeRoute` (above) is read before we (possibly) install a
        // per-account override below — comparing target vs original active
        // is what tells us whether this push is for the foreground account
        // or a different one in the local roster.
        //
        // Whose stores this push is read against, for the pinned-key check
        // further down: the routed account when there is one, else active.
        var routedAccountID = activeBeforeRoute
        // The account whose chat locks judge this push (#1045): only one the
        // push itself named. Falling back to the active account would judge
        // another account's chat by the wrong locks, so without an owner the
        // lock check takes every account's (see `AppGroup.lockedChats`).
        var lockOwnerID: UUID?
        if let toUIN, let targetID = owners.first {
            routedAccountID = targetID
            // Only an owner that is the ONLY one: numbers are per island, and
            // one key restored onto two islands makes two accounts with the
            // same number here. Judged by the wrong one's locks, a locked
            // chat's words would print; by all of them, one line too few.
            lockOwnerID = owners.count == 1 ? targetID : nil
            // Push for a non-foreground account: mark the banner so
            // the user can tell at a glance that this message went
            // to one of their OTHER accounts, not the one they're
            // currently looking at. iOS renders subtitle as the
            // second line below title in the banner. Single-account
            // devices and pushes for the active account skip this —
            // no clutter for the common case.
            if let activeBeforeRoute, activeBeforeRoute != targetID {
                content.subtitle = "\(toUIN)"
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
            let groupID = (userInfo["group_id"] as? Int) ?? (userInfo["group_id"] as? NSNumber)?.intValue
            // Where the sender's number lives, decided the way the app decides
            // it (report 1071): our island or another one, by the names of our
            // island the app hands over (`AppGroup.ownHosts`). Every number
            // rule below is a rule about OUR island's numbers, and the
            // cross-island gate further down only runs for another island.
            let island = Self.senderIsland(decrypted.senderHost, accountID: routedAccountID)
            let ourNumber: Bool = {
                switch island {
                case .ours: return true
                case .foreign: return false
                // The app has not said yet: as before, any address without a
                // pinned row counts as ours.
                case .unknown:
                    return !Self.isPinnedForeign(uin: decrypted.senderUIN, host: decrypted.senderHost, accountID: routedAccountID)
                }
            }()
            // ICQ-style mutual remove: if the user previously dropped this
            // contact, silently suppress the push. PushDecryptCache stays
            // un-touched so the main app's MessageService.ingest can also
            // re-evaluate (and double-drop) when it sees the envelope.
            //
            // ⚠ The list is our own island's numbers (report 1064): a contact
            // on another island who holds the same number is somebody else,
            // and the app files what they write.
            //
            // ⚠ Read for the account the push is for, from disk: the list is
            // per account, and one account's removal silenced the same
            // number in another (where it may be another person).
            if ourNumber, RemovedContactsStore.stored(accountID: routedAccountID).contains(decrypted.senderUIN) {
                contentHandler(UNNotificationContent())
                return
            }
            // ⚠⚠ A STRANGER WHOSE RANDOM SESSION IS OVER GETS NO BANNER.
            //
            // A random-chat message is an ordinary sealed envelope: nothing on
            // the wire marks it, because the island must not be able to tell
            // either. So once the session ended, this process titled the banner
            // with the stranger's bare number, and tapping it opened an
            // ordinary 1:1 chat where the app resolved their nickname — the one
            // thing random chat promises never to do (founder, 07.09).
            //
            // The app drops the message itself, but this is a SEPARATE PROCESS
            // and can only be told through the shared container, so the leak
            // happened before the app was ever opened. A random stranger is a
            // number of our island, like the app's own check.
            if ourNumber, FinishedStrangers.contains(decrypted.senderUIN) {
                contentHandler(UNNotificationContent())
                return
            }
            // Filed under the account whose keys just opened it: its entry is
            // that account's only decoder until the account is next drained,
            // and a switch to another account must not take it (#1045 review).
            PushDecryptCache.store(ciphertextB64: envB64, decrypted: decrypted, accountID: routedAccountID)
            // ⚠⚠ NOTHING IS ANNOUNCED THAT THE APP WILL NOT SHOW (report 1071).
            //
            // The island pushes every content-class deposit, and that class
            // holds far more than messages: a reaction, an edit, a delete, a
            // home record, a call's ICE. Android 0.213 sends reactions, edits,
            // deletes and its home record to a contact on another island under
            // their own types, the island pushes each one, and each one woke
            // the phone with the contact's name over "Message". The app files
            // none of them as anything a person said, so opening it showed
            // nothing, every time. Only what the app shows as said gets a
            // banner (`MessageService.isSomethingSaid`), plus a call offer.
            // The secure-mode toggle, a §5f contact request (the pending badge
            // surfaces it) and a §5e profile refresh were already kept quiet
            // one by one; they are covered here. Cached above either way, so
            // the app still applies them.
            //
            // Before the duress check on purpose: nothing for these in every
            // state, so locked and unlocked do not differ by them.
            guard Self.isAnnounced(decrypted.envelope) else {
                contentHandler(UNNotificationContent())
                return
            }
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
            // covers other clients that don't.) Our number on another island
            // is us only under our own key; under any other it is somebody
            // else, and the gate below decides about them like the app does.
            let signedByUs = Self.sameKey(decrypted.senderSigningKey, (try? crypto.bootstrapIdentity())?.signingKey)
            if let toUIN, decrypted.senderUIN == toUIN, ourNumber || signedByUs {
                contentHandler(UNNotificationContent())
                return
            }
            // Somebody this account blocked: no banner (reports 1064, 1065).
            // Cached above, so the app still takes the row in and drops it
            // (and bounces it to a blocked contact) by its own rules. Nothing
            // here used to look at a block at all, so a blocked person's words
            // reached the lock screen before the app ever ran.
            if Self.senderBlocked(
                uin: decrypted.senderUIN, host: decrypted.senderHost,
                spub: decrypted.senderSigningKey, ourNumber: ourNumber, accountID: routedAccountID
            ) {
                os_log("sender #%d is blocked - no banner", log: Self.log, type: .default, decrypted.senderUIN)
                contentHandler(UNNotificationContent())
                return
            }
            // ⚠⚠ A sender who names a pinned cross-island contact but signed
            // with another key gets no banner. `from` and `from_host` sit
            // outside the v=1 signature, so anyone who reads our open key card
            // can claim uin@host of a contact we accepted. The app holds such
            // a message as a request, but this process titled the banner with
            // the contact's name and printed the forger's text on the lock
            // screen first. Cached above, so the app still files the request.
            // Only a pinned row is checked: a row exists only for another
            // island.
            if let host = decrypted.senderHost,
               let pinned = Self.pinnedSigningKey(
                   uin: decrypted.senderUIN, host: host, accountID: routedAccountID
               ),
               !Self.sameKey(decrypted.senderSigningKey, pinned) {
                os_log("sender claims pinned #%d@%{public}@ under another key - no banner",
                       log: Self.log, type: .error, decrypted.senderUIN, host)
                contentHandler(UNNotificationContent())
                return
            }
            // A call offer rings in the app only from an accepted contact on
            // another island, at exactly the address they are filed under
            // (`MessageService.routeCrossIslandCallSignal`): the answer goes
            // back there. Any other offer the app drops without a trace, so
            // it gets no banner either, and never a request one (report 1071).
            if case .callSignal = decrypted.envelope {
                let rings: Bool = {
                    guard groupID == nil else { return false }
                    switch island {
                    case .foreign(let host):
                        return Self.verifiedPinned(
                            uin: decrypted.senderUIN, host: host, spub: decrypted.senderSigningKey,
                            accountID: routedAccountID, exactAddress: true
                        )
                    case .ours: return false
                    case .unknown: return true
                    }
                }()
                if !rings {
                    contentHandler(UNNotificationContent())
                    return
                }
            }
            // ⚠⚠ THE CROSS-ISLAND GATE, AS THE APP RUNS IT (report 1071).
            //
            // A 1:1 message from another island is a chat message only from an
            // accepted contact proven by the key we pinned: at that address,
            // or (with no row there) a row for this number under that key.
            // Anything else the app files under Requests. This process knew
            // nothing of it and announced it as a message, titled with the
            // name the bare number has in our list (somebody else's, when our
            // island has a holder of it) and counted on that chat; opening the
            // app showed an empty chat and nothing said where the message
            // went. Said as a request instead: the address, not a name, none
            // of the words, and a tap opens Requests (`pending`).
            if groupID == nil, case .foreign(let host) = island,
               !Self.verifiedPinned(
                   uin: decrypted.senderUIN, host: host,
                   spub: decrypted.senderSigningKey, accountID: routedAccountID
               ) {
                // The app holds only content and polls from them and drops the
                // rest (`MessageService.isCrossIslandHeldKind`): a screenshot
                // note or a system notice from a stranger left a request
                // banner over a Requests list with nothing new in it.
                guard Self.isHeldAsRequest(decrypted.envelope) else {
                    contentHandler(UNNotificationContent())
                    return
                }
                os_log("#%d@%{public}@ is not an accepted contact - request banner",
                       log: Self.log, type: .default, decrypted.senderUIN, host)
                contentHandler(Self.requestContent(uin: decrypted.senderUIN, host: host, from: content))
                return
            }
            // Muted: cached above so it still lands in the thread; just no alert.
            // A number of our island by the number, anybody else by the
            // address the app keeps them under (`foreignMuted`).
            let mutedGroupID = groupID
            let suppressedByMute: Bool = {
                if let gid = mutedGroupID { return mutes.silencesGroup(gid) }
                if ourNumber { return mutes.silences(uin: decrypted.senderUIN) }
                return Self.foreignMuted(
                    mutes, uin: decrypted.senderUIN, host: decrypted.senderHost,
                    spub: decrypted.senderSigningKey, accountID: routedAccountID
                )
            }()
            if suppressedByMute {
                contentHandler(UNNotificationContent())
                return
            }
            // ⚠⚠ THE SAME-ISLAND QUARANTINE, AS THE APP RUNS IT.
            //
            // With Privacy -> "Strangers go to requests" on, the app files a
            // content message from a number of our own island that is not a
            // contact, was never let in and was never written to under
            // Requests (`StrangerQuarantine.shouldQuarantine`), and holds it
            // there without a word in any chat. This process knew nothing of
            // the switch and printed the stranger's words on the lock screen,
            // the one thing the switch is for. Said as a request instead, like
            // one from another island above: the number and not a name, none
            // of the words, and a tap opens Requests. Whom the app lets
            // through comes from the app (`AppGroup.strangerQuarantine`), for
            // the account this push is for; with no live roster there it holds
            // nobody, as the app does.
            let me = toUIN ?? KeychainStore.string(KeychainStore.Keys.uin).flatMap { Int($0) }
            if groupID == nil, ourNumber, decrypted.senderUIN != me,
               Self.isQuarantinedKind(decrypted.envelope),
               AppGroup.strangerQuarantine(accountID: routedAccountID)?.holds(decrypted.senderUIN) == true {
                os_log("#%d is a stranger the app holds under Requests - request banner",
                       log: Self.log, type: .default, decrypted.senderUIN)
                contentHandler(Self.requestContent(uin: decrypted.senderUIN, host: nil, from: content))
                return
            }
            // Mentions-only group: alert only when THIS message mentions us
            // (#<our uin>). Cached above so it still threads in-app; just no
            // banner for an ordinary message in a group set to "mentions only".
            if let gid = mutedGroupID, mutes.mentionsOnly(gid),
               !Self.envelopeMentions(decrypted.envelope, uin: toUIN ?? 0) {
                contentHandler(UNNotificationContent())
                return
            }
            apply(decrypted: decrypted, to: content, lockOwner: lockOwnerID)
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
                if mutes.silencesGroup(gid) {
                    contentHandler(UNNotificationContent())
                    return
                }
                // Mentions-only group + undecryptable gmsg: a mention can't be
                // verified out-of-process, so stay quiet. The in-app path and
                // the home-row @ indicator still surface mentions when the app
                // runs; an offline @mention won't push (sender-keys limit).
                if mutes.mentionsOnly(gid) {
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

    /// One cross-island contact of this account as `CrossIslandStore` keeps it.
    private struct PinnedRow {
        let uin: Int
        /// `AppGroup.canonicalHost` of the row's island.
        let host: String
        let signingKey: String
    }

    /// This account's cross-island contacts, read RAW from the App Group slot
    /// `CrossIslandStore` persists (a map "uin@lowercased host" -> Contact JSON
    /// under `rcq.crossisland.contacts.v1.<account>`), because that store is
    /// not in this target and would drag the federation layer in with it. Keep
    /// the two in step; CrossIslandStore says so beside its key. The rows are
    /// read for their own `uin` and `host`, so a map key in another spelling of
    /// the island still finds its row.
    private static func pinnedRows(accountID: UUID?) -> [PinnedRow] {
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier),
              let data = defaults.data(
                  forKey: "rcq.crossisland.contacts.v1." + (accountID?.uuidString ?? "none")
              ),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return map.compactMap { key, value in
            guard let row = value as? [String: Any],
                  let sk = row["signing_key"] as? String, !sk.isEmpty
            else { return nil }
            // The row's own fields; the map key ("uin@host") only when one is
            // missing.
            let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
            guard let uin = (row["uin"] as? Int) ?? parts.first.flatMap({ Int($0) }),
                  let host = AppGroup.canonicalHost((row["host"] as? String) ?? (parts.count == 2 ? parts[1] : ""))
            else { return nil }
            return PinnedRow(uin: uin, host: host, signingKey: sk)
        }
    }

    /// The signing key pinned for uin@host among this account's cross-island
    /// contacts, or nil when we hold no row for that address.
    private static func pinnedSigningKey(uin: Int, host: String, accountID: UUID?) -> String? {
        guard let want = AppGroup.canonicalHost(host) else { return nil }
        return pinnedRows(accountID: accountID).first { $0.uin == uin && $0.host == want }?.signingKey
    }

    /// Does this account hold a pinned cross-island contact at `uin@host`? How
    /// this process told a number from another island apart from ours before
    /// the app handed it our island's names (`senderIsland`): a row exists
    /// only for a foreign address.
    private static func isPinnedForeign(uin: Int, host: String?, accountID: UUID?) -> Bool {
        guard let host else { return false }
        return pinnedSigningKey(uin: uin, host: host, accountID: accountID) != nil
    }

    /// The app's cross-island gate (`MessageService.verifiedCrossIslandContact`):
    /// an accepted contact proven by the key that signed the envelope. The row
    /// at exactly `uin@host` must carry that key; with no row there, a row for
    /// this number under that key is the same person writing from another of
    /// their islands (not with `exactAddress`, the rule for calls). A nil
    /// `spub` (v=2) proves nobody.
    private static func verifiedPinned(
        uin: Int, host: String, spub: String?, accountID: UUID?, exactAddress: Bool = false
    ) -> Bool {
        let rows = pinnedRows(accountID: accountID)
        if let want = AppGroup.canonicalHost(host), let exact = rows.first(where: { $0.uin == uin && $0.host == want }) {
            return sameKey(spub, exact.signingKey)
        }
        if exactAddress { return false }
        return rows.contains { $0.uin == uin && sameKey(spub, $0.signingKey) }
    }

    /// Where a sender's number lives (report 1071). `ours` for no `from_host`
    /// (v=2, or a sender from before it) and for a name of our own island;
    /// `foreign` with the island's canonical name; `unknown` while the app has
    /// not handed this account's island names over (`AppGroup.ownHosts`).
    private enum SenderIsland {
        case ours
        case foreign(String)
        case unknown
    }

    private static func senderIsland(_ host: String?, accountID: UUID?) -> SenderIsland {
        guard let host, let canonical = AppGroup.canonicalHost(host) else { return .ours }
        guard let own = AppGroup.ownHosts(accountID: accountID) else { return .unknown }
        return own.contains(canonical) ? .ours : .foreign(canonical)
    }

    /// Did the account this push belongs to block its sender (reports 1064,
    /// 1065)? The app's rules (`BlockRule`) as far as this process can follow
    /// them, read raw from the App Group like `pinnedRows`:
    ///
    /// - a number of our own island (`BlockedContactsStore`), when
    ///   `ourNumber` says the sender's number is ours (see `senderIsland`);
    /// - an older build's block of the number, which covers every island;
    /// - uin@host blocked on another island (`CrossIslandRequestsStore`, the
    ///   set under `rcq.ci-blocked.v1.<account>`, "uin@lowercased host");
    /// - the key pinned for a blocked address, from wherever it writes now.
    ///
    /// Before the app handed over our island's names, wrong only toward
    /// silence for a stranger on another island who holds a number blocked on
    /// ours: no banner, and the app still files the row.
    private static func senderBlocked(uin: Int, host: String?, spub: String?, ourNumber: Bool, accountID: UUID?) -> Bool {
        if ourNumber, BlockedContactsStore.storedOwnIsland(accountID: accountID).contains(uin) {
            return true
        }
        if BlockedContactsStore.storedEveryIsland(accountID: accountID).contains(uin) { return true }
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier) else { return false }
        let id = accountID?.uuidString ?? "none"
        guard let data = defaults.data(forKey: "rcq.ci-blocked.v1." + id),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String],
              !raw.isEmpty
        else { return false }
        // "uin@host" in the spelling `AppGroup.canonicalHost` gives, so a
        // block filed under another spelling of the island still names it.
        let blocked: [(uin: Int, host: String)] = raw.compactMap { address in
            let parts = address.split(separator: "@", maxSplits: 1)
            guard parts.count == 2, let u = Int(parts[0]), let h = AppGroup.canonicalHost(String(parts[1])) else { return nil }
            return (u, h)
        }
        if let host, let want = AppGroup.canonicalHost(host),
           blocked.contains(where: { $0.uin == uin && $0.host == want }) {
            return true
        }
        guard spub != nil else { return false }
        let rows = pinnedRows(accountID: accountID)
        return blocked.contains { address in
            rows.contains { $0.uin == address.uin && $0.host == address.host && sameKey(spub, $0.signingKey) }
        }
    }

    /// Same Ed25519 key, compared as bytes so two base64 spellings agree. A
    /// nil `spub` (v=2) never matches, the same rule the app applies.
    private static func sameKey(_ spub: String?, _ pinned: String?) -> Bool {
        guard let spub, let pinned,
              let got = Data(base64Encoded: spub), !got.isEmpty,
              let want = Data(base64Encoded: pinned)
        else { return false }
        return got == want
    }

    /// The banner for a message the app files under Requests (report 1071):
    /// the sender's address and not a name, none of the words, no badge on a
    /// chat it will not be in, and `pending` so a tap opens Requests. A
    /// stranger on our own island (`host` nil) is addressed by the number.
    ///
    /// Keeps the router's "for account B" subtitle and `to_uin`: without the
    /// number the tap stayed on the active account and opened ITS Requests,
    /// where the row is not. Only `to_uin` from the payload: with `env` the
    /// app's `willPresent` takes the banner for a message push and drops it in
    /// the foreground.
    private static func requestContent(uin: Int, host: String?, from content: UNMutableNotificationContent) -> UNNotificationContent {
        let out = UNMutableNotificationContent()
        out.title = host.map { "\(uin)@\($0)" } ?? "\(uin)"
        out.subtitle = content.subtitle
        let body = pushLocalized("push.message_request.body")
        out.body = (body.isEmpty || body == "push.message_request.body") ? "New message request" : body
        out.sound = content.sound
        out.threadIdentifier = "pending"
        if let to = content.userInfo["to_uin"] { out.userInfo = ["to_uin": to] }
        return out
    }

    /// Walk the local account roster and return the IDs of the accounts
    /// that own the given UIN, in roster order. Used by the multi-account
    /// push router above (the first one) and the mute and lock gates (all
    /// of them). Empty if no account matches (push for an account that's
    /// been removed from the device, or for a fresh install that hasn't run
    /// AccountManager yet).
    private func accountsOwning(uin: Int) -> [UUID] {
        let target = String(uin)
        return AppGroup.readAccountIDs().filter {
            KeychainStore.string(KeychainStore.Keys.uin, forAccount: $0) == target
        }
    }

    /// A sender who is not a number of our island: muted at their address, or
    /// at the address of the contact their key proves them to be (the same
    /// person writing from another of their islands, whom the app files under
    /// that row and mutes there). Before the app handed its lists out per
    /// account, an older build's list silenced the number anywhere.
    private static func foreignMuted(
        _ mutes: MutedStore.Mutes, uin: Int, host: String?, spub: String?, accountID: UUID?
    ) -> Bool {
        if let host, mutes.silences(uin: uin, host: host) { return true }
        if mutes.olderBuild, mutes.silences(uin: uin) { return true }
        return pinnedRows(accountID: accountID).contains {
            $0.uin == uin && sameKey(spub, $0.signingKey) && mutes.silences(uin: uin, host: $0.host)
        }
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
        let name = content.title.isEmpty ? "\(senderUIN)" : content.title
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

    private func apply(
        decrypted: DecryptedEnvelope,
        to content: UNMutableNotificationContent,
        lockOwner: UUID?
    ) {
        // Sender's name. The main app pushes a `uin → nickname` cache
        // into the App Group on every contact-list refresh, so we have
        // a recent value here in most cases. Falls back to a `#UIN`
        // tag when the sender isn't in our contacts (e.g. an open
        // random-chat session, or a contact added on another device).
        let senderNick = NicknameCache.nickname(for: decrypted.senderUIN) ?? "\(decrypted.senderUIN)"
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

        // ⚠ A chat that asks for a PIN says who wrote and nothing of what
        // (#1045): its words on the lock screen would walk round the gate the
        // chat is behind. The app hands us the locks in force through the App
        // Group (`LockedChatsStore.syncExtensionMirror`), per account: the
        // account this push was addressed to, or every account's when it named
        // none we know. Only what a person wrote is replaced; a call keeps
        // saying it is a call. Same rule as the in-app banner.
        let lockKey = groupID.map { "group:\($0)" } ?? "peer:\(decrypted.senderUIN)"
        let chatLocked = Self.envelopeIsUserVisible(decrypted.envelope)
            && AppGroup.lockedChats(accountID: lockOwner).contains(lockKey)

        switch decrypted.envelope {
        case _ where chatLocked:
            let localized = Self.pushLocalized("push.locked_chat.body")
            content.body = (localized.isEmpty || localized == "push.locked_chat.body") ? "Message" : localized
        case .text(_, let text, _, _, _, _):
            content.body = text.isEmpty ? "Message" : text
        case .photo(_, _, _, let caption, _, _, _, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "📷 Photo" : "📷 \(cap)"
        case .video(_, _, _, _, _, let caption, _, _, _, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "🎬 Video" : "🎬 \(cap)"
        case .voice:
            content.body = "🎤 Voice message"
        case .file(_, _, _, let fname, _, _, let caption, _, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "📎 \(fname)" : "📎 \(fname): \(cap)"
        case .location(_, _, _, let caption, _, _, _, _):
            let cap = caption?.trimmingCharacters(in: .whitespaces) ?? ""
            content.body = cap.isEmpty ? "📍 Location" : "📍 Location: \(cap)"
        case .systemNotice(_, let text):
            content.body = text.isEmpty ? "System notice" : text
        case .poll:
            // ⚠ The question is DELIBERATELY not printed. Polls were removed
            // (14a) and the app draws such a row as "no longer supported"
            // without ever touching the body, so printing it here would put
            // the one thing the removal exists to stop retaining onto the
            // lock screen, and then promise content the chat denies having.
            // A peer on an old build still sends them, so the banner stays:
            // a removed feature answers, it does not vanish.
            content.body = "📊 Poll"
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
             .profile, .readMark, .gsKey, .gsKnack, .pkey, .pkeyAsk, .ciAck,
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
            // Longest first ("zh-Hans-CN", "zh-Hans", "zh"): a folder named
            // with its script (zh-Hans.lproj) is found as well as a bare one.
            func add(_ raw: String?) {
                guard let raw, !raw.isEmpty else { return }
                var parts = raw.split(separator: "-").map(String.init)
                while !parts.isEmpty {
                    let code = parts.joined(separator: "-")
                    if !seen.contains(code) {
                        seen.insert(code)
                        ordered.append(code)
                    }
                    parts.removeLast()
                }
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
             .contactRequest, .profile, .readMark, .gsKey, .gsKnack,
             // ⚠ SILENT on purpose: my own device telling me a cross-island
             // request was answered is bookkeeping between my installs, not
             // something a person said to me.
             .ciAck,
             // ⚠ SILENT on purpose: a contact changing their picture must not
             // bump the badge or paint the app icon. Key distribution is
             // housekeeping, not something a person said.
             .pkey, .pkeyAsk:
            return false
        // A kind this build does not know. Not user-visible on purpose: raising
        // a banner for an envelope we cannot read would announce a message that
        // the app itself will then ignore, and inflate the unread count for it.
        case .unknown:
            return false
        }
    }

    /// Does this envelope get a banner at all (report 1071)? What the app shows
    /// as something said, and a call offer: the one signal a person waits for,
    /// which rings as "Incoming call" while fresh and is filed as a missed call
    /// when stale. Every other kind is applied by the app without a row in any
    /// chat, so a banner for it announced a message nobody could find.
    private static func isAnnounced(_ envelope: Envelope) -> Bool {
        if case .callSignal(_, let sig, _, _, _) = envelope { return sig == "call_offer" }
        return envelopeIsUserVisible(envelope)
    }

    /// What the app keeps under Requests from somebody on another island who
    /// is not an accepted contact. ⚠ The same set as
    /// `MessageService.isCrossIslandHeldKind` (content kinds and a poll); the
    /// app drops every other kind from them.
    private static func isHeldAsRequest(_ envelope: Envelope) -> Bool {
        switch envelope {
        case .text, .photo, .video, .voice, .file, .location, .poll: return true
        default: return false
        }
    }

    /// What the same-island quarantine holds from a stranger. ⚠ The same set
    /// as `StrangerQuarantine.isContentKind` (no poll, unlike the cross-island
    /// set above); every other kind from them reaches the chat as before.
    /// `Tools/StrangerQuarantineCheck` holds the two together.
    private static func isQuarantinedKind(_ envelope: Envelope) -> Bool {
        switch envelope {
        case .text, .photo, .video, .voice, .file, .location: return true
        default: return false
        }
    }

    /// True if a decryptable message mentions us by `#<uin>`. Used by the
    /// mentions-only group gate. `@<nick>` mentions aren't checked here (the
    /// NSE has no reliable own-nickname); they still surface in-app. An
    /// undecryptable sender-keys `gmsg` never reaches this (handled in the
    /// catch block).
    private static func envelopeMentions(_ envelope: Envelope, uin: Int) -> Bool {
        guard uin > 0 else { return false }
        let needle = "\(uin)"
        switch envelope {
        case .text(_, let t, _, _, _, _):                   return t.contains(needle)
        case .photo(_, _, _, let c, _, _, _, _, _, _):      return (c ?? "").contains(needle)
        case .video(_, _, _, _, _, let c, _, _, _, _, _, _): return (c ?? "").contains(needle)
        case .file(_, _, _, _, _, _, let c, _, _, _, _):    return (c ?? "").contains(needle)
        case .location(_, _, _, let c, _, _, _, _):         return (c ?? "").contains(needle)
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
        case .readMark:         return "readmark"
        case .ciAck:            return "ciack"
        case .gsKey:            return "gskey"
        case .gsKnack:          return "gsknack"
        case .pkey:             return "pkey"
        case .pkeyAsk:          return "pkeyask"
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

/// The numbers whose random-chat session has just ended, as written by the app
/// into the shared container.
///
/// ⚠ Deliberately a copy of eight lines rather than pulling `RandomChatService`
/// into this target: the extension is a separate binary with its own launch
/// budget, and it needs one dictionary lookup, not a service that talks to a
/// socket. The key and the window must match `RandomChatService`.
enum FinishedStrangers {
    private static let key = "rcq.random.recentlyEnded"
    private static let grace: TimeInterval = 24 * 3600

    static func contains(_ uin: Int) -> Bool {
        let d = UserDefaults(suiteName: "group.app.rcq.shared") ?? .standard
        guard let raw = d.dictionary(forKey: key) as? [String: Double],
              let at = raw[String(uin)] else { return false }
        return Date().timeIntervalSince1970 - at < grace
    }
}
