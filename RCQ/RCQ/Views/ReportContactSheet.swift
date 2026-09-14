import SwiftUI

/// User-facing report flow. Shown when the long-press preview's
/// "Report" action fires on a contact. Single text-field + submit;
/// posts to /reports with `context = "contact"` so the admin queue
/// can sort by surface where the report originated.
///
/// Sealed-sender means the server can't tie this to a specific
/// message — the report is against the UIN as a whole. The reason
/// text the user types here is the only signal the admin sees.
struct ReportContactSheet: View {
    let targetUIN: Int
    let targetNickname: String
    /// Surface label that lands in the report row's `context` column
    /// — admin uses it to triage by where the report originated.
    /// Defaults to "contact" for legacy call sites that don't pass
    /// a value; UGC surfaces wire their own ("profile", "chat",
    /// "group", "audio_room", "stranger_mode", "site:<name>@<host>",
    /// "group:<id>").
    var context: String = "contact"
    /// What the reason field opens with. Empty for a person; a room report
    /// seeds it with the room's name so the moderator sees which room without
    /// looking the id in `context` up. It does not count towards the minimum:
    /// the person still has to say what happened.
    let initialReason: String

    @Environment(\.dismiss) private var dismiss
    @State private var reason: String
    @State private var sending: Bool = false
    @State private var sentOK: Bool = false
    @State private var errorMessage: String?

    private static let maxLength: Int = 1000
    private static let minLength: Int = 10

    init(targetUIN: Int, targetNickname: String, context: String = "contact", initialReason: String = "") {
        self.targetUIN = targetUIN
        self.targetNickname = targetNickname
        self.context = context
        self.initialReason = initialReason
        _reason = State(initialValue: initialReason)
    }

    /// The sheet for a room itself (App Review 1.2, B.14), not a member of it.
    /// Names the OWNER, with the room in `context` as `group:<id>` (the form
    /// the server's `Report.context` comment names and Android sends) and the
    /// room's name on the first line of the reason.
    static func forGroup(_ group: RCQGroup) -> ReportContactSheet {
        ReportContactSheet(
            targetUIN: groupReportTarget(group),
            targetNickname: group.name,
            context: groupReportContext(group),
            initialReason: group.name + "\n"
        )
    }

    /// The account a report about `group` names: its owner on THIS island. A
    /// room on another island carries its owner's uin in THAT island's uin
    /// space (§5c), and posting it to ours would file the report against
    /// whoever holds the same number here, so it goes out as `target_uin = 0`,
    /// which the server accepts with a `group:` context (reports.py,
    /// `create_report`); Android sends the same for a room without an owner.
    private static func groupReportTarget(_ group: RCQGroup) -> Int {
        guard group.host == nil, group.ownerUIN > 0 else { return 0 }
        return group.ownerUIN
    }

    /// `group:<id>` for a room on this island. A room on another island has a
    /// local NEGATIVE alias for an id here (§5c), which means nothing to the
    /// moderator reading the queue, so the host island's own id goes out with
    /// the host after it, the way a site report names its page.
    private static func groupReportContext(_ group: RCQGroup) -> String {
        if let host = group.host {
            let remote = VisitedIslandsStore.shared.refByAlias(group.id)?.remoteId ?? group.id
            return "group:\(remote)@\(host)"
        }
        return "group:\(group.id)"
    }

    private var isGroupReport: Bool { context.hasPrefix("group:") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    Text("report.body".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary)

                    reasonField

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("report.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
            .alert("report.alert.title".localized,
                   isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                   ),
                   actions: { Button("common.ok".localized, role: .cancel) {} },
                   message: { Text(errorMessage ?? "") })
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 26))
                .foregroundColor(Theme.Color.statusBusy)
                .frame(width: 52, height: 52)
                .background(Theme.Color.statusBusy.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                // A site has no person behind it: the heading says "this
                // page" and no "0" is printed where a number would go. A room
                // report names its owner, but the line under the heading is
                // the room, so the owner's number is not printed next to a
                // name that is not theirs.
                Text(headingKey.localized)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                HStack(spacing: 4) {
                    Text(targetNickname)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textPrimary)
                    if targetUIN > 0 && !isGroupReport {
                        Text(verbatim: "\(targetUIN)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
            }
        }
    }

    private var reasonField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("report.reason.label".localized)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.Color.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            ZStack(alignment: .topLeading) {
                if reason.isEmpty {
                    Text("report.reason.placeholder".localized)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textSecondary.opacity(0.6))
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $reason)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(minHeight: 160)
                    .foregroundColor(Theme.Color.textPrimary)
            }
            .background(Theme.Color.bgSecondary)
            .cornerRadius(8)
            .onChange(of: reason) { _ in
                if reason.count > Self.maxLength {
                    reason = String(reason.prefix(Self.maxLength))
                }
            }

            HStack {
                Text("\(reason.count) / \(Self.maxLength)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.Color.textSecondary)
                Spacer()
                if sentOK {
                    Label("report.sent".localized, systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                } else {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text(sending ? "report.cta.sending".localized
                                     : "report.cta.send".localized)
                            .font(.system(.body, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(canSubmit ? Theme.Color.statusBusy : Theme.Color.divider)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit || sending)
                }
            }
        }
    }

    private var headingKey: String {
        if context.hasPrefix("site:") { return "report.heading.site" }
        if isGroupReport { return "report.heading.group" }
        return "report.heading"
    }

    private var canSubmit: Bool {
        // The seeded first line is not the person's account of what happened,
        // so the minimum is measured on what they typed after it. Comparing the
        // whole text to the seed was not enough: a room with a ten-letter name
        // could be reported with one more character.
        let seeded = initialReason.trimmingCharacters(in: .whitespacesAndNewlines)
        var own = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seeded.isEmpty, own.hasPrefix(seeded) {
            own = String(own.dropFirst(seeded.count))
        }
        return own.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minLength
    }

    private func submit() async {
        struct Body: Encodable {
            let target_uin: Int
            let reason: String
            let context: String
        }
        struct Out: Decodable { let id: Int }
        sending = true
        defer { sending = false }
        do {
            let _: Out = try await APIClient.shared.request(
                "POST", "/reports",
                body: Body(
                    target_uin: targetUIN,
                    reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                    context: context
                )
            )
            sentOK = true
            // Auto-dismiss after a beat so the user gets confirmation
            // visual + the sheet doesn't sit there awaiting another tap.
            Task {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                await MainActor.run { dismiss() }
            }
        } catch {
            errorMessage = String(format: "report.error.generic".localized,
                                  error.localizedDescription)
        }
    }
}
