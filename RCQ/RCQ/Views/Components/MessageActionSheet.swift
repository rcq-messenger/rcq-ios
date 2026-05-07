import SwiftUI

/// Bottom sheet that appears on long-press of a message bubble. Top row: six
/// classic KOLOBOK emoticons used as reactions. Bottom: delete actions.
///
/// We deliberately avoid Apple's built-in `.contextMenu` because reactions need
/// to render as the actual animated GIFs, and Menu's `Label(image:)` only finds
/// assets in `Assets.xcassets`. The bundle holds loose `.gif` resources, so a
/// custom sheet wins.
struct MessageActionSheet: View {
    let message: Message
    let onReact: (String) -> Void
    let onDeleteForMe: () -> Void
    let onDeleteForEveryone: (() -> Void)?

    /// Six classic KOLOBOK reactions — covers the same semantic ground as the
    /// six default emoji reactions on Telegram/Slack. We pick from the existing
    /// kolobok pack instead of inventing emojis, since the user already has
    /// these assets and they're the soul of the app.
    static let reactionAssets: [String] = [
        "smile",   // happy / like
        "biggrin", // laughing
        "shok",    // shocked / wow
        "cray",    // crying / sad
        "good",    // thumbs up
        "heart",   // love
    ]

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 6) {
                ForEach(Self.reactionAssets, id: \.self) { asset in
                    Button { onReact(asset) } label: {
                        ReactionTile(asset: asset, selected: message.reactions.values.contains(asset))
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
                Button { onTap(entry.asset) } label: {
                    HStack(spacing: 3) {
                        if GIFImage.cachedImage(for: entry.asset) != nil {
                            GIFImage(name: entry.asset)
                                .frame(width: 14, height: 14)
                        } else {
                            Text(":)").font(.caption2).foregroundColor(Theme.Color.textPrimary)
                        }
                        if entry.count > 1 {
                            Text("\(entry.count)")
                                .font(.system(size: 10, weight: .semibold))
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
        }
    }
}
