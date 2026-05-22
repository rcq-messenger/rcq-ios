import SwiftUI

/// Renders a `.poll` message bubble. Decodes the encrypted-side
/// `PollPayload` from `Message.text` for question + option labels,
/// pairs it with server-side `PollState` for vote tallies (fetched
/// on appear, refreshed after each vote). One-tap voting; single-
/// choice polls swap the ballot, multi-choice toggles the option.
/// Creator sees a "Close poll" footer; everyone else sees totals.
struct PollBubble: View {
    let message: Message
    let creatorIsMe: Bool

    @StateObject private var svc = PollService.shared
    @State private var loading: Bool = false
    @State private var error: String?
    /// Server-side poll id recovered via `lookupByMessage` for rows
    /// that came in before `MessageDB` persisted the `pollID`
    /// column. Falls back to `message.pollID` for fresh rows.
    @State private var resolvedPollID: Int?

    private var payload: PollPayload? {
        PollPayload.decode(from: message.text)
    }

    /// Effective server-side poll id — prefer the local message's,
    /// fall back to the recovery state if we had to re-look it up.
    private var pollID: Int? {
        message.pollID ?? resolvedPollID
    }

    private var state: PollState? {
        guard let pid = pollID else { return nil }
        return svc.statesByID[pid]
    }

    private var isClosed: Bool { state?.closedAt != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let payload {
                header(payload: payload)
                ForEach(Array(payload.options.enumerated()), id: \.offset) { idx, label in
                    row(index: idx, label: label)
                }
                footer(payload: payload)
            } else {
                Text("poll.error.parse".localized)
                    .font(.caption)
                    .foregroundColor(Theme.Color.textSecondary)
            }
        }
        .padding(12)
        .background(message.isFromMe ? Theme.Color.bubbleSelf : Theme.Color.bubbleOther)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.bubbleRadius))
        .frame(maxWidth: 320, alignment: message.isFromMe ? .trailing : .leading)
        .task { await refreshOnAppear() }
    }

    private func header(payload: PollPayload) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
                Text(payload.singleChoice ? "poll.header.single".localized : "poll.header.multi".localized)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.Color.accent)
                    .textCase(.uppercase)
                    .tracking(0.5)
                if payload.anonymous {
                    Text("·")
                        .foregroundColor(Theme.Color.textSecondary)
                    Text("poll.header.anonymous".localized)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                if isClosed {
                    Text("·")
                        .foregroundColor(Theme.Color.textSecondary)
                    Text("poll.header.closed".localized)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.red.opacity(0.7))
                }
            }
            Text(payload.question)
                .font(.body.weight(.semibold))
                .foregroundColor(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Resolves `voter_uins` from the option tally into the group's
    /// member nicknames. Empty dict in 1:1 / random; populated when
    /// the poll lives in a group whose members are in the local
    /// `GroupService` cache (the common case — you have to be a
    /// group member to receive the `.poll` envelope in the first
    /// place).
    private var memberNicks: [Int: String] {
        if case .group(let gid) = message.thread,
           let g = GroupService.shared.groups.first(where: { $0.id == gid }) {
            return Dictionary(
                g.members.map { ($0.uin, $0.nickname) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        return [:]
    }

    private func row(index: Int, label: String) -> some View {
        let tally = state?.tallies.first { $0.optionIndex == index }
        let count = tally?.count ?? 0
        let total = max(1, state?.totalVotes ?? 0)
        let pct = state == nil ? 0.0 : Double(count) / Double(total)
        let mine = state?.myVotes.contains(index) ?? false
        let voterUINs = tally?.voterUINs ?? []
        let voterLabel = Self.voterListLabel(uins: voterUINs, lookup: memberNicks)
        return Button {
            Task { await tap(index: index) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: mine
                          ? (state?.singleChoice ?? true ? "largecircle.fill.circle" : "checkmark.square.fill")
                          : (state?.singleChoice ?? true ? "circle" : "square"))
                        .foregroundColor(mine ? Theme.Color.accent : Theme.Color.textSecondary)
                    Text(label)
                        .font(.callout)
                        .foregroundColor(Theme.Color.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(Theme.Color.textSecondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Color.divider)
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Color.accent.opacity(mine ? 0.85 : 0.4))
                            .frame(width: geo.size.width * pct, height: 4)
                            .animation(.easeOut(duration: 0.25), value: pct)
                    }
                }
                .frame(height: 4)
                // Voter-attribution row — only for non-anonymous
                // polls with at least one vote. Resolves UINs to
                // nicknames via the group member cache; UINs we
                // can't resolve (rare — would mean a voter left
                // the group) render as `#UIN`.
                if let voterLabel, !voterLabel.isEmpty {
                    Text(voterLabel)
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                        .lineLimit(2)
                        .padding(.leading, 26)  // align with option label after radio glyph
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isClosed)
    }

    /// Render up to 3 nicknames + "+N more" for the tail. Empty
    /// for zero votes; nil for anonymous polls (server already
    /// stripped voter_uins). The dual-state (nil vs empty) lets
    /// the caller skip rendering entirely instead of allocating
    /// padding for an invisible line.
    private static func voterListLabel(uins: [Int], lookup: [Int: String]) -> String? {
        guard !uins.isEmpty else { return nil }
        let nicks = uins.map { lookup[$0] ?? "#\($0)" }
        if nicks.count <= 3 {
            return nicks.joined(separator: ", ")
        }
        let head = nicks.prefix(3).joined(separator: ", ")
        return head + " " + String(format: "poll.row.more_voters".localized, nicks.count - 3)
    }

    private func footer(payload: PollPayload) -> some View {
        HStack(spacing: 6) {
            if let total = state?.totalVotes {
                Text(String(format: "poll.footer.total_votes".localized, total))
                    .font(.caption2)
                    .foregroundColor(Theme.Color.textSecondary)
            } else if loading {
                ProgressView().scaleEffect(0.7).tint(Theme.Color.textSecondary)
            }
            if let err = error {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.red.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            if creatorIsMe && !isClosed {
                Button {
                    Task { await closeTap() }
                } label: {
                    Text("poll.footer.close".localized)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.red.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func refreshOnAppear() async {
        loading = true
        defer { loading = false }
        if let pid = message.pollID {
            _ = await svc.refresh(pollID: pid)
        } else {
            // Recovery for pre-`pollID`-column polls — resolve the
            // server id via the envelope UUID, cache it in @State
            // so subsequent vote / close taps work. The first time
            // an old bubble appears we eat one extra round-trip;
            // every render after that uses the cached id.
            if let st = await svc.lookupByMessage(messageID: message.id.uuidString) {
                resolvedPollID = st.pollID
            }
        }
    }

    private func tap(index: Int) async {
        guard let pid = pollID, !isClosed else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        do {
            _ = try await svc.vote(pollID: pid, optionIndex: index)
            error = nil
        } catch {
            self.error = "poll.error.vote".localized
        }
    }

    private func closeTap() async {
        guard let pid = pollID else { return }
        do {
            _ = try await svc.close(pollID: pid)
        } catch {
            self.error = "poll.error.close".localized
        }
    }
}
