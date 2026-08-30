import SwiftUI

/// Bottom sheet that appears on long-press of a message bubble. Top row: the
/// user's quick reactions. Bottom: delete actions.
///
/// Avoid Apple's built-in `.contextMenu` here - reactions need
/// to render as the actual animated GIFs, and Menu's `Label(image:)` only finds
/// assets in `Assets.xcassets`. The bundle holds loose `.gif` resources, so a
/// custom sheet wins.
///
/// ⚠ Nothing presents this today; `MessageActionOverlay` took over the
/// long-press. It is kept because the delete wording and the tile geometry are
/// the reference the overlay was built from, but it is not on any screen.
struct MessageActionSheet: View {
    let message: Message
    let onReact: (String) -> Void
    let onDeleteForMe: () -> Void
    let onDeleteForEveryone: (() -> Void)?

    /// The user's chosen quick reactions, defaulting to the six below
    /// until customised in the emoji picker. The cap is 40, not 6, which is
    /// why the row below scrolls instead of dividing the width by the count.
    @ObservedObject private var emojiPrefs = EmoticonPrefsStore.shared

    /// Six classic KOLOBOK reactions — covers the same semantic ground as the
    /// six default emoji reactions on Telegram/Slack. We pick from the existing
    /// kolobok pack instead of inventing emojis, since the user already has
    /// these assets and they're the soul of the app.
    static let reactionAssets: [String] = [
        "good",        // thumbs up / like
        "give_heart",  // love
        "biggrin",     // laughing
        "rofl",        // rolling on the floor
        "shok",        // shocked / wow
        "cray",        // crying / sad
        "mad",         // angry
        "diablo",      // devil
        "cool",        // cool
        "kiss",        // kiss
        "give_rose",   // rose
        "man_in_love", // in love
    ]

    var body: some View {
        VStack(spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(emojiPrefs.reactions, id: \.self) { asset in
                        Button { onReact(asset) } label: {
                            ReactionTile(asset: asset, selected: message.reactions.values.contains(asset))
                        }
                    }
                }
            }
            .padding(.top, 14)

            Divider().background(Theme.Color.divider)

            Button(role: .destructive) { onDeleteForMe() } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Delete for me")
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.Color.bgSecondary)
                .cornerRadius(6)
            }

            if let onDeleteForEveryone {
                Button(role: .destructive) { onDeleteForEveryone() } label: {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("Delete for everyone")
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.Color.bgSecondary)
                    .cornerRadius(6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
    }
}

private struct ReactionTile: View {
    let asset: String
    let selected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Theme.Color.accent.opacity(0.25) : Theme.Color.bgSecondary)
            if GIFImage.cachedImage(for: asset) != nil {
                GIFImage(name: asset)
                    .frame(width: 36, height: 36)
                    .padding(6)
            } else {
                Image(systemName: "face.smiling")
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(width: 36, height: 36)
                    .padding(6)
            }
        }
        .frame(width: 50, height: 50)
    }
}

/// Reactions bar shown beneath a message bubble. Aggregates by asset, shows
/// count, taps toggle the current user's reaction.
struct ReactionsBar: View {
    let message: Message
    let onTap: (String) -> Void
    /// Long-press a reaction chip → show who reacted (Telegram-style).
    var onShowWho: (() -> Void)? = nil

    private var grouped: [(asset: String, count: Int, mine: Bool)] {
        let me = AuthService.shared.ownUIN ?? 0
        var counts: [String: Int] = [:]
        var mineSet: Set<String> = []
        for (uin, asset) in message.reactions {
            counts[asset, default: 0] += 1
            if uin == me { mineSet.insert(asset) }
        }
        return counts.keys
            .sorted()
            .map { (asset: $0, count: counts[$0] ?? 0, mine: mineSet.contains($0)) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(grouped, id: \.asset) { entry in
                chip(entry)
                    .contentShape(Capsule())
                    // ExclusiveGesture: a hold (≥0.35s) opens "who reacted" and
                    // suppresses the tap; a quick tap toggles. .onTapGesture +
                    // .onLongPressGesture on one view conflict — the tap claims
                    // the touch and the long-press never fires.
                    .gesture(
                        ExclusiveGesture(
                            LongPressGesture(minimumDuration: 0.35).onEnded { _ in onShowWho?() },
                            TapGesture().onEnded { onTap(entry.asset) }
                        )
                    )
            }
        }
    }

    @ViewBuilder
    private func chip(_ entry: (asset: String, count: Int, mine: Bool)) -> some View {
        HStack(spacing: 3) {
            // 22pt, up from 14 (#821): at 14 a good kolobok and a bad one
            // were the same brown smudge - a reaction has to be readable at
            // a glance. Width follows the (non-square) picture.
            if GIFImage.cachedImage(for: entry.asset) != nil {
                GIFImage(name: entry.asset)
                    .frame(width: 22, height: 22)
            } else {
                Text(":)").font(.footnote).foregroundColor(Theme.Color.textPrimary)
            }
            // A lone reactor needs no "1" — show the number only once it grows
            // past one (founder feedback; Android parity).
            if entry.count > 1 {
                Text("\(entry.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(
            Capsule().fill(entry.mine ? Theme.Color.accent.opacity(0.25) : Theme.Color.bgSecondary)
        )
        .overlay(
            Capsule().stroke(entry.mine ? Theme.Color.accent : Color.clear, lineWidth: 1)
        )
    }
}

/// "Who reacted" sheet — long-press a reaction chip. Groups the message's
/// reactions by asset and lists each reactor. Tapping a row opens that person's
/// profile (22): the rows were inert, so the one sheet in the app that is a list
/// of PEOPLE was the one list you could not get from a person to their card.
struct ReactionsWhoSheet: View {
    let reactions: [Int: String]          // reactor UIN → asset
    let nameFor: (Int) -> String
    /// Their picture, from the same roster the name comes from. Optional so the
    /// other call sites of this sheet keep compiling; without it the rows draw
    /// the plain status flower, which is what they did before.
    var avatarFor: ((Int) -> (id: String?, key: String?, status: UserStatus, host: String?))? = nil
    @Environment(\.dismiss) private var dismiss

    /// Non-nil = a reactor's row was tapped; their card is pushed onto this
    /// sheet's own stack rather than dismissing back to the chat first.
    @State private var openProfileUIN: Int?

    private var grouped: [(asset: String, uins: [Int])] {
        Dictionary(grouping: reactions.keys, by: { reactions[$0] ?? "" })
            .map { (asset: $0.key, uins: $0.value.sorted()) }
            .sorted { $0.uins.count != $1.uins.count ? $0.uins.count > $1.uins.count : $0.asset < $1.asset }
    }

    /// May this row become a link to that person's card?
    ///
    /// ⚠ This sheet is the exact complaint behind the setting: react to a
    /// message in a group and your name lands in a list a stranger can read.
    /// A reaction carries nothing but a UIN, so the island's per-viewer
    /// verdict (`profile_openable`, the twin of `callable`) is looked up in the
    /// rosters this client already holds. ⚠ Fails OPEN when nothing knows.
    private func canOpenCard(_ uin: Int) -> Bool {
        ProfileCardPrivacy.canOpenCard(
            uin: uin,
            openable: ProfileCardPrivacy.verdict(for: uin),
            myUIN: AuthService.shared.ownUIN,
            isContact: ContactService.shared.contacts.contains { $0.uin == uin }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.asset) { g in
                    Section {
                        ForEach(g.uins, id: \.self) { uin in
                            reactorRow(uin)
                        }
                    } header: {
                        HStack(spacing: 8) {
                            // 18pt read as tiny against the row text (founder
                            // report) — the smiley IS the section's subject,
                            // let it lead.
                            if GIFImage.cachedImage(for: g.asset) != nil {
                                GIFImage(name: g.asset).frame(width: 30, height: 30)
                            }
                            Text("\(g.uins.count)")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
            .navigationTitle("reactions.who_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done".localized) { dismiss() }
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { openProfileUIN != nil },
                set: { if !$0 { openProfileUIN = nil } }
            )) {
                if let uin = openProfileUIN {
                    UserInfoView(uin: uin, isOwn: uin == (AuthService.shared.ownUIN ?? -1))
                }
            }
        }
    }

    /// One reactor. A tappable row when their card may be opened, the same row
    /// inert when it may not - never a row that looks tappable and does nothing,
    /// which is what all of them were.
    @ViewBuilder
    private func reactorRow(_ uin: Int) -> some View {
        let openable = canOpenCard(uin)
        if openable {
            Button {
                openProfileUIN = uin
            } label: {
                reactorRowBody(uin, openable: true)
            }
            .buttonStyle(.plain)
        } else {
            reactorRowBody(uin, openable: false)
        }
    }

    private func reactorRowBody(_ uin: Int, openable: Bool) -> some View {
        HStack(spacing: 10) {
            if let a = avatarFor?(uin) {
                PersonAvatarView(
                    mediaID: a.id,
                    keyBase64: a.key,
                    status: a.status,
                    host: a.host,
                    size: 26,
                )
            }
            Text(nameFor(uin))
                .foregroundColor(Theme.Color.textPrimary)
            Spacer()
            Text(verbatim: "#\(uin)")
                .font(.caption.monospaced())
                .foregroundColor(Theme.Color.textMono)
            if openable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
        // The whole row, not just the glyph and the name: a 26pt avatar next to
        // a short nickname is a small target in the middle of a wide row.
        .contentShape(Rectangle())
    }
}
