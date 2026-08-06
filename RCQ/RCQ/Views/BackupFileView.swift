import SwiftUI

/// Settings → Chat history file. Saves this device's history into one
/// `.rcqbak` and puts it back again.
///
/// Deliberately a plain file and nothing else: no cloud of ours, no account
/// needed to hold it. The person keeps it wherever they keep things, which on a
/// phone means Files, a drive, or a chat with themselves. We cannot lose what
/// we never had, and we cannot be made to hand it over.
///
/// The container is shared with the phones and the browser — see
/// `BackupFormat.swift` and `RCQ/docs/backup-format.md`.
struct BackupFileView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var includeMedia = true
    @State private var busy: String?
    @State private var note: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                Form {
                    Section {
                        Toggle(isOn: $includeMedia) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("backup.media.title".localized)
                                    .foregroundColor(Theme.Color.textPrimary)
                                Text("backup.media.desc".localized)
                                    .font(.caption)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                        }
                        .disabled(busy != nil)

                        Button {
                            save()
                        } label: {
                            Label("backup.export".localized, systemImage: "square.and.arrow.up")
                                .foregroundColor(Theme.Color.accent)
                        }
                        .disabled(busy != nil)
                    } header: {
                        Text("backup.intro".localized)
                            .textCase(nil)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    Section {
                        Button {
                            restore()
                        } label: {
                            Label("backup.restore".localized, systemImage: "square.and.arrow.down")
                                .foregroundColor(Theme.Color.accent)
                        }
                        .disabled(busy != nil)
                    } header: {
                        Text("backup.restore.desc".localized)
                            .textCase(nil)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    .listRowBackground(Theme.Color.bgSecondary)

                    if busy != nil || note != nil || error != nil {
                        Section {
                            if let busy {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(busy).foregroundColor(Theme.Color.textSecondary)
                                }
                            }
                            if let note {
                                Text(note).foregroundColor(Theme.Color.textPrimary)
                            }
                            if let error {
                                Text(error).foregroundColor(Theme.Color.statusBusy)
                            }
                        }
                        .listRowBackground(Theme.Color.bgSecondary)
                    }

                    Section {
                        Text("backup.warning".localized)
                            .font(.caption)
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("settings.history.file".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
        }
    }

    private func save() {
        busy = "backup.working".localized
        note = nil
        error = nil
        let name = "rcq-\(DateFormatters.isoDay.string(from: Date())).rcqbak"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        Task {
            do {
                let r = try await BackupService.export(to: url, includeMedia: includeMedia) { p in
                    busy = "backup.media.progress".localized(p.done, p.total)
                }
                busy = nil
                // Said out loud rather than left to the manifest: attachments
                // are pulled from the island as the file is written, so a blob
                // that has aged off simply is not there, and now is the only
                // moment the person can do anything about it.
                note = !includeMedia
                    ? "backup.saved".localized
                    : (r.mediaMissed > 0
                        ? "backup.saved.media.missed".localized(r.messages, r.media, r.mediaMissed)
                        : "backup.saved.media".localized(r.messages, r.media))
                DocumentPickerPresenter.presentExport(url: url, onDone: {
                    try? FileManager.default.removeItem(at: url)
                }, onCancel: {
                    try? FileManager.default.removeItem(at: url)
                })
            } catch {
                busy = nil
                self.error = error.localizedDescription
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func restore() {
        note = nil
        error = nil
        DocumentPickerPresenter.present(onPick: { picked in
            busy = "backup.working".localized
            Task {
                do {
                    let r = try await BackupService.restore(from: picked.url) { p in
                        busy = "backup.restore.progress".localized(p.done, p.total)
                    }
                    busy = nil
                    var parts = ["backup.restored".localized(r.added, r.skipped)]
                    if r.unreadable > 0 { parts.append("backup.restored.unreadable".localized(r.unreadable)) }
                    if r.media > 0 { parts.append("backup.restored.media".localized(r.media)) }
                    note = parts.joined(separator: " ")
                } catch {
                    busy = nil
                    self.error = error.localizedDescription
                }
                try? FileManager.default.removeItem(at: picked.url)
            }
        })
    }
}
