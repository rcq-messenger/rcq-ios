import SwiftUI
import UIKit

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
/// Founder item 26 added the row of icon actions the other clients carry:
///   * copy, for the report AND for the answer. People quote their own wording
///     when they follow up, and re-typing it off a screen is the kind of small
///     tax that stops somebody bothering;
///   * edit (`PATCH /reports/mine/{id}`), while nobody has answered yet. The
///     typo is noticed one second after sending, and the only fix used to be a
///     second report saying "sorry, I meant", which is how the queue collected
///     the same issue three times;
///   * remove from my list (`DELETE /reports/mine/{id}`), which is a HIDE and
///     not a delete. The row stays on the island and still counts on the Hall
///     of Fame, so the copy never promises otherwise: deleting the reports that
///     came back `dismissed` would be a scoreboard exploit, and the server
///     closed it by keeping the row.
///
/// The number on each row is `reports.id`, the same integer the operator quotes
/// when he answers. An island older than 23.08 does not send `number`, and the
/// id IS that number, which is what the fallback below leans on.
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
    /// Which report is being rewritten, and the text as typed. Mutually
    /// exclusive with the reply box: two editors open on one card is two ways
    /// to send the same words.
    @State private var editing: Int?
    @State private var editDraft = ""
    @State private var savingEdit = false
    /// Kept apart from `sendError` on purpose: that one belongs to the reply
    /// box and is cleared when the box closes, while an edit or a removal can
    /// fail with the box shut.
    @State private var actionError: CardError?
    @State private var removeTarget: Int?
    /// Which copy button last fired, so its icon can say so for a moment. The
    /// app has no toast, and a copy that looks like nothing happened gets
    /// pressed again.
    @State private var copiedKey: String?
    @FocusState private var composerFocused: Bool
    @FocusState private var editorFocused: Bool

    /// Matches the backend's `MAX_REASON_LEN`. The platform tag counts against
    /// it too, so the editor's own ceiling is this minus the tag.
    private static let maxReasonLength = 1000

    /// An error that belongs to one card rather than to the screen.
    private struct CardError: Equatable {
        let reportID: Int
        let text: String
    }

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
        /// The number the operator quotes back. Absent on an island older than
        /// the field, where the row id is that same integer anyway.
        let number: Int?
        var reason: String?
        let status: String?
        let created_at: String?
        /// The LAST operator answer. An island older than the thread sends only
        /// this, which is why the screen still falls back to it.
        let reply: String?
        let replied_at: String?
        /// The whole exchange, oldest first. Absent on an island that predates
        /// tickets, and empty on a report nobody answered or added to.
        var thread: [ReportTurn]?

        /// What to print on the row. See the type comment on `number`.
        var displayNumber: Int { number ?? id }
    }

    private struct TurnBody: Encodable { let body: String }
    private struct EditBody: Encodable { let reason: String }

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
            .confirmationDialog(
                removeTitle,
                isPresented: Binding(
                    get: { removeTarget != nil },
                    set: { if !$0 { removeTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("myreports.remove.cta".localized, role: .destructive) {
                    if let target = removeTarget {
                        removeTarget = nil
                        Task { await remove(target) }
                    }
                }
                Button("common.cancel".localized, role: .cancel) { removeTarget = nil }
            } message: {
                Text("myreports.remove.confirm.body".localized)
            }
        }
        .task { await load() }
    }

    private var removeTitle: String {
        guard let target = removeTarget,
              let report = reports?.first(where: { $0.id == target }) else { return "" }
        return String(
            format: "myreports.remove.confirm.title".localized,
            String(format: "myreports.number.short".localized, report.displayNumber)
        )
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
            let tagged = Self.splitTag(report.reason ?? "")
            // Rewriting is for a report nobody has read out yet. Once an
            // operator has answered, changing the words underneath the answer
            // would make the exchange read as a non-sequitur for both sides, so
            // from then on the way to add something is "Write back".
            //
            // A crash report is refused by the server as well (the [CRASH]
            // marker is what keeps auto-submitted crashes out of a
            // contributor's tally, so it must not be editable by hand), and an
            // icon that always fails is worse than no icon.
            let editable = (report.status ?? "open") == "open"
                && !answered
                && !(report.reason ?? "").contains(Self.crashMarker)

            header(report, answered: answered, editable: editable, reason: tagged.body)

            if editing == report.id {
                editor(for: report, tag: tagged.tag)
            } else if !tagged.body.isEmpty {
                Text(tagged.body).font(.subheadline).foregroundColor(Theme.Color.textPrimary)
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
                        fromAdmin: turn.from_admin,
                        copyKey: turn.from_admin ? "turn-\(turn.id)" : nil
                    )
                }
            } else if let reply = report.reply, !reply.isEmpty {
                turnBlock(
                    label: "myreports.answer".localized,
                    labelColor: Theme.Color.accent,
                    body: reply,
                    fromAdmin: true,
                    copyKey: "reply-\(report.id)"
                )
            }

            // Writing back only makes sense while the ticket is open. A closed
            // one keeps its whole exchange readable. Hidden while the report
            // itself is being rewritten: one box at a time.
            if (report.status ?? "open") == "open", editing != report.id {
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
            if let actionError, actionError.reportID == report.id {
                Text(actionError.text)
                    .font(.caption2)
                    .foregroundColor(Theme.Color.statusBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Status and the number on the left, the actions on the right. The number
    /// and the date share a line under the status rather than sitting beside
    /// three icons: on a narrow phone that single row runs off the card, and
    /// the number is the half a person needs to read back.
    private func header(_ report: MyReport, answered: Bool, editable: Bool, reason: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(answered && (report.status ?? "open") == "open"
                     ? "myreports.status.answered".localized
                     : statusLabel(report.status))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(report.status == "open" && !answered
                                     ? Theme.Color.accent : Theme.Color.textSecondary)
                HStack(spacing: 6) {
                    Text(String(format: "myreports.number.short".localized, report.displayNumber))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(Theme.Color.textSecondary)
                        .textSelection(.enabled)
                        .accessibilityLabel(
                            String(format: "myreports.number".localized, report.displayNumber)
                        )
                    if let when = formatted(report.created_at) {
                        Text(verbatim: "·").font(.caption2).foregroundColor(Theme.Color.textSecondary)
                        Text(when).font(.caption2).foregroundColor(Theme.Color.textSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                iconButton(
                    copiedKey == "report-\(report.id)" ? "checkmark" : "doc.on.doc",
                    label: "myreports.copy".localized
                ) {
                    copy(reason, key: "report-\(report.id)")
                }
                if editable {
                    iconButton("pencil", label: "myreports.edit".localized) {
                        actionError = nil
                        replyTo = nil
                        sendError = nil
                        if editing == report.id {
                            editing = nil
                            editDraft = ""
                        } else {
                            editing = report.id
                            editDraft = reason
                            editorFocused = true
                        }
                    }
                }
                iconButton("trash", label: "myreports.remove".localized) {
                    actionError = nil
                    removeTarget = report.id
                }
            }
        }
    }

    /// One turn of the exchange. The operator's side sits on the screen
    /// background and the reporter's on a wash of the text colour, so the two
    /// read apart at a glance without either growing a border.
    private func turnBlock(
        label: String,
        labelColor: Color,
        body: String,
        fromAdmin: Bool,
        copyKey: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(labelColor)
                Spacer(minLength: 0)
                // The answer gets its own copy, not just the report: people
                // quote the operator's words when they follow up.
                if let copyKey {
                    iconButton(
                        copiedKey == copyKey ? "checkmark" : "doc.on.doc",
                        label: "myreports.copy_answer".localized
                    ) {
                        copy(body, key: copyKey)
                    }
                }
            }
            Text(body).font(.footnote).foregroundColor(Theme.Color.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(fromAdmin ? Theme.Color.bgPrimary : Theme.Color.textPrimary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Rewriting the report itself. The platform tag is off the screen and back
    /// on before saving, so an edit never strips the marker the admin queue
    /// sorts by, and the character ceiling is the server's cap minus that tag.
    private func editor(for report: MyReport, tag: String) -> some View {
        let limit = max(1, Self.maxReasonLength - tag.count)
        return VStack(spacing: 8) {
            TextEditor(text: $editDraft)
                .focused($editorFocused)
                .font(.footnote)
                .foregroundColor(Theme.Color.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96, maxHeight: 220)
                .padding(8)
                .background(Theme.Color.textPrimary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if editDraft.isEmpty {
                        Text("myreports.edit.placeholder".localized)
                            .font(.footnote)
                            .foregroundColor(Theme.Color.textSecondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: editDraft) { newValue in
                    if newValue.count > limit {
                        editDraft = String(newValue.prefix(limit))
                    }
                }
                .disabled(savingEdit)

            HStack(spacing: 8) {
                cardButton("common.cancel".localized, filled: false) {
                    editing = nil
                    editDraft = ""
                    actionError = nil
                }
                cardButton(
                    "myreports.edit.save".localized,
                    filled: true,
                    enabled: !editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !savingEdit
                ) {
                    Task { await saveEdit(report, tag: tag) }
                }
            }
        }
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

    /// A quiet square in the card's corner. The glyph carries the meaning and
    /// the accessibility label carries the words, so three actions fit on a row
    /// that used to hold one.
    private func iconButton(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.Color.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - The platform tag

    /// The tag the sending client glued on ("[iOS 1.2.3] ") is ours, not
    /// something the reporter wrote. Showing it back to them reads as their own
    /// text having been mangled, and letting an edit drop it would take the
    /// report out of the queue's platform sort.
    ///
    /// Only OUR tags, not any leading bracket: an abuse report carries no tag
    /// at all, and a report that opens with "[важно] ..." is the reporter's own
    /// emphasis, not ours to eat.
    private static let tagExpression = try? NSRegularExpression(
        pattern: "^\\[(Web|Desktop [^\\]]{0,24}|Android [^\\]]{0,12}|iOS [^\\]]{0,12})\\]\\s*"
    )

    private static let crashMarker = "[CRASH]"

    private static func splitTag(_ reason: String) -> (tag: String, body: String) {
        guard let expression = tagExpression else { return ("", reason) }
        let text = reason as NSString
        guard let match = expression.firstMatch(
            in: reason,
            range: NSRange(location: 0, length: text.length)
        ) else { return ("", reason) }
        return (text.substring(with: match.range), text.substring(from: match.range.length))
    }

    // MARK: - Actions

    private func copy(_ text: String, key: String) {
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copiedKey = key
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if copiedKey == key { copiedKey = nil }
        }
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

    /// Rewrite the report. The server answers with the whole row, so the card
    /// takes that rather than patching its own copy and drifting.
    private func saveEdit(_ report: MyReport, tag: String) async {
        let text = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !savingEdit else { return }
        // Nothing typed but the same words back: closing the box is the honest
        // answer, and it costs the server nothing.
        if text == Self.splitTag(report.reason ?? "").body {
            editing = nil
            editDraft = ""
            return
        }
        savingEdit = true
        actionError = nil
        defer { savingEdit = false }
        do {
            let updated: MyReport = try await APIClient.shared.request(
                "PATCH", "/reports/mine/\(report.id)", body: EditBody(reason: tag + text)
            )
            if let index = reports?.firstIndex(where: { $0.id == report.id }) {
                reports?[index] = updated
            }
            editing = nil
            editDraft = ""
        } catch APIError.http(409, let body) {
            actionError = CardError(
                reportID: report.id,
                text: (body ?? "").contains("already_answered")
                    ? "myreports.edit.answered".localized
                    : "myreports.closed".localized
            )
        } catch APIError.http(400, _) {
            actionError = CardError(reportID: report.id, text: "myreports.edit.not_editable".localized)
        } catch APIError.http(429, _) {
            actionError = CardError(reportID: report.id, text: "myreports.edit.too_often".localized)
        } catch APIError.http(404, let body) {
            // Our handler answers `{"detail":{"code":"not_found"}}`; the
            // router's own miss answers a bare string, and that is an island
            // too old to have the route. Getting this backwards is a lie
            // either way: "try again" on a button that can never work, or
            // "your report is gone" about a report sitting right there.
            if (body ?? "").contains("not_found") {
                reports?.removeAll { $0.id == report.id }
                editing = nil
                editDraft = ""
            } else {
                actionError = CardError(reportID: report.id, text: "myreports.edit.unsupported".localized)
            }
        } catch APIError.http(405, _) {
            actionError = CardError(reportID: report.id, text: "myreports.edit.unsupported".localized)
        } catch {
            actionError = CardError(reportID: report.id, text: "myreports.edit.error".localized)
        }
    }

    /// Take the report off this list. Server-side it is a hide, not a delete:
    /// the row stays and still counts on the Hall of Fame, which is why the
    /// copy says "remove from my list" everywhere and never "delete".
    private func remove(_ reportID: Int) async {
        actionError = nil
        do {
            _ = try await APIClient.shared.rawRequest("DELETE", "/reports/mine/\(reportID)")
            drop(reportID)
        } catch APIError.http(409, _) {
            // A still-open report ABOUT another user waits for a verdict: the
            // reporter is a live party to that case and the thread is the only
            // way the operator can ask them anything.
            actionError = CardError(reportID: reportID, text: "myreports.remove.refused".localized)
        } catch APIError.http(404, _) {
            // Already gone, from another device or from the operator's side.
            drop(reportID)
        } catch {
            actionError = CardError(reportID: reportID, text: "myreports.remove.error".localized)
        }
    }

    private func drop(_ reportID: Int) {
        reports?.removeAll { $0.id == reportID }
        if replyTo == reportID {
            replyTo = nil
            draft = ""
            sendError = nil
        }
        if editing == reportID {
            editing = nil
            editDraft = ""
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
    ///
    /// Date only, no clock time: the line now carries the report number as
    /// well and shares its row with three icons, and a full timestamp pushed
    /// the whole thing off a narrow card. Android and web print the date alone
    /// here for the same reason.
    private func formatted(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = withFrac.date(from: iso) ?? plain.date(from: iso) else { return nil }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .none
        return out.string(from: date)
    }

    private func load() async {
        defer { loading = false }
        reports = try? await APIClient.shared.request("GET", "/reports/mine") as [MyReport]
    }
}
