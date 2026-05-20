import SwiftUI

/// Wraps `DailyQACard` in its own sheet — the 12-row checklist was
/// too bulky sitting inline in the Settings list. Settings now shows
/// a single row that opens this.
struct DailyQASheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    DailyQACard()
                        .padding(16)
                }
            }
            .navigationTitle("smoke.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
        }
    }
}
