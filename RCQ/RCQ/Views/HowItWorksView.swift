import SwiftUI

/// "How this works" — three questions, one screen.
///
/// ⚠ NOT a second carousel, and that distinction is the brief. The carousel
/// shows what the app can DO, and nobody is confused about that. The confusion
/// in the reports is three other things: who can read what I send, what an
/// island is and why there is more than one, and what to do when it stops
/// working.
///
/// It lives in Settings permanently rather than at first launch, because the
/// question arrives on the third day, by which time an onboarding screen is
/// long gone.
struct HowItWorksView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                answer("how.q1", "how.a1")
            }
            .listRowBackground(Theme.Color.bgSecondary)
            Section {
                answer("how.q2", "how.a2")
            }
            .listRowBackground(Theme.Color.bgSecondary)
            Section {
                answer("how.q3", "how.a3")
            }
            .listRowBackground(Theme.Color.bgSecondary)
            Section {
                Button("how.more".localized) {
                    if let url = URL(string: "https://rcq.app/faq") { openURL(url) }
                }
                .foregroundColor(Theme.Color.accent)
            }
            .listRowBackground(Theme.Color.bgSecondary)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Color.bgPrimary.ignoresSafeArea())
        .navigationTitle("how.title".localized)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func answer(_ q: String, _ a: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(q.localized)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text(a.localized)
                .font(.system(size: 14))
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
