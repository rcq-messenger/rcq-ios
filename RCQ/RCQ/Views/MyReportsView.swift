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
/// Since 16.08 it is a conversation and not a box with a lid: an operator asks
/// "which version?", and the answer belongs on the same ticket. Before that the
/// only way to say anything back was to file a SECOND report, which is why the
/// queue held the same issue three times over from one person.
///
/// Android parity: `ui/MyReportsScreen.kt`, shipped in v0.77.
struct MyReportsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var reports: [MyReport]?
    @State private var loading = true
    /// Which ticket has its box open, and what is typed in it. One at a time:
    /// this is a list of tickets, not a chat list.
    @State private var replyTo: Int?
    @State private var draft = ""
    @State private var sending = false
    @State private var sendError: String?
    @FocusState private var composerFocused: Bool

    /// One turn in a report's conversation. `from_admin` is the only side the
    /// reader needs: there is exactly one person on each end.
    struct ReportTurn: Decodable, Identifiable {
        let id: Int
        let from_admin: Bool
        let body: String?
        let created_at: String?
    }

    struct MyReport: Decodable, Identifiable {
        let id: Int
        let reason: String?
        let status: String?
        let created_at: String?
        /// The LAST operator answer. An island older than the thread sends only
        /// this, which is why the screen still falls back to it.
        let reply: String?
        let replied_at: String?
        /// The whole exchange, oldest first. Absent on an island that predates
        /// tickets, and empty on a report nobody answered or added to.
        var thread: [ReportTurn]?
    }

    private struct TurnBody: Encodable { let body: String }

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
            // A card that says "Waiting" in green with the operator's answer
            // printed right underneath reads as "we are being ignored" — the
            // exact complaint in #417. The reply IS the status change; the
            // server's own `status` only moves when an admin resolves the
            // ticket, which is a different thing.
            let turns = report.thread ?? []
            let answered = !(report.reply ?? "").isEmpty || turns.contains { $0.from_admin }
            HStack {
                Text(answered && (report.status ?? "open") == "open"
                     ? "myreports.status.answered".localized
                     : statusLabel(report.status))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(report.status == "open" && !answered
                                     ? Theme.Color.accent : Theme.Color.textSecondary)
                Spacer()
                if let when = formatted(report.created_at) {
                    Text(when).font(.caption2).foregroundColor(Theme.Color.textSecondary)
                }
            }

            if let reason = report.reason, !reason.isEmpty {
                Text(reason).font(.subheadline).foregroundColor(Theme.Color.textPrimary)
            }

            // The exchange, oldest first. `thread` is what a current island
            // sends; an older one sends only the single `reply`, and that is the
            // fallback below — the screen must not go blank against an island
            // that has not updated. The answer is the whole reason this screen
            // exists, so it gets its own block rather than a line of small print.
            if !turns.isEmpty {
                ForEach(turns) { turn in
                    turnBlock(
                        label: turn.from_admin ? "myreports.answer".localized : "myreports.you".localized,
                        labelColor: turn.from_admin ? Theme.Color.accent : Theme.Color.textSecondary,
                        body: turn.body ?? "",
                        fromAdmin: turn.from_admin
                    )
                }
            } else if let reply = report.reply, !reply.isEmpty {
                turnBlock(
                    label: "myreports.answer".localized,
                    labelColor: Theme.Color.accent,
                    body: reply,
                    fromAdmin: true
                )
            }

            // Writing back only makes sense while the ticket is open. A closed
            // one keeps its whole exchange readable.
            if (report.status ?? "open") == "open" {
                if replyTo == report.id {
                    composer(for: report)
                } else {
                    cardButton("myreports.reply".localized, filled: false) {
                        replyTo = report.id
                        draft = ""
                        sendError = nil
                        composerFocused = true
                    }
                }
            }

            // A closed ticket is not a failure, it is an answer, so it says so
            // here rather than as a generic "could not send".
            if let sendError, replyTo == report.id {
                Text(sendError)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.statusBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// One turn of the exchange. The operator's side sits on the screen
    /// background and the reporter's on a wash of the text colour, so the two
    /// read apart at a glance without either growing a border.
    private func turnBlock(label: String, labelColor: Color, body: String, fromAdmin: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(labelColor)
            Text(body).font(.footnote).foregroundColor(Theme.Color.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(fromAdmin ? Theme.Color.bgPrimary : Theme.Color.textPrimary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func composer(for report: MyReport) -> some View {
        VStack(spacing: 8) {
            // A height floor so the box looks like the answer it wants, and a
            // ceiling so it cannot push the buttons off the card.
            TextEditor(text: $draft)
                .focused($composerFocused)
                .font(.footnote)
                .foregroundColor(Theme.Color.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72, maxHeight: 160)
                .padding(8)
                .background(Theme.Color.textPrimary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("myreports.reply.placeholder".localized)
                            .font(.footnote)
                            .foregroundColor(Theme.Color.textSecondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(sending)

            HStack(spacing: 8) {
                cardButton("common.cancel".localized, filled: false) {
                    replyTo = nil
                    draft = ""
                    sendError = nil
                }
                cardButton(
                    "myreports.reply.send".localized,
                    filled: true,
                    enabled: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
                ) {
                    Task { await send(to: report.id) }
                }
            }
        }
    }

    /// A button sized for the inside of a card: the app's primary capsule is a
    /// full-width action and swallows a ticket card whole.
    private func cardButton(
        _ label: String,
        filled: Bool,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundColor(filled && enabled ? .white : (enabled ? Theme.Color.accent : Theme.Color.textSecondary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(filled && enabled ? Theme.Color.accent : Theme.Color.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Add a turn and put it straight into the list, so the answer appears where
    /// it was typed instead of after a refresh nobody triggers.
    private func send(to reportID: Int) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        sendError = nil
        defer { sending = false }
        do {
            let turn: ReportTurn = try await APIClient.shared.request(
                "POST", "/reports/mine/\(reportID)/messages", body: TurnBody(body: text)
            )
            if let index = reports?.firstIndex(where: { $0.id == reportID }) {
                reports?[index].thread = (reports?[index].thread ?? []) + [turn]
            }
            draft = ""
            replyTo = nil
        } catch APIError.http(409, _) {
            sendError = "myreports.closed".localized
        } catch {
            sendError = "myreports.send_error".localized
        }
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
