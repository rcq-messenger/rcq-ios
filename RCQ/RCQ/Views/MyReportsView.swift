import SwiftUI

/// The reports this account has filed, and whatever was written back.
///
/// Filing a report used to be shouting into a well: the queue is admin-side and
/// nothing came back, so a person who spent an hour writing careful feedback
/// could not tell whether anyone had read it. The answer cannot arrive as a chat
/// message either — chats are sealed on the sending device and the server holds
/// no keys, so a server-written "message" is exactly the capability this project
/// promises it lacks. It is fetched here on our own authenticated session
/// (`GET /reports/mine`) and rendered as what it is: a note from the operators.
///
/// Android parity: `ui/MyReportsScreen.kt`, shipped in v0.77.
struct MyReportsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var reports: [MyReport]?
    @State private var loading = true

    struct MyReport: Decodable, Identifiable {
        let id: Int
        let reason: String?
        let status: String?
        let created_at: String?
        let reply: String?
        let replied_at: String?
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                content
            }
            .navigationTitle("myreports.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.done".localized) { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().tint(Theme.Color.accent)
        } else if (reports ?? []).isEmpty {
            Text("myreports.empty".localized)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(Theme.Color.textSecondary)
                .padding(32)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(reports ?? []) { card($0) }
                }
                .padding(16)
            }
        }
    }

    private func card(_ report: MyReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(statusLabel(report.status))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(report.status == "open" ? Theme.Color.accent : Theme.Color.textSecondary)
                Spacer()
                if let when = formatted(report.created_at) {
                    Text(when).font(.caption2).foregroundColor(Theme.Color.textSecondary)
                }
            }

            if let reason = report.reason, !reason.isEmpty {
                Text(reason).font(.subheadline).foregroundColor(Theme.Color.textPrimary)
            }

            // The answer is the whole reason this screen exists, so it gets its
            // own block rather than a line of small print under the report.
            if let reply = report.reply, !reply.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("myreports.answer".localized)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                    Text(reply).font(.footnote).foregroundColor(Theme.Color.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.Color.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func statusLabel(_ status: String?) -> String {
        switch status {
        case "resolved": return "myreports.status.resolved".localized
        case "dismissed": return "myreports.status.dismissed".localized
        case "duplicate": return "myreports.status.duplicate".localized
        default: return "myreports.status.open".localized
        }
    }

    /// Server timestamps are ISO-8601, with or without fractional seconds. A
    /// failure to parse drops the date rather than showing a raw string.
    private func formatted(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = withFrac.date(from: iso) ?? plain.date(from: iso) else { return nil }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: date)
    }

    private func load() async {
        defer { loading = false }
        reports = try? await APIClient.shared.request("GET", "/reports/mine") as [MyReport]
    }
}
