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

    /// Which card is up. Also what the Use button acts on: a swipe is the
    /// selection, and asking for a second tap on the card to "select" it before
    /// the button would be a step nobody expects here.
    @State private var page: Int = 0
    /// The typed path. A self-hoster's island, and any island an organisation
    /// hands out privately, is never in the catalogue.
    @State private var manualEntry: Bool = false
    @State private var typedHost: String = ""

    /// Writing the default URL as EMPTY keeps the "empty means default"
    /// convention APIClient and CustomServerSheet already rely on.
    private func choose(_ entry: ServerEntry) {
        customServer = entry.url == ServerDirectoryService.defaultEntry.url ? "" : entry.url
        dismiss()
    }

    private func chooseTyped() {
        var host = typedHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        if !host.hasPrefix("http://") && !host.hasPrefix("https://") { host = "https://" + host }
        while host.hasSuffix("/") { host.removeLast() }
        customServer = host == ServerDirectoryService.defaultEntry.url ? "" : host
        dismiss()
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
                    if manualEntry || directory.servers.isEmpty {
                        manualBlock
                    } else {
                        // Cards you swipe, not rows you scan. An island is a
                        // place, and the catalogue is short enough that a list
                        // of grey rows was hiding that rather than showing it.
                        // Android draws the same thing card for card.
                        TabView(selection: $page) {
                            ForEach(Array(directory.servers.enumerated()), id: \.element.id) { index, entry in
                                card(for: entry).tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .always))
                        .indexViewStyle(.page(backgroundDisplayMode: .always))
                        .frame(maxHeight: .infinity)
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            choose(directory.servers[min(page, directory.servers.count - 1)])
                        } label: {
                            Text("island.use".localized)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Capsule().fill(Theme.Color.accent))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 18)
                        Button("island.manual_entry".localized) { manualEntry = true }
                            .font(.callout)
                            .foregroundColor(Theme.Color.accent)
                            .padding(.top, 12)
                            .padding(.bottom, 18)
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


    /// One island: its painting, its own logo on it, and what it says about
    /// itself. The picture is decoration the project ships, so every island has
    /// one; the logo is the operator's and may be absent, in which case the
    /// lettered tile stands in, exactly as it does everywhere else.
    private func card(for entry: ServerEntry) -> some View {
        let selected = entry.url == currentURL
        return VStack(spacing: 8) {
            IslandArtView(host: entry.displayHost, name: entry.name)
            Text(entry.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            HStack(spacing: 6) {
                Text(entry.displayHost)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                if !entry.region.isEmpty && entry.region != "—" {
                    Text("·").font(.caption).foregroundColor(Theme.Color.textSecondary.opacity(0.6))
                    Text(entry.region).font(.caption).foregroundColor(Theme.Color.textSecondary)
                }
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(Theme.Color.accent)
                }
            }
            if !entry.description.isEmpty {
                Text(entry.description)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.Color.bgSecondary))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(selected ? Theme.Color.accent : Color.clear, lineWidth: 1.5)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 34)   // clear of the page dots
    }

    /// Typing an address, and also what an unreachable catalogue falls back to:
    /// a blocked network must never leave this sheet empty.
    private var manualBlock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .foregroundColor(Theme.Color.textSecondary)
                TextField("island.host_hint".localized, text: $typedHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(10)
            Button {
                chooseTyped()
            } label: {
                Text("island.use".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Theme.Color.accent))
            }
            .buttonStyle(.plain)
            .disabled(typedHost.trimmingCharacters(in: .whitespaces).isEmpty)
            if !directory.servers.isEmpty {
                Button("island.back_to_list".localized) { manualEntry = false }
                    .font(.callout)
                    .foregroundColor(Theme.Color.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }

}

/// The island's painting with its own logo standing on it.
///
/// Seeded from the memory cache so a card that has been seen before opens on
/// the picture rather than flashing an empty frame first, the same trick
/// PersonAvatarView and IslandAvatarView already use.
private struct IslandArtView: View {
    let host: String
    let name: String

    @State private var image: UIImage?

    init(host: String, name: String) {
        self.host = host
        self.name = name
        _image = State(initialValue: IslandArtStore.shared.cached(host: host))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(height: 150)
            IslandAvatarView(name: name, host: host, size: 34)
                .offset(y: 6)
        }
        .frame(height: 156)
        .task(id: host) {
            image = await IslandArtStore.shared.load(host: host)
        }
    }
}
