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
    /// What the trust door said about the typed address (design §3): an
    /// address error under the field, or the banner when the fingerprint
    /// disagrees with what this device already holds. Nothing is written or
    /// dialled in either case.
    @State private var typedError: String?
    @State private var trustChange: IslandTrust.Change?

    /// Writing the default URL as EMPTY keeps the "empty means default"
    /// convention APIClient and CustomServerSheet already rely on.
    private func choose(_ entry: ServerEntry) {
        customServer = entry.url == ServerDirectoryService.defaultEntry.url ? "" : entry.url
        dismiss()
    }

    /// Through the trust door first (design §3): a `#fingerprint` is on file
    /// as typed before the register that follows, a bad one is an address
    /// error, one that disagrees with the record on file is the banner. The
    /// door hands back the normalised address, scheme and all, so the fragment
    /// cannot be dropped on the way and this screen has no second normaliser
    /// to drift from the one the store keys itself with.
    private func chooseTyped() {
        let raw = typedHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        typedError = nil
        trustChange = nil
        let host: String
        switch IslandTrust.shared.admit(typed: raw) {
        case .notAFingerprint:
            typedError = "island.trust.not_fingerprint".localized
            return
        case .caOnlyHost:
            typedError = "island.trust.ca_only".localized
            return
        case .changed(let change):
            trustChange = change
            return
        case .admitted(let address):
            host = address
        }
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
                                IslandCardView(entry: entry, selected: entry.url == currentURL).tag(index)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .always))
                        .indexViewStyle(.page(backgroundDisplayMode: .always))
                        .frame(maxHeight: .infinity)
                        // The dots sat right on the button. They belong with the deck
                        // they describe, not with the thing you press next.
                        .padding(.bottom, 10)
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
            // An address with a host in it, judged by the same parser the door
            // and the store use, so this screen cannot hand on something it
            // could not key. A `#fragment` is not judged here: a bad one is
            // the door's own error message, not a dead button.
            .disabled(IslandTrust.dialAddress(typedHost) == nil)
            if let typedError {
                Text(typedError)
                    .font(.caption)
                    .foregroundColor(.red.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let trustChange {
                IslandTrustChangedBanner(change: trustChange) {
                    typedHost = trustChange.rewriting(typedHost)
                    self.trustChange = nil
                    chooseTyped()
                }
                .cornerRadius(10)
            }
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
    /// The mirrored logo from the catalogue, when the island has one. Nil falls
    /// back to the lettered tile, which is what an island whose operator never
    /// set a logo gets everywhere else in the app.
    var logoURL: String?

    @State private var image: UIImage?
    /// Flipped once on appear; the animation below turns that one change into a
    /// slow drift that never settles. Four points either way over two and a
    /// half seconds: enough to read as floating, not enough to be a thing that
    /// moves while somebody is trying to read the name under it.
    @State private var drifting = false

    @State private var logo: UIImage?

    init(host: String, name: String, logoURL: String? = nil) {
        self.host = host
        self.name = name
        self.logoURL = logoURL
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
            .frame(height: 190)
            // ⚠ The drift belongs on the PAINTING and nowhere else. It used to
            // sit on this whole stack, which had two wrong effects at once: the
            // logo bobbed with the island (it is a mark, it should sit still)
            // and the picture, whose branch changes the moment the bytes
            // arrive, blinked instead of moving, because the repeating
            // animation caught that change too (founder, 24.08).
            .offset(y: drifting ? -4 : 4)
            Group {
                if let logo {
                    Image(uiImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                        .clipShape(RoundedRectangle(cornerRadius: 34 * 0.28, style: .continuous))
                } else {
                    IslandAvatarView(name: name, host: host, size: 34)
                }
            }
            .offset(y: 6)
        }
        .frame(height: 196)
        // ⚠ withAnimation on the NEXT runloop tick, not `.animation(value:)` on
        // appear. A page of a TabView is built before it is on screen, and the
        // flag flipped in the same frame the view was first laid out: SwiftUI
        // had no previous value to animate from, so the island simply sat there
        // until something forced the sheet to rebuild (founder, 24.08: "not
        // always floating, reopen and it starts"). Deferring by a tick gives it
        // the two states it needs, and the guard keeps a rebuild from stacking
        // a second repeating animation on the same view.
        .onAppear {
            guard !drifting else { return }
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                    drifting = true
                }
            }
        }
        .task(id: host) {
            image = await IslandArtStore.shared.load(host: host)
        }
        .task(id: logoURL ?? "") {
            logo = await IslandArtStore.shared.logo(urlString: logoURL)
        }
    }
}

/// One island: its painting, its own logo on it, and what it says about itself.
///
/// Shared by the onboarding picker and the add-account sheet, because they are
/// the same question asked twice and were drifting apart as two lists.
struct IslandCardView: View {
    let entry: ServerEntry
    var selected: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            // A capped gap above and free slack below. Splitting the space
            // evenly put the island low: the name, host and blurb under it
            // carry most of the height, so an honestly-centred card reads as
            // bottom-heavy. Sixteen points of air at the top and the rest
            // underneath lands it where the eye expects (founder, 24.08).
            Spacer(minLength: 0).frame(maxHeight: 16)
            IslandArtView(host: entry.displayHost, name: entry.name, logoURL: entry.logo)
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
                // Capped. is2's blurb is a paragraph, and unbounded it ran
                // straight through the page dots under the deck (founder,
                // 24.08). Three lines say what kind of island it is; the rest
                // is for the catalogue page, not for a card being swiped.
                Text(entry.description)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
    }
}
