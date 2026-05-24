import SwiftUI

struct RadioInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Topic: Identifiable {
        let id = UUID()
        let glyph: String
        let titleKey: String
        let bodyKey: String
    }

    private let topics: [Topic] = [
        Topic(
            glyph: "antenna.radiowaves.left.and.right",
            titleKey: "radio.info.what.title",
            bodyKey: "radio.info.what.body",
        ),
        Topic(
            glyph: "dot.radiowaves.left.and.right",
            titleKey: "radio.info.how.title",
            bodyKey: "radio.info.how.body",
        ),
        Topic(
            glyph: "ruler",
            titleKey: "radio.info.range.title",
            bodyKey: "radio.info.range.body",
        ),
        Topic(
            glyph: "wifi",
            titleKey: "radio.info.wifi.title",
            bodyKey: "radio.info.wifi.body",
        ),
        Topic(
            glyph: "lock.shield",
            titleKey: "radio.info.privacy.title",
            bodyKey: "radio.info.privacy.body",
        ),
        Topic(
            glyph: "person.2.wave.2",
            titleKey: "radio.info.when.title",
            bodyKey: "radio.info.when.body",
        ),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        ForEach(topics) { t in
                            topicBlock(t)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("radio.info.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                Text("radio.info.header.title".localized)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
            }
            Text("radio.info.header.subtitle".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func topicBlock(_ t: Topic) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: t.glyph)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 22, alignment: .center)
                Text(t.titleKey.localized)
                    .font(.headline)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            Text(t.bodyKey.localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 30)
        }
    }
}
