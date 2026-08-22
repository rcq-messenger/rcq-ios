import Foundation
import SwiftUI
import UIKit

/// Friendly connection diagnostics. Plain-language checks with a clear overall
/// verdict, green/red/neutral tints, and a Run button to re-test. Mirrors the
/// Android "Connection diagnostics" screen — no raw `enabled=X port=Z` dumps,
/// every line says what it means for the user.
struct ConnectionDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss

    private enum Status { case ok, fail, info }

    private struct DiagLine: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let status: Status
    }

    @State private var lines: [DiagLine] = []
    @State private var running = false
    @State private var overallOK: Bool? = nil
    @State private var audit: NetworkAudit.Report?
    @State private var auditing = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        ForEach(lines) { row($0) }
                        // Two of the lines above are named "RCQ relays" and
                        // "Relay list", so this screen owes the reader the word.
                        if !lines.isEmpty { RelayFAQLink() }
                        if running {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("diag.checking".localized)
                                    .font(.caption)
                                    .foregroundColor(Theme.Color.textSecondary)
                            }
                            .padding(.top, 2)
                        }
                        auditSection
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("diag.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("diag.run".localized) { Task { await run() } }
                        .disabled(running)
                }
            }
            .task { await run() }
        }
    }

    // MARK: - Full network check

    /// Separate button because it opens raw connections to a couple of
    /// third-party control hosts, which must never happen without the user
    /// asking for it.
    @ViewBuilder private var auditSection: some View {
        // ⚠⚠ Never under duress. This one does not go through `APIClient`, so
        // `DuressGate` cannot stop it: it opens raw connections to this island,
        // the front, the relays and two third-party control hosts. One tap from
        // a coerced phone would put the real island's name on the wire from a
        // session whose whole claim is that it is somebody else's. Hidden
        // rather than disabled — a dead button invites a second tap.
        if !PanicPINService.shared.isDecoy {
        Divider().padding(.vertical, 6)
        Text("audit.hint".localized)
            .font(.caption)
            .foregroundColor(Theme.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        Button {
            Task {
                auditing = true
                audit = nil
                audit = await NetworkAudit.run(islandHost: APIClient.shared.baseURL.host ?? "api.rcq.app")
                auditing = false
            }
        } label: {
            HStack(spacing: 8) {
                if auditing { ProgressView() }
                Text("audit.run".localized).font(.callout.weight(.semibold))
            }
        }
        .disabled(auditing)
        if let a = audit {
            ForEach(a.lines) { l in
                row(DiagLine(title: l.title, detail: l.detail, status: l.ok == nil ? .info : (l.ok! ? .ok : .fail)))
            }
            Text("audit.verdict.\(a.verdict.rawValue)".localized)
                .font(.callout)
                .foregroundColor(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(a.compact)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(Theme.Color.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(copied ? "audit.copied".localized : "audit.copy".localized) {
                    UIPasteboard.general.string = a.compact
                    copied = true
                }
                ShareLink(item: a.compact) { Text("common.share".localized) }
            }
            .font(.callout)
        }
        }
    }

    // MARK: - Header verdict

    @ViewBuilder private var header: some View {
        let (glyph, tint, text): (String, Color, String) = {
            switch overallOK {
            case .some(true):  return ("checkmark.seal.fill", .green, "diag.verdict.ok".localized)
            case .some(false): return ("exclamationmark.triangle.fill", .orange, "diag.verdict.problems".localized)
            case .none:        return ("antenna.radiowaves.left.and.right", Theme.Color.accent, "diag.verdict.checking".localized)
            }
        }()
        HStack(spacing: 12) {
            Image(systemName: glyph)
                .font(.system(size: 26))
                .foregroundColor(tint)
            Text(text)
                .font(.callout.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Row

    private func row(_ line: DiagLine) -> some View {
        let (glyph, tint): (String, Color) = {
            switch line.status {
            case .ok:   return ("checkmark.circle.fill", .green)
            case .fail: return ("xmark.octagon.fill", .red)
            case .info: return ("info.circle.fill", Theme.Color.textSecondary)
            }
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: glyph).foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text(line.detail)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Probes

    @MainActor
    private func run() async {
        running = true
        overallOK = nil
        var out: [DiagLine] = []
        func push(_ l: DiagLine) { out.append(l); lines = out }

        // Route: direct vs through the RCQ relays.
        let onRelay = SingBoxTransport.shared.isActive
        push(DiagLine(
            title: "diag.route.title".localized,
            detail: (onRelay ? "diag.route.relay" : "diag.route.direct").localized,
            status: .info
        ))

        // Surface a transport start failure if the relays tried and failed.
        if let err = SingBoxTransport.lastStartError {
            push(DiagLine(
                title: "diag.transport.title".localized,
                detail: "diag.transport.failed".localized(err),
                status: .fail
            ))
        }

        // ⚠⚠ A duress session answers this screen from what it already claims
        // and asks the network nothing. The two probes below go through
        // `APIClient`, so `DuressGate` refuses them — no traffic leaves, which
        // is the important half — but they would then paint two red FAILED
        // lines directly under a header whose dot is green. "Connected" over
        // "server unreachable" on one screen is a contradiction a coercer reads
        // for free, and the decoy's whole job is to hold one story.
        if PanicPINService.shared.isDecoy {
            push(DiagLine(
                title: "diag.server.title".localized,
                detail: "diag.server.ok".localized(42),
                status: .ok
            ))
            push(DiagLine(
                title: "diag.ws.title".localized,
                detail: "diag.ws.connected".localized,
                status: .ok
            ))
            overallOK = true
            running = false
            return
        }

        // Server reachable: unauthenticated /health.
        await probe(
            title: "diag.server.title".localized,
            path: "/health",
            authed: false,
            okText: { ms, _ in "diag.server.ok".localized(ms) },
            failText: { "diag.server.fail".localized },
            push: push
        )

        // Account: authenticated /contacts (proves the token works end to end).
        await probe(
            title: "diag.account.title".localized,
            path: "/contacts",
            authed: true,
            okText: { ms, count in
                count.map { "diag.account.ok".localized($0, ms) }
                    ?? "diag.account.ok_unknown".localized(ms)
            },
            failText: { "diag.account.fail".localized },
            push: push
        )

        // Real-time channel: the live WebSocket.
        let ws = WebSocketService.shared.isConnected
        let offline = AppState.shared.isOffline
        push(DiagLine(
            title: "diag.ws.title".localized,
            detail: ws
                ? "diag.ws.connected".localized
                : (offline ? "diag.ws.offline".localized : "diag.ws.disconnected".localized),
            status: ws ? .ok : .fail
        ))

        // Relays available in the list (informational).
        let relayCount = RelayConfigStore.shared.currentRelays().count
        push(DiagLine(
            title: "diag.relays.title".localized,
            detail: relayCount > 0
                ? "diag.relays.count".localized(relayCount)
                : "diag.relays.builtin".localized,
            status: .info
        ))

        overallOK = !out.contains { $0.status == .fail }
        running = false
    }

    /// One reachability probe. `okText(ms, itemCount)` / `failText()` build the
    /// human-readable detail. itemCount is the JSON array length when the body
    /// is an array (contacts/groups), else nil.
    @MainActor
    private func probe(
        title: String,
        path: String,
        authed: Bool,
        okText: (Int, Int?) -> String,
        failText: () -> String,
        push: (DiagLine) -> Void
    ) async {
        let started = Date()
        do {
            let data = try await APIClient.shared.rawRequest("GET", path, authenticated: authed)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let count = ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.count
            push(DiagLine(title: title, detail: okText(ms, count), status: .ok))
        } catch {
            push(DiagLine(title: title, detail: failText(), status: .fail))
        }
    }
}
