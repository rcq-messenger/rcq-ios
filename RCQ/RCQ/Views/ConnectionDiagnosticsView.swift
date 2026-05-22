import Foundation
import SwiftUI

struct ConnectionDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct DiagLine: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let ok: Bool
    }

    @State private var lines: [DiagLine] = []
    @State private var running = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: line.ok
                                      ? "checkmark.circle.fill"
                                      : "xmark.octagon.fill")
                                    .foregroundColor(line.ok ? .green : .red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.label)
                                        .font(.callout.weight(.semibold))
                                        .foregroundColor(Theme.Color.textPrimary)
                                    Text(line.value)
                                        .font(.caption.monospaced())
                                        .foregroundColor(Theme.Color.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        if running {
                            ProgressView().padding(.top, 4)
                        }
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

    @MainActor
    private func run() async {
        running = true
        var out: [DiagLine] = []

        let port = UserDefaults.standard.integer(forKey: "rcq.singbox.activePort")
        out.append(DiagLine(
            label: "Transport",
            value: "enabled=\(SingBoxTransport.isEnabled)  active=\(SingBoxTransport.shared.isActive)  port=\(port)",
            ok: true
        ))
        out.append(DiagLine(
            label: "App state",
            value: "offline=\(AppState.shared.isOffline)  ws=\(WebSocketService.shared.isConnected)",
            ok: true
        ))
        lines = out

        let probes: [(String, String, Bool)] = [
            ("GET /health", "/health", false),
            ("GET /contacts", "/contacts", true),
            ("GET /groups", "/groups", true),
        ]
        for (label, path, authed) in probes {
            let started = Date()
            do {
                let data = try await APIClient.shared.rawRequest(
                    "GET", path, authenticated: authed
                )
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let count = ((try? JSONSerialization.jsonObject(with: data)) as? [Any])?.count
                let detail = count.map { "\($0) items, " } ?? ""
                out.append(DiagLine(
                    label: label,
                    value: "OK — \(detail)\(data.count) bytes, \(ms)ms",
                    ok: true
                ))
            } catch {
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                out.append(DiagLine(
                    label: label,
                    value: "FAIL (\(ms)ms) — \(error.localizedDescription)",
                    ok: false
                ))
            }
            lines = out
        }
        running = false
    }
}
