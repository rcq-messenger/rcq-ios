import SwiftUI
import UIKit
import WebKit

/// The `.rcq` browser: the network's own pages, and nothing else.
///
/// Design: `RCQ/docs/rcq-sites-design.md`. The three clients share a shape;
/// the normative reference is `web-chat/src/pages/Sites.tsx`, and Android's
/// `SitesScreen.kt` is the other phone. What matters for reading this file:
///
/// * The page is already SAFE before it reaches the web view. Everything was
///   fetched, signature-checked, hash-checked and sanitised in
///   `SitesRepository`; stylesheets and images are inlined and every anchor has
///   lost its `href`, so the document handed over here is self-contained and
///   refers to nothing. `LockedSiteWebView` locks the view anyway, because two
///   locks are the point.
/// * `.rcq` is not DNS and never leaves this device as a name: the address is
///   parsed HERE into an island and a site, and the request goes straight to
///   that island — never through the reader's own, which would otherwise hold a
///   journal of what its users read elsewhere.
/// * Pages of one site are moved between out here, in our own chrome. With no
///   scripts inside there is nothing in a page that could navigate itself, and
///   that is the point rather than a limitation. The one kind of link a page
///   keeps is a door back into the network (`SiteReaderLinks`): a tap on it
///   is cancelled in the web view and answered here.
struct SitesView: View {
    @Environment(\.dismiss) private var dismiss

    /// What to open on arrival: a `.rcq` link tapped in a chat lands here.
    /// Nil, or an empty address, is the start screen.
    var initial: AppState.SiteOpenRequest? = nil

    @State private var typed = ""
    @State private var addr: SiteAddress?
    @State private var page: SitesRepository.SitePage?
    /// `page.html` with its in-network anchors made tappable, armed ONCE when
    /// the page lands rather than on every redraw: it is a regex pass over a
    /// document that can run to half a megabyte.
    @State private var armed = ""
    @State private var failure: SiteError?
    @State private var loading = false
    @State private var editing = false
    @State private var catalogue: [SitesRepository.SiteListing] = []
    @State private var recents: [SiteRecents.Entry] = []
    /// Which open is the current one. Back and every new open bump it, and a
    /// fetch that comes home to find it changed lands nowhere: the reader has
    /// already left the page it was for.
    @State private var turn = 0
    /// `name@host` → its verified mark, or nil once we know there is none. The
    /// pin key rather than the typed address, so a catalogue row and the page
    /// it opens are one site, and `blog` here and `blog` on another island in
    /// the recents are two.
    @State private var marks: [String: UIImage?] = [:]
    /// The address being handed to a chat, while the picker is up.
    @State private var shareTarget: ShareTarget?
    /// "Address sent to X", for a moment after the picker closes: the message
    /// itself lands in a chat the reader is not looking at.
    @State private var sentNote: String?

    private struct ShareTarget: Identifiable {
        let id = UUID()
        let address: String
    }

    /// "My island" for a bare `name.rcq`, so somebody's first site is reachable
    /// before they know what an island is.
    ///
    /// ⚠ `Multihome.ownHost()`, not `APIClient.shared.baseURL.host`: the second
    /// is the TRANSPORT, and when the direct probe fails it silently becomes the
    /// Cloudflare front. A reader whose tunnel came up would then resolve
    /// `blog.rcq` to a site on `cdn.rcq.app`, which is not an island and hosts
    /// nothing.
    private let ownHost = Multihome.ownHost()

    var body: some View {
        ZStack {
            Theme.Color.bgPrimary.ignoresSafeArea()
            VStack(spacing: 0) {
                addressBar
                progressHairline
                sentBanner
                pageStrip
                keyChangedBanner
                content
            }
        }
        .sheet(item: $shareTarget) { target in
            // The app's own picker, with the address as the payload: the
            // person picks a chat or a contact and the address goes out as an
            // ordinary text message (#852).
            ForwardPickerSheet(
                onPick: { destination in share(target.address, to: destination) },
                onCancel: { shareTarget = nil }
            )
        }
        .task {
            // The page first, so a link tapped in a chat is loading while the
            // start screen underneath it is still being fetched.
            if let initial, let address = initial.address {
                open(address, path: initial.page ?? "index.html")
            }
            recents = SiteRecents.shared.all()
            let rows = await SitesRepository.shared.catalogue(host: ownHost)
            catalogue = rows
            // Marks are fetched after the list is drawn, and each is checked
            // against the owner's signature before it is shown. A list that
            // waited for them would be a list an offline site could hold up.
            for row in rows {
                guard let a = SiteAddressParser.parse("\(row.name).rcq", ownHost: ownHost) else { continue }
                let mark = await SitesRepository.shared.mark(a)
                marks[a.pinKey] = mark.flatMap { UIImage(data: $0.bytes) }
            }
            // ⚠⚠ Marks are asked of THIS island only. A recent row on
            // somebody else's island is drawn with its letter until it is
            // opened: asking that island for the mark would tell it "this
            // address still has me in its list" every time the reader merely
            // opens the browser, and the promise here is that an island learns
            // about a reader when the reader opens something on it.
            for entry in SiteRecents.shared.all() where marks[entry.key] == nil && entry.host == ownHost {
                let a = SiteAddress(
                    name: entry.name,
                    host: entry.host,
                    display: SiteAddressParser.display(name: entry.name, host: entry.host, ownHost: ownHost)
                )
                let mark = await SitesRepository.shared.mark(a)
                marks[a.pinKey] = mark.flatMap { UIImage(data: $0.bytes) }
            }
        }
    }

    // MARK: - The address bar

    /// One capsule across the row, the way a desktop browser does it: the
    /// address IS the control, and the way back lives inside it, at the left
    /// edge (founder, 02.09). Idle the address sits centred between the site's
    /// mark and a reload glyph; editing it is an ordinary text field,
    /// left-aligned and selected, and the keyboard's Go opens it.
    ///
    /// Centred on the CAPSULE, not on what the controls leave of it. The two
    /// side groups are unequal - a chevron and a mark on the left, share and
    /// reload on the right - and a field squeezed between them has its middle
    /// off the capsule's, which is where the founder saw the domain sitting
    /// (02.09). So both sides get the same slot, as wide as the wider group,
    /// and the field's centre is the capsule's in every idle state: the
    /// catalogue's placeholder, a page's address, the spinner while it reloads.
    /// Editing is left-aligned, and the slots shrink to the chevron so the
    /// typed text starts beside it.
    ///
    /// There is no Open button anywhere on this screen: that would be a second
    /// way to do what the Go key already does (founder, 01.09).
    private var addressBar: some View {
        let idle = page != nil && !editing
        // Two glyphs and their gap on the right; the chevron, its gap and the
        // mark on the left are narrower and take the same width.
        let slot: CGFloat = idle ? 28 + 8 + 28 : 28
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    back()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.Color.accent)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("sites.back".localized)

                // The mark stands in for the padlock a browser puts here, and
                // it means the same thing: this is the site it says it is,
                // checked against the owner's signature.
                if let addr, idle {
                    SiteMarkView(name: addr.name, image: marks[addr.pinKey] ?? nil, size: 18)
                }
            }
            .frame(width: slot, alignment: .leading)

            SiteAddressField(
                text: $typed,
                placeholder: "sites.address.placeholder".localized,
                centred: !editing,
                onEditingChanged: { now in
                    editing = now
                    if !now, let addr { typed = addr.display }
                },
                onGo: { open($0) }
            )

            HStack(spacing: 8) {
                if let page, idle {
                    // The address as text, into a chat: what a person who
                    // wants to show somebody a page actually needs (#852).
                    Button {
                        if let addr { shareTarget = ShareTarget(address: addr.display) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.Color.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .accessibilityLabel("sites.share".localized)

                    if loading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.6)
                            .frame(width: 28, height: 28)
                    } else {
                        // Reload, and it really reloads: a bundle is served
                        // with a short cache, which is right for reading and
                        // wrong for somebody who just republished.
                        Button {
                            if let addr { open(addr.display, path: page.path, fresh: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Theme.Color.textSecondary)
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("sites.reload".localized)
                    }
                }
            }
            .frame(width: slot, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        .background(Theme.Color.bgSecondary)
        .clipShape(Capsule())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// The chevron leaves the PAGE before it leaves the browser: on a page,
    /// or on an error for an address, it returns to the catalogue, and only
    /// from the catalogue does it dismiss (founder, 02.09, all three clients).
    /// A fetch still in flight for the page is disowned rather than allowed to
    /// land on top of the catalogue.
    private func back() {
        guard page != nil || failure != nil || addr != nil else {
            dismiss()
            return
        }
        turn += 1
        page = nil
        armed = ""
        addr = nil
        failure = nil
        typed = ""
        loading = false
        // The page just left is now the newest recent.
        recents = SiteRecents.shared.all()
    }

    /// A hair of progress under the bar. The spinner in the capsule says
    /// "something is happening"; this says the screen is still busy even while
    /// the capsule is being typed into.
    private var progressHairline: some View {
        Rectangle()
            .fill(loading ? Theme.Color.accent.opacity(0.7) : Color.clear)
            .frame(height: 2)
    }

    @ViewBuilder
    private var sentBanner: some View {
        if let sentNote {
            Text(sentNote)
                .font(.system(size: 12))
                .foregroundColor(Theme.Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
                .background(Theme.Color.bgSecondary)
        }
    }

    // MARK: - The other pages of this site

    /// With no scripts in the view, a link inside a page cannot navigate — so
    /// the doors live out here.
    @ViewBuilder
    private var pageStrip: some View {
        if let page, page.pages.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(page.pages, id: \.self) { p in
                        let here = p == page.path
                        Button {
                            if let addr { open(addr.display, path: p) }
                        } label: {
                            Text(p)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(here ? Theme.Color.textPrimary : Theme.Color.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(here ? Theme.Color.bgSecondary : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - A key that changed since the last visit

    /// The one thing worth interrupting for: these bytes are signed by somebody
    /// other than last time, which is exactly what the signature exists to make
    /// visible. The page is still drawn — a reader who cannot see it cannot
    /// judge it.
    @ViewBuilder
    private var keyChangedBanner: some View {
        if let shown = page, shown.keyChanged {
            HStack(spacing: 12) {
                Text("sites.key_changed".localized)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    guard let addr else { return }
                    SitePins.shared.repin(addr, key: shown.key)
                    page = SitesRepository.SitePage(
                        html: shown.html,
                        path: shown.path,
                        pages: shown.pages,
                        version: shown.version,
                        key: shown.key,
                        keyChanged: false,
                        title: shown.title
                    )
                } label: {
                    Text("sites.key_changed.accept".localized)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.Color.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.Color.statusBusy.opacity(0.15))
        }
    }

    // MARK: - The page, the catalogue, or what went wrong

    @ViewBuilder
    private var content: some View {
        if let failure {
            // Six errors, six plain sentences. The spellings are shared with
            // the web and Android (`SiteError`'s raw values), so the key falls
            // straight out of the case.
            Text("sites.error.\(failure.rawValue)".localized)
                .font(.system(size: 13))
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(24)
        } else if let page {
            // Under the home indicator too, so the strip down there is the
            // page's own background and not our ground: a dark page over our
            // light one drew a bright island at the bottom of the screen
            // (founder, 02.09). The page's text still stops short of the
            // indicator, see `SiteWebView`.
            LockedSiteWebView(html: armed) { target in
                guard let addr else { return }
                switch target {
                case .page(let p):
                    // A page, not any file the manifest signs. The sanitiser
                    // marks every in-bundle link, and a page from the 2000s
                    // links its full-size photographs that way; opening one
                    // decoded its bytes as text and painted the rubble.
                    guard Self.isPage(p) else { return }
                    open(addr.display, path: p)
                case .site(let link):
                    // ⚠ A name with no island in it belongs to the island THIS
                    // page came from, the way a bare name in a web page belongs
                    // to the site's own zone. Resolved against the reader's
                    // island instead, an author on the flagship writing
                    // `e2ee.rcq` sent every reader on another island to whoever
                    // holds that name over there.
                    let page = Self.isPage(link.page) ? link.page : "index.html"
                    if let bare = SiteAddressParser.parse(link.address, ownHost: addr.host),
                       bare.host == addr.host {
                        open(
                            SiteAddressParser.display(name: bare.name, host: addr.host, ownHost: ownHost),
                            path: page
                        )
                    } else {
                        open(link.address, path: page)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .bottom)
        } else {
            emptyScreen
        }
    }

    // MARK: - The start screen

    /// One row of the start screen, whichever section it came from.
    private struct SiteRow: Identifiable {
        /// `name@host`, the identity the pins and the recents share.
        let key: String
        let name: String
        /// What opens on a tap and what is handed to a chat by the share
        /// glyph: `name.rcq` at home, `name.island.rcq` elsewhere.
        let address: String
        let title: String?
        /// A recent, which the person can take off the list.
        let removable: Bool
        /// Whose site it is, when its author asked to be named. Nil means the
        /// author did not ask, which is the default and not a missing value,
        /// so the row simply carries no byline.
        let ownerUIN: Int?

        var id: String { key }
    }

    /// Pinned, then recent, then the rest of the catalogue (founder, 02.09,
    /// all three clients). A site appears once, in the first section it
    /// belongs to: the island's own front page is pinned, so opening it does
    /// not also make it a recent, and a recent that is in the catalogue is
    /// not listed twice under it.
    private var emptyScreen: some View {
        let pinned = catalogue.filter(\.featured).map(listingRow)
        var shown = Set(pinned.map(\.key))
        let recent = recents.filter { !shown.contains($0.key) }.map(recentRow)
        shown.formUnion(recent.map(\.key))
        let rest = catalogue.filter { !shown.contains("\($0.name)@\(ownHost)") }.map(listingRow)

        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("sites.empty.title".localized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text("sites.empty.body".localized)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                section("sites.pinned", pinned)
                section("sites.recents", recent)
                section("sites.catalogue", rest)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func listingRow(_ row: SitesRepository.SiteListing) -> SiteRow {
        SiteRow(
            key: "\(row.name)@\(ownHost)",
            name: row.name,
            address: "\(row.name).rcq",
            title: row.title,
            removable: false,
            ownerUIN: row.ownerUIN
        )
    }

    private func recentRow(_ entry: SiteRecents.Entry) -> SiteRow {
        SiteRow(
            key: entry.key,
            name: entry.name,
            address: SiteAddressParser.display(name: entry.name, host: entry.host, ownHost: ownHost),
            title: entry.title,
            removable: true,
            // A recent is what this device remembers about a page it opened,
            // and it never carried a byline. The catalogue is where an author
            // who asked to be named is named.
            ownerUIN: nil
        )
    }

    @ViewBuilder
    private func section(_ heading: String, _ rows: [SiteRow]) -> some View {
        if !rows.isEmpty {
            Text(heading.localized.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.Color.textSecondary)
                .padding(.top, 6)
            ForEach(rows) { row in
                if row.removable {
                    siteRow(row).contextMenu {
                        Button(role: .destructive) {
                            SiteRecents.shared.remove(key: row.key)
                            recents = SiteRecents.shared.all()
                        } label: {
                            Label("sites.recents.remove".localized, systemImage: "xmark")
                        }
                    }
                } else {
                    siteRow(row)
                }
            }
        }
    }

    /// The share glyph is a SIBLING of the row's button, not a button inside
    /// its label: a tap on it has to be its own and not also open the site.
    private func siteRow(_ row: SiteRow) -> some View {
        HStack(spacing: 10) {
            Button {
                open(row.address)
            } label: {
                HStack(spacing: 10) {
                    SiteMarkView(name: row.name, image: marks[row.key] ?? nil, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.address)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                            .lineLimit(1)
                        if let title = row.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(title)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Color.textSecondary)
                                .lineLimit(1)
                        }
                        // Named only because the author asked to be. The island
                        // leaves the field out otherwise, so there is nothing
                        // here to fall back to and nothing that could read as
                        // "by #" with no number after it.
                        if let owner = row.ownerUIN {
                            Text(String(format: "sites.by_owner".localized, String(owner)))
                                .font(.system(size: 11))
                                .foregroundColor(Theme.Color.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                shareTarget = ShareTarget(address: row.address)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("sites.share".localized)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Sharing

    /// The address goes out as an ordinary text message; the receiving
    /// client's linkifier is what makes it a tap into their reader.
    private func share(_ address: String, to destination: ForwardPickerSheet.Destination) {
        shareTarget = nil
        Task {
            let name: String
            do {
                switch destination {
                case .contact(let c):
                    try await MessageService.shared.send(text: address, to: c)
                    name = c.nickname
                case .group(let g):
                    try await MessageService.shared.send(text: address, to: g)
                    name = g.name
                }
            } catch {
                return
            }
            sentNote = String(format: "sites.share.sent".localized, name)
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            sentNote = nil
        }
    }

    // MARK: - Opening

    /// What may be opened as a page. The manifest signs pictures and
    /// stylesheets too, and neither is a page: decoded as text and parsed as
    /// HTML they paint a screen of rubble, with the bar claiming the site is
    /// showing `photo.jpg`.
    static func isPage(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.hasSuffix(".html") || p.hasSuffix(".htm")
    }

    private func open(_ raw: String, path: String = "index.html", fresh: Bool = false) {
        turn += 1
        let mine = turn
        guard let parsed = SiteAddressParser.parse(raw, ownHost: ownHost) else {
            // Nothing has been sent anywhere: an address we cannot parse is an
            // address we must not guess at.
            failure = .address
            page = nil
            loading = false
            return
        }
        loading = true
        failure = nil
        // The address goes into the bar now, not when the page lands: a link
        // tapped in a chat arrives with an empty bar, and an island that does
        // not answer would otherwise leave "Could not reach that island" under
        // a placeholder, with no sign of which island.
        typed = parsed.display
        Task {
            do {
                let got = try await SitesRepository.shared.page(parsed, path: path, fresh: fresh)
                guard mine == turn else { return }
                armed = SiteReaderLinks.arm(got.html)
                page = got
                addr = parsed
                typed = parsed.display
                loading = false
                // A page that opened is a site this device read; a page that
                // failed is not.
                SiteRecents.shared.touch(parsed, title: got.title)
                // The mark of the site being read, fetched AFTER the page so a
                // slow icon never holds the page up.
                let mark = await SitesRepository.shared.mark(parsed, fresh: fresh)
                marks[parsed.pinKey] = mark.flatMap { UIImage(data: $0.bytes) }
            } catch let e as SiteError {
                guard mine == turn else { return }
                page = nil
                failure = e
                loading = false
            } catch {
                guard mine == turn else { return }
                page = nil
                failure = .offline
                loading = false
            }
        }
    }
}

// MARK: - The mark

/// A site's mark, or its first letter while there is none. The letter is not a
/// placeholder waiting for a picture: most sites will never have one, and a row
/// that jumps when an icon lands is worse than a row that never had it.
private struct SiteMarkView: View {
    let name: String
    let image: UIImage?
    var size: CGFloat = 26

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, design: .monospaced))
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Color.bgSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }
}

// MARK: - The address field

/// The address itself, as a `UITextField` rather than SwiftUI's `TextField`.
///
/// Two things this screen needs have no SwiftUI API: the keyboard's **Go** key
/// (`returnKeyType`), which is the ONLY way to open an address here, and
/// selecting the whole address the moment the field is tapped, which is what
/// every browser does and what makes replacing an address one gesture instead
/// of three.
private struct SiteAddressField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let centred: Bool
    let onEditingChanged: (Bool) -> Void
    let onGo: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.returnKeyType = .go
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.clearButtonMode = .never
        field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        field.textColor = UIColor(Theme.Color.textPrimary)
        field.tintColor = UIColor(Theme.Color.accent)
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
        field.textAlignment = centred ? .center : .natural
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: UIColor(Theme.Color.textSecondary),
                .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            ]
        )
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SiteAddressField

        init(_ parent: SiteAddressField) { self.parent = parent }

        @objc func editingChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onEditingChanged(true)
            // ⚠ A run loop turn later on purpose: the tap that got us here
            // places its own caret AFTER this callback returns, and a
            // `selectAll` made inline is undone by it.
            DispatchQueue.main.async { textField.selectAll(nil) }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onEditingChanged(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            parent.onGo(textField.text ?? "")
            return false
        }
    }
}

// MARK: - The locked web view

/// The one rule list: block every load.
///
/// ⚠⚠ On iOS this is the ONLY network switch a `WKWebView` has, and it is not
/// an opinion — there is no request-interception API at all. `NSURLProtocol` is
/// never consulted by the web content process, so the classic hook is dead
/// here; `setURLSchemeHandler(_:forURLScheme:)` raises an exception for `http`
/// and `https` because those are WebKit's own. Android's pair
/// (`blockNetworkLoads` plus `shouldInterceptRequest`) has no counterpart on
/// this platform. Delete this and the view is on the open network with nothing
/// in front of it.
///
/// ⚠⚠ The second rule is not a loophole and must not be tightened without
/// looking at the screen. `.*` alone renders an EMPTY PAGE — no text, no
/// pictures — while `didCommit` and `didFinish` both fire and the title comes
/// back blank, so nothing about it reads as an error. The reason is that
/// `loadHTMLString(_:baseURL: nil)` hands WebKit a `data:` URL underneath:
/// the navigation delegate is shown `about:blank`, but the rule engine matches
/// the real one, so a blanket block swallows the document we wrote ourselves.
/// The inlined images are `data:` for the same reason. Measured in the
/// simulator, 02.09: `.*` alone → blank; exempting `^about:blank` → still
/// blank; exempting `^data:` → the page and its pictures.
///
/// What it costs is nothing: `data:` is bytes already in this process. Every
/// scheme that can reach a network — http, https, ws, wss, blob, whatever is
/// added next — is still caught by the first rule, because the first rule
/// names none of them.
///
/// Compiled once for the life of the process: `WKContentRuleListStore` also
/// keeps it on disk under this identifier, so a second launch looks it up
/// rather than compiling again. ⚠ Bump the identifier when the source changes,
/// or the store hands back the rules it compiled from the old one.
@MainActor
private final class SiteBlockAllRules {
    static let shared = SiteBlockAllRules()

    private static let identifier = "rcq.sites.block-all.v3"
    private static let source = #"""
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """#

    private var compiled: WKContentRuleList?
    private var task: Task<WKContentRuleList?, Never>?

    func list() async -> WKContentRuleList? {
        if let compiled { return compiled }
        if let task { return await task.value }
        let work = Task<WKContentRuleList?, Never> { [id = Self.identifier, src = Self.source] in
            let store = WKContentRuleListStore.default()
            if let found = await withCheckedContinuation({ (k: CheckedContinuation<WKContentRuleList?, Never>) in
                store?.lookUpContentRuleList(forIdentifier: id) { list, _ in k.resume(returning: list) }
            }) {
                return found
            }
            return await withCheckedContinuation { (k: CheckedContinuation<WKContentRuleList?, Never>) in
                store?.compileContentRuleList(forIdentifier: id, encodedContentRuleList: src) { list, _ in
                    k.resume(returning: list)
                }
            }
        }
        task = work
        let result = await work.value
        compiled = result
        task = nil
        return result
    }
}

/// The web view runs to the bottom of the screen so the strip under the home
/// indicator is painted in the page's own colour; this is what keeps the page's
/// last line from ending underneath the indicator. The inset is written by
/// hand from the safe area rather than left to the scroll view, so the
/// `.never` in `makeUIView` stays the one word it is and the only inset the
/// page ever gets is the bottom one.
private final class SiteWebView: WKWebView {
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        scrollView.contentInset.bottom = safeAreaInsets.bottom
        scrollView.verticalScrollIndicatorInsets.bottom = safeAreaInsets.bottom
    }
}

/// A `WKWebView` that can render and can do nothing else.
///
/// ⚠⚠ Every line in `makeUIView` is load-bearing, and the order they are argued
/// in is:
///
/// * `allowsContentJavaScript` DEFAULTS TO TRUE, and it is set in both places
///   it can be set — on the configuration's `defaultWebpagePreferences` and
///   again on the preferences handed to `decidePolicyFor`, because the second
///   overrides the first for the navigation it belongs to and a delegate that
///   forgets it hands the page a scripting engine.
/// * The content rule list is the network switch (see `SiteBlockAllRules`), and
///   the load waits for it: a view that painted first and blocked second would
///   have a window in which it is an ordinary browser.
/// * A non-persistent data store, so nothing about a visit lands on disk.
///   `allowsLinkPreview` and `isFraudulentWebsiteWarningEnabled` are both OFF
///   because both reach the network by themselves — the first fetches a preview
///   of whatever a link points at, the second sends a hash prefix of the URL to
///   a safe-browsing service.
/// * `loadHTMLString(html, baseURL: nil)`: an opaque origin, and with no base
///   URL a relative reference resolves nowhere.
/// * The navigation delegate CANCELS every navigation that is not the initial
///   load. That is the hole worth naming: when WebKit is allowed a navigation
///   whose scheme it cannot handle (`tel:`, `mailto:`, `itms-apps:`,
///   anything), it asks the system to open it, and the page has left the app.
///   `UIApplication.shared.open` appears nowhere in this file and must not.
///   A tap on one of `SiteReaderLinks`' doors is cancelled like the rest; it
///   is reported to the chrome FIRST, and the chrome does the opening.
///
/// The document handed over here is already self-contained — verified,
/// hash-checked, sanitised, with stylesheets and images inlined and every
/// `href` stripped, except the ones `SiteReaderLinks.arm` put back in a scheme
/// nobody answers — so none of these should ever fire. That is exactly why
/// they are cheap to keep.
private struct LockedSiteWebView: UIViewRepresentable {
    let html: String
    /// A tap on a door of ours: another page of this bundle, or another site.
    let onTap: (SiteReaderLinks.Target) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // ⚠ Default is TRUE. Place one of two.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        config.allowsInlineMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.suppressesIncrementalRendering = false

        let web = SiteWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = .white
        web.scrollView.backgroundColor = .white
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.onTap = onTap
        guard context.coordinator.painted != html else { return }
        context.coordinator.painted = html
        Task { @MainActor in
            if let rules = await SiteBlockAllRules.shared.list() {
                web.configuration.userContentController.removeAllContentRuleLists()
                web.configuration.userContentController.add(rules)
            }
            context.coordinator.expectingInitialLoad = true
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        /// The document currently painted, so a redraw of the SwiftUI view does
        /// not reload the page under the reader's scroll position.
        var painted: String?
        /// Set immediately before our own `loadHTMLString` and cleared by it.
        var expectingInitialLoad = false
        var onTap: ((SiteReaderLinks.Target) -> Void)?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            preferences: WKWebpagePreferences,
            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
        ) {
            // ⚠ The second place scripting can be switched on. The preferences
            // handed in here start as a copy of the configuration's, but they
            // are what the navigation actually uses, so this is not a
            // repetition of the line in `makeUIView`.
            preferences.allowsContentJavaScript = false

            let url = navigationAction.request.url

            // A door of ours, tapped by a finger: the chrome opens it and the
            // web view stays where it is. Only a link activation counts, so a
            // page that somehow raised the same URL by other means is refused
            // like every other navigation below.
            if navigationAction.navigationType == .linkActivated,
               let url, let target = SiteReaderLinks.target(of: url) {
                onTap?(target)
                decisionHandler(.cancel, preferences)
                return
            }

            // Our own `loadHTMLString` and nothing else. A tapped link, a form,
            // a redirect, a `meta refresh` — all of them are a page trying to
            // go somewhere, and none of them may.
            let isOurs = expectingInitialLoad
                && navigationAction.navigationType == .other
                && (url == nil || url?.absoluteString == "about:blank")
            if isOurs {
                expectingInitialLoad = false
                decisionHandler(.allow, preferences)
            } else {
                decisionHandler(.cancel, preferences)
            }
        }

        /// No second window, ever. Returning nil is what keeps a `target=_blank`
        /// from becoming a web view with none of the locks above on it.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }
    }
}
