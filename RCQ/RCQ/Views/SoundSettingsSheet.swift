import SwiftUI

/// Standalone sound preferences sheet — split off the main Settings
/// screen because the sub-toggles for contact-online / contact-offline
/// chimes were cluttering the top-level list. Reached via the row in
/// Settings.
struct SoundSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var sound = SoundService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                Form {
                    Section("settings.sound.section.master".localized) {
                        Toggle(isOn: $sound.isEnabled) {
                            Text("settings.sound.toggle".localized)
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        .tint(Theme.Color.accent)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    Section {
                        Toggle(isOn: $sound.contactOnlineSoundEnabled) {
                            Text("settings.sound.contact_online".localized)
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        .tint(Theme.Color.accent)
                        .disabled(!sound.isEnabled)

                        Toggle(isOn: $sound.contactOfflineSoundEnabled) {
                            Text("settings.sound.contact_offline".localized)
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        .tint(Theme.Color.accent)
                        .disabled(!sound.isEnabled)
                    } header: {
                        Text("settings.sound.section.presence".localized)
                    } footer: {
                        Text("settings.sound.section.presence.hint".localized)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("settings.sound".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
        }
    }
}
