import SwiftUI

/// Mini-FAQ explaining the item system — rarity, essence, purity,
/// enhancement, disassemble, equip. Opened from the info button in
/// `ItemDetailSheet`'s top-right toolbar slot. Pure static content;
/// no network, no state beyond dismiss.
struct ItemSystemInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Topic: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let titleKey: String
        let bodyKey: String
        /// When set, the card renders this bundled asset instead of
        /// the SF Symbol in `icon` (e.g. the essence / gem artwork).
        var assetIcon: (name: String, ext: String)? = nil
    }

    private var topics: [Topic] {
        [
            Topic(icon: "arrow.up", tint: .purple,
                  titleKey: "item.faq.rarity.title",
                  bodyKey: "item.faq.rarity.body"),
            Topic(icon: "sparkles", tint: Theme.Color.accent,
                  titleKey: "item.faq.essence.title",
                  bodyKey: "item.faq.essence.body",
                  assetIcon: ("essence", "png")),
            Topic(icon: "drop.fill", tint: .blue,
                  titleKey: "item.faq.purity.title",
                  bodyKey: "item.faq.purity.body"),
            Topic(icon: "flame.fill", tint: .orange,
                  titleKey: "item.faq.enhance.title",
                  bodyKey: "item.faq.enhance.body",
                  assetIcon: ("gem", "gif")),
            Topic(icon: "wrench.adjustable.fill", tint: Theme.Color.textSecondary,
                  titleKey: "item.faq.disassemble.title",
                  bodyKey: "item.faq.disassemble.body"),
            Topic(icon: "checkmark.seal.fill", tint: Theme.Color.accent,
                  titleKey: "item.faq.equip.title",
                  bodyKey: "item.faq.equip.body"),
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("item.faq.intro".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(topics) { topic in
                        topicCard(topic)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("item.faq.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("common.done".localized) { dismiss() }
                        .foregroundColor(Theme.Color.accent)
                }
            }
        }
    }

    private func topicCard(_ topic: Topic) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let asset = topic.assetIcon {
                    ItemAssetImage(bundleSubdir: "Items", filename: asset.name, ext: asset.ext)
                        .frame(width: 18, height: 18)
                        .frame(width: 22)
                } else {
                    Image(systemName: topic.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(topic.tint)
                        .frame(width: 22)
                }
                Text(topic.titleKey.localized)
                    .font(.headline)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            Text(topic.bodyKey.localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(12)
    }
}
