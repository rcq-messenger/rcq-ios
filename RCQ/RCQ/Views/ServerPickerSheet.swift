import SwiftUI

/// Pick a server from the public RCQ instance directory at first
/// launch. Non-destructive: this sheet only runs from `OnboardingView`,
/// where there is no local account yet — so a tap just writes
/// `rcq.baseURL` to `UserDefaults` and the subsequent `/auth/register`
/// call lands on the chosen backend.
///
/// For established users who want to switch *after* having an account,
/// the matching surface is `CustomServerSheet` in Privacy & Network
/// settings — that one is intentionally destructive (burns the local
/// account, mints fresh on the new server).
struct ServerPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var directory = ServerDirectoryService.shared
    @AppStorage("rcq.baseURL") private var customServer: String = ""

    @State private var query: String = ""

    /// Returns the visible list after applying the search filter.
    /// Search matches name, description, region and host — operator
    /// contact deliberately not searchable, you shouldn't be looking
    /// instances up by maintainer email.
    private var filtered: [ServerEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return directory.servers }
        return directory.servers.filter { entry in
            entry.name.lowercased().contains(q)
                || entry.description.lowercased().contains(q)
                || entry.region.lowercased().contains(q)
                || entry.displayHost.lowercased().contains(q)
        }
    }

    private var currentURL: String {
        customServer.isEmpty ? ServerDirectoryService.defaultEntry.url : customServer
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerBlock
                    searchField
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(filtered) { entry in
                                row(for: entry)
                            }
                            if filtered.isEmpty {
                                emptyState
                            }
                            Spacer(minLength: 24)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                    }
                }
            }
            .navigationTitle("onboard.server.picker.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
            }
            .task {
                // Always force a refresh when the user opens the picker.
                // They explicitly want the freshest list; a 6h-stale
                // cache shouldn't be what they see.
                await directory.refresh()
            }
        }
    }

    // MARK: - sections

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("onboard.server.picker.intro.title".localized)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text("onboard.server.picker.intro.body".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.Color.textSecondary)
                .font(.system(size: 13, weight: .semibold))
            TextField(
                "onboard.server.picker.search".localized,
                text: $query
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(Theme.Color.textSecondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(10)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func row(for entry: ServerEntry) -> some View {
        let selected = entry.url == currentURL
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // Writing the default URL as empty keeps the existing
            // "empty means default" convention used by APIClient and
            // CustomServerSheet — no need to normalise it elsewhere.
            if entry.url == ServerDirectoryService.defaultEntry.url {
                customServer = ""
            } else {
                customServer = entry.url
            }
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Spacer(minLength: 8)
                    if !entry.region.isEmpty && entry.region != "—" {
                        Text(entry.region)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundColor(Theme.Color.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Theme.Color.bgPrimary)
                            )
                    }
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                }
                if !entry.description.isEmpty {
                    Text(entry.description)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Text(entry.displayHost)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.operatorContact.isEmpty {
                        Text("·")
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary.opacity(0.6))
                        Text(entry.operatorContact)
                            .font(.caption2)
                            .foregroundColor(Theme.Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.Color.bgSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        selected ? Theme.Color.accent : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(Theme.Color.textSecondary.opacity(0.5))
            Text("onboard.server.picker.empty".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
