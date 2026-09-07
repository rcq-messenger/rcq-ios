import AVFoundation
import SwiftUI
import UIKit

/// QR surface for adding contacts. Two states, no tabs: the my-code state
/// renders a QR for `rcq://add/{ownUIN}`, the scan state opens the camera and
/// routes a detected `rcq://add/{uin}` to a contact-add request. One button
/// moves between them and the panes cross-fade, so the sheet can size itself
/// to whichever state is up (fitted for the code, full for the camera).
struct QRSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var auth = AuthService.shared
    @StateObject private var presence = PresenceService.shared
    @State private var mode: Mode = .myCode
    @State private var scanResult: ScanResult?
    /// Natural height of the my-code column, reported by the column itself.
    /// The sheet is sized to it so it ends at its bottom-most element instead
    /// of standing at full height with dead space under the buttons.
    @State private var codeHeight: CGFloat = 0
    @State private var detent: PresentationDetent = .height(QRSheet.estimatedCodeHeight)

    enum Mode: Hashable { case myCode, scan }

    /// Inline navigation bar: inside the sheet's height, outside the column
    /// we measure.
    private static let navigationBarHeight: CGFloat = 44
    /// First-frame guess, replaced the moment the column reports its real
    /// size. Close enough that the correction does not read as a jump.
    private static let estimatedCodeHeight: CGFloat = 600

    /// Home-indicator strip: also inside the sheet's height and outside the
    /// measured column.
    private static var bottomSafeInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.bottom ?? 0
    }

    private static func detent(forColumnHeight height: CGFloat) -> PresentationDetent {
        guard height > 0 else { return .height(estimatedCodeHeight) }
        return .height(height + navigationBarHeight + bottomSafeInset)
    }

    private var codeDetent: PresentationDetent { Self.detent(forColumnHeight: codeHeight) }

    /// Cross-fade to the other state. One control does this in both
    /// directions (the "scan a code" button on the code, the "my code" button
    /// on the camera), which is what replaced the segmented tabs.
    private func swap(to newMode: Mode) {
        withAnimation(.easeInOut(duration: 0.25)) { mode = newMode }
    }

    enum ScanResult: Equatable {
        case sent(uin: Int)
        /// §5f: a cross-island add now DOES cross the wire — we read the peer's
        /// open key card, write the local row, and deposit a `contactreq` with
        /// `act:"request"` to their island. "Request sent" is a true statement
        /// again, and only in this case.
        case crossIslandSent(uin: Int, host: String)
        /// The local row landed but their island did not take the request, so
        /// nothing is waiting on their phone. Kept as a separate case precisely
        /// because claiming "request sent" here is the bug §5f exists to fix.
        case addedLocally(uin: Int, host: String)
        case alreadyContact(uin: Int)
        case failed(message: String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                // Two states, one slot. With the tabs gone the swap itself has
                // to carry the change, so the panes sit on top of each other
                // and cross-fade.
                switch mode {
                case .myCode: myCodePane.transition(.opacity)
                case .scan:   scanPane.transition(.opacity)
                }
            }
            .navigationTitle("qr.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            // Over the camera the bar carries no ground of its own, so the
            // preview runs the full height of the sheet and the title and
            // Close button sit on the picture. `.dark` keeps them white there
            // whatever the app theme is; the code pane is untouched.
            .toolbarBackground(mode == .scan ? .hidden : .automatic, for: .navigationBar)
            .toolbarColorScheme(mode == .scan ? ColorScheme.dark : nil, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                // Handing the link to somebody who is not in the room: the
                // code itself only works face to face. This lived in Settings
                // as a toolbar button until the settings search took that slot,
                // and it belongs here anyway, next to the other two ways of
                // passing the same link on. Only on the code pane: there is
                // nothing to share while the camera is up.
                ToolbarItem(placement: .confirmationAction) {
                    if mode == .myCode, let uin = auth.ownUIN,
                       let url = URL(string: RcqFederation.buildContactLink(
                           RcqFederation.Address(uin: uin, host: Multihome.ownHost()),
                           card: OutgoingGuestCard.value,
                       )) {
                        ShareLink(
                            item: url,
                            subject: Text(auth.nickname.isEmpty ? "RCQ" : auth.nickname),
                            message: Text(String(
                                format: "settings.share.message".localized,
                                auth.nickname.isEmpty ? "RCQ" : auth.nickname,
                                uin
                            )),
                        ) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            .alert(
                alertTitle,
                isPresented: Binding(
                    get: { scanResult != nil },
                    set: { if !$0 { scanResult = nil } }
                ),
                presenting: scanResult
            ) { result in
                Button("common.ok".localized) {
                    if case .sent = result { dismiss() }
                    if case .crossIslandSent = result { dismiss() }
                    if case .addedLocally = result { dismiss() }
                    if case .alreadyContact = result { dismiss() }
                }
            } message: { result in
                Text(alertMessage(for: result))
            }
        }
        // The code stands exactly as tall as the code needs; the camera takes
        // the whole sheet, which is what the tabs used to eat into.
        .presentationDetents([codeDetent, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: mode) { newMode in
            detent = newMode == .scan ? .large : codeDetent
        }
        // ⚠ Take the INCOMING height: `codeHeight` read off `self` in here is
        // still the old value.
        .onChange(of: codeHeight) { height in
            guard mode == .myCode else { return }
            detent = Self.detent(forColumnHeight: height)
        }
    }

    // MARK: - my code

    @ViewBuilder
    private var myCodePane: some View {
        if let uin = auth.ownUIN {
            ScrollView {
                VStack(spacing: 18) {
                    Spacer().frame(height: 12)
                    if let qr = QRCode.image(from: addPayload(for: uin)) {
                        // 44pt badge over 240pt code = ~3.3%, well under
                        // the ~15% level-M error-correction tolerance.
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                            .padding(14)
                            .background(Color.white)
                            .cornerRadius(10)
                            // Your FACE in the middle, not your presence. This
                            // code exists to be held up to a stranger, and the
                            // one thing worth putting in the middle of it is
                            // the person doing the holding — a flower says
                            // "online", which the person standing in front of
                            // you can already see.
                            //
                            // PersonAvatarView rather than an image: with no
                            // picture set it draws exactly the flower that was
                            // here before, so nobody's code changes until they
                            // give it a face to show.
                            .overlay(
                                PersonAvatarView(
                                    mediaID: presence.ownAvatarID,
                                    keyBase64: presence.ownAvatarKey,
                                    status: presence.status,
                                    size: 44
                                )
                            )
                    }
                    VStack(spacing: 2) {
                        Text(auth.nickname.isEmpty ? "—" : auth.nickname)
                            .font(.title2.bold())
                            .foregroundColor(Theme.Color.textPrimary)
                        Text(verbatim: "\(uin)")
                            .font(.title3.monospaced())
                            .foregroundColor(Theme.Color.textMono)
                    }
                    Text("qr.body.your_code".localized)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    HStack(spacing: 10) {
                        Button {
                            UIPasteboard.general.string = addPayload(for: uin)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } label: {
                            Label("qr.button.copy_link".localized, systemImage: "link")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Theme.Color.bgSecondary)
                                .foregroundColor(Theme.Color.textPrimary)
                                .cornerRadius(6)
                        }
                        Button { swap(to: .scan) } label: {
                            Label("qr.button.scan_code".localized, systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Theme.Color.accent)
                                .foregroundColor(.white)
                                .cornerRadius(6)
                        }
                    }
                    .padding(.horizontal, 16)
                    Spacer().frame(height: 24)
                }
                // Hands the column's natural height to `codeDetent`.
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: CodeColumnHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                )
            }
            .onPreferenceChange(CodeColumnHeightKey.self) { codeHeight = $0 }
        } else {
            ProgressView().tint(Theme.Color.accent)
        }
    }

    // MARK: - scan

    private var scanPane: some View {
        VStack(spacing: 0) {
            // Just the instruction. The `rcq://add/{uin}` line under it told
            // the person nothing they could act on and read like debug output
            // left on the screen.
            Text("qr.scan.aim".localized)
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.black.opacity(0.55))
                .cornerRadius(6)
                .padding(.top, 14)
            Spacer(minLength: 0)
            // The way back, in the same corner of the sheet the "scan a code"
            // button occupies on the other side.
            Button { swap(to: .myCode) } label: {
                Label("qr.tab.my_code".localized, systemImage: "qrcode")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
            }
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Camera as a BACKGROUND, edge to edge on all four sides including
        // UNDER the nav bar: the bar is made transparent for this pane (see
        // `body`), so its title and Close button float over the picture
        // instead of standing on a slab that eats the top of the sheet. The
        // controls in the VStack above stay inside the safe area.
        .background(
            QRScannerView { code in
                Task { await handleScan(code) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        )
    }

    /// Our own add-code payload (spec §5). Carries the island host for a
    /// self-hoster so others can add us cross-island by scanning, plus the
    /// advisory `k=` signing key (base64url; consumers still fetch the card).
    /// A flagship account with no key degrades to the legacy bare form old
    /// scanners already parse.
    private func addPayload(for uin: Int) -> String {
        let host = Multihome.ownHost()
        var params: [String] = []
        if host != RcqFederation.flagshipHost { params.append("h=\(host)") }
        if let sk = (MessageService.shared.crypto as? SignalCryptoService)?.signingPubB64 {
            let urlSafe = sk
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            params.append("k=\(urlSafe)")
        }
        // ⚠ The guest card, after the hash, and ONLY on a closed island. A
        // fragment is never sent to a server, which is the whole reason the
        // credential can ride in a code at all. On an open island there is no
        // card to put here — minting one would push a live credential into
        // every code anybody has ever held up to a camera, for a door that is
        // not locked.
        let frag = (OutgoingGuestCard.value?.isEmpty == false)
            ? "#c=" + (OutgoingGuestCard.value!.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? OutgoingGuestCard.value!)
            : ""
        return "rcq://add/\(uin)" + (params.isEmpty ? "" : "?" + params.joined(separator: "&")) + frag
    }

    private func handleScan(_ raw: String) async {
        guard let url = URL(string: raw),
              let scanned = Self.parseAddURL(url) else {
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                scanResult = .failed(message: "qr.alert.invalid_code".localized)
            }
            return
        }
        let uin = scanned.uin
        // ⚠ Kept the MOMENT the code is read, before any decision about adding
        // them. It is what the next request about this person needs, and
        // somebody who backs out and adds them an hour later would otherwise
        // have thrown away the only way to reach them on a closed island.
        if let card = scanned.card, uin != auth.ownUIN {
            await MainActor.run {
                GuestCardStore.shared.remember(uin: uin, host: scanned.host, card: card)
            }
        }
        if uin == auth.ownUIN {
            await MainActor.run {
                scanResult = .failed(message: "qr.alert.own_code".localized)
            }
            return
        }
        if ContactService.shared.contacts.contains(where: { $0.uin == uin }) {
            await MainActor.run {
                scanResult = .alreadyContact(uin: uin)
            }
            return
        }
        // Resolve the peer's island: an explicit `?h=`, else the flagship (a
        // bare code means flagship by convention). If that island isn't OURS,
        // add as a cross-island contact directly (no add-request; the peer's
        // keys come from their island's open card). This is what lets a
        // self-hoster on is2 scan a flagship user's bare QR and reach them.
        let host = scanned.host ?? RcqFederation.flagshipHost
        if !Multihome.isOwnHost(host) {
            // §5f: this deposits `act:"request"` to their island as well as
            // writing the local row, so the scan finally puts something on the
            // other person's screen. Report the two outcomes separately —
            // "request sent" is only true when the deposit was taken.
            let r = await ContactService.shared.addCrossIslandContact(
                uin: uin, host: host, announce: .request
            )
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(r.added ? .success : .error)
                if r.added && r.announced {
                    scanResult = .crossIslandSent(uin: uin, host: host)
                } else if r.added {
                    scanResult = .addedLocally(uin: uin, host: host)
                } else {
                    scanResult = .failed(message: "qr.alert.failed.title".localized)
                }
            }
            // ⚠ A closed island answers a stranger with the SAME "no such
            // number" it gives for a number that never existed, deliberately,
            // so it cannot tell the truth and this is the only place that can.
            // Asked only after the add failed, so the ordinary path costs
            // nothing.
            let alreadyAdded = await MainActor.run {
                ContactService.shared.contacts.contains { $0.uin == uin }
            }
            if !alreadyAdded,
               let info = await ServerInfoService.fetch(host: host),
               info.capabilities.closedIsland {
                await MainActor.run {
                    scanResult = .failed(message: "ci.closed_island".localized)
                }
            }
            return
        }
        do {
            try await ContactService.shared.sendAddRequest(to: uin)
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                scanResult = .sent(uin: uin)
            }
        } catch {
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                scanResult = .failed(message: error.localizedDescription)
            }
        }
    }

    /// A scanned add-code: the UIN plus an optional island host. Handles our own
    /// `rcq://add/{uin}[?h=host]` and the web universal link
    /// `https://rcq.app/u/{uin}?h=host` so iOS can scan codes from any client.
    /// `card` is a GUEST CARD the sharer put in the link's FRAGMENT, on a
    /// closed island: what lets us reach them at all. See `GuestCardStore`.
    struct ScannedAddress { let uin: Int; let host: String?; var card: String? = nil }

    static func parseAddURL(_ url: URL) -> ScannedAddress? {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let hostRaw = comps?.queryItems?.first(where: { $0.name == "h" })?.value?
            .trimmingCharacters(in: .whitespaces)
        let host = (hostRaw?.isEmpty ?? true) ? nil : hostRaw
        // ⚠⚠ THE CARD COMES OUT OF THE FRAGMENT, and it is there rather than in
        // the query on purpose: a fragment is never sent to a server, so a link
        // can be pasted anywhere without rcq.app, its CDN or a middlebox ever
        // seeing a live credential. Parsed by hand because `queryItems` cannot
        // reach it, and bounded because it arrives from a scanned code and
        // leaves as a request header.
        let card: String? = comps?.fragment?
            .split(separator: "&")
            .first(where: { $0.hasPrefix("c=") })
            .map { String($0.dropFirst(2)) }
            .flatMap { $0.removingPercentEncoding ?? $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty || $0.count > 128 ? nil : $0 }
        // rcq://add/{uin}[?h=host]
        if url.scheme == "rcq", url.host == "add" {
            let seg = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let uin = Int(seg) else { return nil }
            return ScannedAddress(uin: uin, host: host, card: card)
        }
        // https://rcq.app/u/{uin}?h=host
        if let scheme = url.scheme, scheme.hasPrefix("http"),
           let h = url.host, h == "rcq.app" || h == "www.rcq.app" {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count == 2, parts[0] == "u", let uin = Int(parts[1]) {
                return ScannedAddress(uin: uin, host: host, card: card)
            }
        }
        return nil
    }

    // MARK: - alert plumbing

    private var alertTitle: String {
        switch scanResult {
        case .sent:           return "qr.alert.sent.title".localized
        case .crossIslandSent: return "qr.alert.ci_sent.title".localized
        case .addedLocally:   return "qr.alert.added.title".localized
        case .alreadyContact: return "qr.alert.already.title".localized
        case .failed:         return "qr.alert.failed.title".localized
        case .none:           return ""
        }
    }

    private func alertMessage(for result: ScanResult) -> String {
        switch result {
        case .sent(let uin):
            return String(format: "qr.alert.sent.body".localized, uin)
        case .crossIslandSent(let uin, let host):
            return String(format: "qr.alert.ci_sent.body".localized, uin, host)
        case .addedLocally(let uin, let host):
            return String(format: "qr.alert.added.body".localized, uin, host)
        case .alreadyContact(let uin):
            return String(format: "qr.alert.already.body".localized, uin)
        case .failed(let msg):
            return msg
        }
    }
}

/// Carries the my-code column's natural height up so the sheet can end where
/// the content ends instead of standing at full height.
private struct CodeColumnHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - AVFoundation scanner

/// AVCaptureSession wrapper that fires `onScan` once on the first
/// QR detection and stops the session.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onScan = onScan
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}

    /// The preview layer IS this view's layer rather than a sublayer of it.
    ///
    /// ⚠ A sublayer has to be resized by hand on every layout pass, and CALayer
    /// does not inherit autoresizing from its host: the layer kept whatever
    /// frame it was given when the session was configured. The sheet grows from
    /// the code detent to `.large` the moment the camera comes up, so the
    /// picture was left as a band across the top with black under it. As the
    /// view's own layer it cannot disagree with the bounds at all.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            // Safe by construction: `layerClass` above is what UIKit builds.
            layer as! AVCaptureVideoPreviewLayer  // swiftlint:disable:this force_cast
        }
    }

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        private var didScan = false
        var onScan: ((String) -> Void)?
        private let session = AVCaptureSession()

        override func loadView() {
            view = PreviewView()
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configureSession()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.session.startRunning()
                }
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning {
                session.stopRunning()
            }
        }

        private func configureSession() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            guard let host = view as? PreviewView else { return }
            host.previewLayer.session = session
            host.previewLayer.videoGravity = .resizeAspectFill
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            // One code, one callback. `stopRunning()` does not un-queue the
            // frames already sitting on the main queue, so a single scan used
            // to deliver two or three times — which sent TWO contact requests
            // for one scan on the add path, and raised the web-link confirm
            // sheet repeatedly (each with a fresh identity) on the other.
            guard !didScan,
                  let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = metadata.stringValue else { return }
            didScan = true
            session.stopRunning()
            onScan?(value)
        }
    }
}
