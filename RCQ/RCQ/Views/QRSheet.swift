import AVFoundation
import SwiftUI
import UIKit

/// QR surface for adding contacts. My-code tab renders a QR for
/// `rcq://add/{ownUIN}`; Scan tab opens the camera and routes a
/// detected `rcq://add/{uin}` to a contact-add request.
struct QRSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var auth = AuthService.shared
    @StateObject private var presence = PresenceService.shared
    @State private var mode: Mode = .myCode
    @State private var scanResult: ScanResult?

    enum Mode: Hashable { case myCode, scan }

    enum ScanResult: Equatable {
        case sent(uin: Int)
        case alreadyContact(uin: Int)
        case failed(message: String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                VStack(spacing: 0) {
                    Picker("", selection: $mode) {
                        Text("qr.tab.my_code".localized).tag(Mode.myCode)
                        Text("qr.tab.scan".localized).tag(Mode.scan)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16).padding(.vertical, 10)

                    Group {
                        switch mode {
                        case .myCode: myCodePane
                        case .scan:   scanPane
                        }
                    }
                }
            }
            .navigationTitle("qr.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
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
                    if case .alreadyContact = result { dismiss() }
                }
            } message: { result in
                Text(alertMessage(for: result))
            }
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
                            .overlay(
                                StatusIcon(status: presence.status, size: 44)
                            )
                    }
                    VStack(spacing: 2) {
                        Text(auth.nickname.isEmpty ? "—" : auth.nickname)
                            .font(.title2.bold())
                            .foregroundColor(Theme.Color.textPrimary)
                        Text(verbatim: "#\(uin)")
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
                        Button { mode = .scan } label: {
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
            }
        } else {
            ProgressView().tint(Theme.Color.accent)
        }
    }

    // MARK: - scan

    @ViewBuilder
    private var scanPane: some View {
        QRScannerView { code in
            Task { await handleScan(code) }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                Text("qr.scan.aim".localized)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                Text("rcq://add/{uin}")
                    .font(.caption2.monospaced())
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.black.opacity(0.55))
            .cornerRadius(6)
            .padding(.top, 14)
        }
        // Camera fills to the sheet edges (default sheet safe-area
        // would leave a visible bg strip under the preview).
        .ignoresSafeArea(.container, edges: [.bottom, .horizontal])
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
        return "rcq://add/\(uin)" + (params.isEmpty ? "" : "?" + params.joined(separator: "&"))
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
            let ok = await ContactService.shared.addCrossIslandContact(uin: uin, host: host)
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
                scanResult = ok ? .sent(uin: uin) : .failed(message: "qr.alert.failed.title".localized)
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
    struct ScannedAddress { let uin: Int; let host: String? }

    static func parseAddURL(_ url: URL) -> ScannedAddress? {
        let hostRaw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "h" })?.value?
            .trimmingCharacters(in: .whitespaces)
        let host = (hostRaw?.isEmpty ?? true) ? nil : hostRaw
        // rcq://add/{uin}[?h=host]
        if url.scheme == "rcq", url.host == "add" {
            let seg = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let uin = Int(seg) else { return nil }
            return ScannedAddress(uin: uin, host: host)
        }
        // https://rcq.app/u/{uin}?h=host
        if let scheme = url.scheme, scheme.hasPrefix("http"),
           let h = url.host, h == "rcq.app" || h == "www.rcq.app" {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count == 2, parts[0] == "u", let uin = Int(parts[1]) {
                return ScannedAddress(uin: uin, host: host)
            }
        }
        return nil
    }

    // MARK: - alert plumbing

    private var alertTitle: String {
        switch scanResult {
        case .sent:           return "qr.alert.sent.title".localized
        case .alreadyContact: return "qr.alert.already.title".localized
        case .failed:         return "qr.alert.failed.title".localized
        case .none:           return ""
        }
    }

    private func alertMessage(for result: ScanResult) -> String {
        switch result {
        case .sent(let uin):
            return String(format: "qr.alert.sent.body".localized, uin)
        case .alreadyContact(let uin):
            return String(format: "qr.alert.already.body".localized, uin)
        case .failed(let msg):
            return msg
        }
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

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configureSession()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
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

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.addSublayer(preview)
            self.preview = preview
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = metadata.stringValue else { return }
            session.stopRunning()
            onScan?(value)
        }
    }
}
