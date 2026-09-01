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
///   that is the point rather than a limitation.
struct SitesView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var typed = ""
    @State private var addr: SiteAddress?
    @State private var page: SitesRepository.SitePage?
    @State private var failure: SiteError?
    @State private var loading = false
    @State private var editing = false
    @State private var catalogue: [SitesRepository.SiteListing] = []
    /// site name → its verified mark, or nil once we know there is none. The
    /// key is the NAME rather than the address, exactly as on the other two
    /// clients: a catalogue row and the page it opens are one site.
    @State private var marks: [String: UIImage?] = [:]

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
                pageStrip
                keyChangedBanner
                content
            }
        }
        .task {
            let rows = await SitesRepository.shared.catalogue(host: ownHost)
            catalogue = rows
            // Marks are fetched after the list is drawn, and each is checked
            // against the owner's signature before it is shown. A list that
            // waited for them would be a list an offline site could hold up.
            for row in rows {
                guard let a = SiteAddressParser.parse("\(row.name).rcq", ownHost: ownHost) else { continue }
                let mark = await SitesRepository.shared.mark(a)
                marks[row.name] = mark.flatMap { UIImage(data: $0.bytes) }
            }
        }
    }

    // MARK: - The address bar

    /// One capsule, the way a desktop browser does it: the address IS the
    /// control. Idle it sits centred with the site's mark and a reload glyph;
    /// editing it is an ordinary text field, left-aligned and selected, and the
    /// keyboard's Go opens it.
    ///
    /// There is no Open button anywhere on this screen: that would be a second
    /// way to do what the Go key already does (founder, 01.09).
    private var addressBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.Color.accent)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("sites.back".localized)

            HStack(spacing: 8) {
                // The mark stands in for the padlock a browser puts here, and
                // it means the same thing: this is the site it says it is,
                // checked against the owner's signature.
                if let addr, page != nil, !editing {
                    SiteMarkView(name: addr.name, image: marks[addr.name] ?? nil, size: 18)
                }
                SiteAddressField(
                    text: $typed,
                    placeholder: "sites.address.placeholder".localized,
                    centred: !editing && page != nil,
                    onEditingChanged: { now in
                        editing = now
                        if !now, let addr { typed = addr.display }
                    },
                    onGo: { open($0) }
                )
                if let page, !editing {
                    if loading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.6)
                            .frame(width: 18, height: 18)
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
                                .frame(width: 18, height: 18)
                        }
                        .accessibilityLabel("sites.reload".localized)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.Color.bgSecondary)
            .clipShape(Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// A hair of progress under the bar. The spinner in the capsule says
    /// "something is happening"; this says the screen is still busy even while
    /// the capsule is being typed into.
    private var progressHairline: some View {
        Rectangle()
            .fill(loading ? Theme.Color.accent.opacity(0.7) : Color.clear)
            .frame(height: 2)
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
            LockedSiteWebView(html: page.html)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyScreen
        }
    }

    private var emptyScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("sites.empty.title".localized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text("sites.empty.body".localized)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !catalogue.isEmpty {
                    Text("sites.catalogue".localized.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.Color.textSecondary)
                        .padding(.top, 6)
                    ForEach(catalogue, id: \.name) { row in
                        Button {
                            open("\(row.name).rcq")
                        } label: {
                            HStack(spacing: 10) {
                                SiteMarkView(name: row.name, image: marks[row.name] ?? nil, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(row.name).rcq")
                                        .font(.system(size: 14, design: .monospaced))
                                        .foregroundColor(Theme.Color.textPrimary)
                                    if let title = row.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                                        Text(title)
                                            .font(.system(size: 11))
                                            .foregroundColor(Theme.Color.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    // MARK: - Opening

    private func open(_ raw: String, path: String = "index.html", fresh: Bool = false) {
        guard let parsed = SiteAddressParser.parse(raw, ownHost: ownHost) else {
            // Nothing has been sent anywhere: an address we cannot parse is an
            // address we must not guess at.
            failure = .address
            page = nil
            return
        }
        loading = true
        failure = nil
        Task {
            do {
                let got = try await SitesRepository.shared.page(parsed, path: path, fresh: fresh)
                page = got
                addr = parsed
                typed = parsed.display
                loading = false
                // The mark of the site being read, fetched AFTER the page so a
                // slow icon never holds the page up.
                let mark = await SitesRepository.shared.mark(parsed, fresh: fresh)
                marks[parsed.name] = mark.flatMap { UIImage(data: $0.bytes) }
            } catch let e as SiteError {
                page = nil
                failure = e
                loading = false
            } catch {
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
///
/// The document handed over here is already self-contained — verified,
/// hash-checked, sanitised, with stylesheets and images inlined and every
/// `href` stripped — so none of these should ever fire. That is exactly why
/// they are cheap to keep.
private struct LockedSiteWebView: UIViewRepresentable {
    let html: String

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

        let web = WKWebView(frame: .zero, configuration: config)
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

            // Our own `loadHTMLString` and nothing else. A tapped link, a form,
            // a redirect, a `meta refresh` — all of them are a page trying to
            // go somewhere, and none of them may.
            let url = navigationAction.request.url
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
