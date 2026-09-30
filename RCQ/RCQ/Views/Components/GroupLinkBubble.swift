import SwiftUI

/// Chat bubble rendering for a shared group invite link. Mirrors
/// `UinLinkBubble` shape — `https://rcq.app/g/<id>` (or
/// `rcq://group/<id>`) inside a chat body parses into a card with
/// the group name + member count + entry price + closed indicator.
/// Tap → `AppState.pendingJoinGroupID = id`, which the root view
/// observes to present `GroupJoinSheet`.
struct GroupLinkBubble: View {
    let groupID: Int
    /// §5c: the group's host island when the link carried one; nil = ours.
    var host: String? = nil
    let rawURL: URL

    @EnvironmentObject private var appState: AppState
    @State private var preview: GroupService.GroupPreview?
    @State private var loadFailed: Bool = false

    /// Foreign = the link names an island that isn't ours.
    private var foreignHost: String? {
        guard let host, !Multihome.isOwnHost(host) else { return nil }
        return host
    }

    private func openJoin() {
        appState.pendingJoinGroupHost = foreignHost
        appState.pendingJoinGroupID = groupID
    }

    private static let cardWidth: CGFloat = 260
    private static let cardHeight: CGFloat = 96

    var body: some View {
        Group {
            if let preview {
                card(preview)
            } else if foreignHost != nil {
                // Unvisited foreign island: do NOT touch it just because the
                // link is on screen (anti-tracking). Minimal join card.
                islandCard
            } else if loadFailed {
                fallback
            } else {
                placeholder
            }
        }
        .task(id: groupID) { await load() }
    }

    @ViewBuilder
    private func card(_ p: GroupService.GroupPreview) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                // Real avatar when uploaded — `GroupAvatarView` falls
                // back to the generic glyph for groups without one,
                // so this single branch covers both cases.
                GroupAvatarView(
                    mediaID: p.avatarMediaID,
                    keyBase64: p.avatarMediaKey,
                    size: 56,
                )
                .frame(width: 56, height: 56)
                if p.isClosed {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(3)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
            }
            .frame(width: 72, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(String(format: "group_share.members".localized, p.memberCount))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
                if p.isClosed {
                    Text("group_share.closed_badge".localized)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.red.opacity(0.7))
                } else {
                    Text("group_share.free".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(Theme.Color.bgSecondary.opacity(0.7))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.Color.divider, lineWidth: 0.5),
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { openJoin() }
    }

    /// Minimal card for an unvisited foreign island (no preview by design).
    private var islandCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 22))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Theme.Color.accent))
            VStack(alignment: .leading, spacing: 3) {
                Text("group_join.island".localized)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                    .lineLimit(1)
                Text(foreignHost ?? "")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
                Text("group_share.free".localized)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(Theme.Color.bgSecondary.opacity(0.7))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Color.divider, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { openJoin() }
    }

    private var placeholder: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Theme.Color.bgSecondary)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.Color.bgSecondary)
                    .frame(width: 100, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.Color.bgSecondary)
                    .frame(width: 60, height: 10)
                ProgressView().scaleEffect(0.6)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .background(Theme.Color.bgSecondary.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var fallback: some View {
        Button {
            openJoin()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .foregroundColor(Theme.Color.accent)
                Text(rawURL.absoluteString)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(Theme.Color.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(8)
            .background(Theme.Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        if preview != nil { return }
        // Foreign island: only query one we've already VISITED (privacy). An
        // unvisited island renders `islandCard` and is left untouched.
        if let foreignHost {
            if let snap = await CrossIslandGroups.previewForeign(host: foreignHost, remoteId: groupID) {
                preview = snap
            }
            return
        }
        if let snap = await GroupService.shared.fetchPreview(groupID: groupID) {
            preview = snap
        } else {
            loadFailed = true
        }
    }
}

/// Parse a chat body for a single group-share URL. §5c: the id segment may
/// carry the group's host island as `<id>@<host>`; a bare id = own island.
/// Room link keys seen in links this process parsed (#990 step 2), by island
/// and room. The preview, the join and the guest entry look here, so a key
/// rides from the link to the island without every screen carrying it. Memory
/// only: a link parsed again (the bubble, the pin, a tap) puts it back.
enum RoomLinkKeys {
    private static var keys: [String: String] = [:]
    private static let lock = NSLock()
    static func isKey(_ k: String) -> Bool {
        (8...64).contains(k.count) && k.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
    private static func slot(_ host: String?, _ id: Int) -> String { "\((host ?? "").lowercased())#\(id)" }
    static func remember(host: String?, id: Int, k: String) {
        guard isKey(k) else { return }
        lock.lock(); keys[slot(host, id)] = k; lock.unlock()
    }
    /// `hosts`: every name the room's island goes by here; for our own island
    /// that is nil (a bare id) and its host.
    static func find(id: Int, hosts: [String?]) -> String? {
        lock.lock(); defer { lock.unlock() }
        for h in hosts { if let k = keys[slot(h, id)] { return k } }
        return nil
    }
    /// `?k=<key>` for a path, or "".
    static func query(id: Int, hosts: [String?]) -> String {
        guard let k = find(id: id, hosts: hosts),
              let e = k.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return "" }
        return "?k=\(e)"
    }
    /// The key a link carries in `?k=`, remembered for (host, id).
    static func note(url: URL, host: String?, id: Int) {
        if let k = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "k" })?.value {
            remember(host: host, id: id, k: k)
        }
    }
}

enum GroupLinkParser {
    /// Split a `<id>` or `<id>@<host>` path segment.
    private static func splitSeg(_ seg: String) -> (id: Int, host: String?)? {
        let at = seg.firstIndex(of: "@")
        let idPart = at.map { String(seg[seg.startIndex..<$0]) } ?? seg
        let hostPart = at.map { String(seg[seg.index(after: $0)...]).lowercased() }
        guard let gid = Int(idPart), gid > 0 else { return nil }
        return (gid, (hostPart?.isEmpty == false) ? hostPart : nil)
    }

    static func parse(_ body: String) -> (groupID: Int, host: String?, url: URL)? {
        // Cheap substring pre-gate: only group-share links carry these tokens.
        // Skips the trim allocation + URL(string:) construction for ordinary
        // text bubbles, which call this every render (isPlainTextBubble + the
        // group-link branch). Matches parse's own host/scheme checks below.
        guard body.contains("rcq.app/g/") || body.contains("rcq://group") else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed) else { return nil }
        if url.scheme == "rcq" && url.host == "group" {
            if let last = url.pathComponents.last, let s = splitSeg(last) {
                RoomLinkKeys.note(url: url, host: s.host, id: s.id)
                return (s.id, s.host, url)
            }
        }
        if (url.scheme == "https" || url.scheme == "http"),
           url.host == "rcq.app",
           url.pathComponents.count >= 3,
           url.pathComponents[1] == "g",
           let s = splitSeg(url.pathComponents[2]) {
            RoomLinkKeys.note(url: url, host: s.host, id: s.id)
            return (s.id, s.host, url)
        }
        return nil
    }

    /// Extract EVERY group-share link embedded anywhere in a longer text.
    /// Deduped by (id, host), original order preserved.
    static func parseAll(_ text: String) -> [(groupID: Int, host: String?)] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [(Int, String?)] = []
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, let hit = parse(url.absoluteString) else { continue }
            let key = "\(hit.groupID)@\(hit.host ?? "")"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append((hit.groupID, hit.host))
        }
        return out
    }

    /// Canonical URL for a fresh share — new shares ALWAYS carry the host so
    /// the link works from any island (§5c).
    /// With the room's key when we hold it (#990 step 2): a room outside the
    /// catalogue opens only with it once its island asks for it.
    static func canonicalURL(forGroupID gid: Int, host: String, k: String? = nil) -> URL {
        let q = k.flatMap { RoomLinkKeys.isKey($0) ? "?k=\($0)" : nil } ?? ""
        return URL(string: "https://rcq.app/g/\(gid)@\(host)\(q)")!
    }
}

/// Compact tappable row for a group link surfaced in the pinned-
/// announcement window — a "bridge" so newcomers can hop straight into
/// related groups. Resolves name + member count + avatar like
/// `GroupLinkBubble`, but as a slim list row, and delegates the tap so
/// the parent can dismiss the pin sheet BEFORE the join sheet presents
/// (avoids stacking two sheets).
struct PinnedGroupChip: View {
    let groupID: Int
    var host: String? = nil
    let onOpen: (Int) -> Void

    @State private var preview: GroupService.GroupPreview?

    /// The name this device already holds for a room the reader is in, drawn
    /// while the card loads or when it cannot be fetched (#1051, as Android):
    /// a bare number in the pinned bar says nothing.
    private var localName: String? {
        guard foreignHost == nil else { return nil }
        return GroupService.shared.groups.first(where: { $0.id == groupID && $0.host == nil })?.name
    }

    private var foreignHost: String? {
        guard let host, !Multihome.isOwnHost(host) else { return nil }
        return host
    }

    var body: some View {
        Button { onOpen(groupID) } label: {
            HStack(spacing: 10) {
                GroupAvatarView(
                    mediaID: preview?.avatarMediaID,
                    keyBase64: preview?.avatarMediaKey,
                    size: 36,
                )
                .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview?.name ?? localName ?? (foreignHost != nil ? "group_join.island".localized : "\(groupID)"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                        .lineLimit(1)
                    if let p = preview {
                        Text(String(format: "group_share.members".localized, p.memberCount))
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                            .lineLimit(1)
                    } else if let foreignHost {
                        Text(foreignHost)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(Theme.Color.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(10)
            .background(Theme.Color.bgSecondary.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.Color.divider, lineWidth: 0.5),
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .task(id: groupID) {
            guard preview == nil else { return }
            // Painted from the cache first, so a banner the user expands for the
            // second time is already filled in (16). Without it every expansion
            // was a fresh `@State` on a fresh view, which meant a fresh network
            // round trip: the rows drew as bare "#1234" placeholders and then
            // visibly re-loaded, every single time the pin was opened.
            if let cached = PinnedGroupPreviewCache.get(host: foreignHost, groupID: groupID) {
                preview = cached
                return
            }
            // A failed card is asked again twice, a little later each time: a
            // pin with several links opened in a burst can meet the preview
            // limit, and a placeholder that never fills in stays for the life
            // of the banner (#1051). Cancelled with the view.
            var fetched: GroupService.GroupPreview? = nil
            for delay in [0, 2, 6] as [UInt64] {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                if Task.isCancelled { return }
                if let foreignHost {
                    fetched = await CrossIslandGroups.previewForeign(host: foreignHost, remoteId: groupID)
                } else {
                    fetched = await GroupService.shared.fetchPreview(groupID: groupID)
                }
                if fetched != nil { break }
            }
            if let fetched {
                PinnedGroupPreviewCache.put(fetched, host: foreignHost, groupID: groupID)
            }
            preview = fetched
        }
    }
}

/// Group cards inside a pinned announcement, remembered for the life of the
/// process (16).
///
/// A pin can carry several group links and the banner is rebuilt on every
/// expand / collapse, on every reopen of the chat, and again inside the
/// expansion sheet. Each rebuild handed `PinnedGroupChip` a nil `@State` and it
/// went back to `/groups/{id}/preview`, so the same three cards flickered
/// through their placeholder state over and over for content that changes about
/// as often as a group is renamed.
///
/// ⚠ Memory only, on purpose. A name and a member count are cheap to re-fetch
/// once per launch and there is no invalidation story worth writing for them;
/// what is NOT acceptable is refetching them four times a minute. Keyed by host
/// as well as id because a foreign group's id is only unique on its own island.
@MainActor
enum PinnedGroupPreviewCache {
    private static var entries: [String: GroupService.GroupPreview] = [:]

    private static func key(host: String?, groupID: Int) -> String {
        "\(host?.lowercased() ?? "")#\(groupID)"
    }

    static func get(host: String?, groupID: Int) -> GroupService.GroupPreview? {
        entries[key(host: host, groupID: groupID)]
    }

    static func put(_ preview: GroupService.GroupPreview, host: String?, groupID: Int) {
        entries[key(host: host, groupID: groupID)] = preview
    }
}
