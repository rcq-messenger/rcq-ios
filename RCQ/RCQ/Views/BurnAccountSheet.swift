import SwiftUI

/// "Permanently delete account" from Settings, across islands (spec
/// 2026-09-15 F2).
///
/// Confirm → the copies on other islands (Phase R) → a decision on the ones
/// that failed → the home island (Phase H) → the device (Phase W).
///
/// ⚠ The order is the point. The keys are what prove a copy is ours, so every
/// other island goes before the home island and before the wipe: once the keys
/// are gone a copy left behind can only be deleted with the recovery phrase,
/// and the failure list says that before "Burn anyway" is pressed. The home
/// island goes last because a failure there leaves the whole account in place
/// and able to try again.
///
/// Every per-island line is the island's own claim ("island confirmed
/// deletion"), because that is all the device can know.
///
/// The final "burned on N islands" is not shown here: the wipe reboots the
/// app and this sheet goes with Settings, so the app root shows it
/// (`AppState.burnReport`).
struct BurnAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// The account is gone and the app has started over.
    let onBurned: () -> Void

    private typealias Sibling = AppState.BurnPlan.Sibling

    private enum Phase: Equatable {
        case confirm
        case remote
        case failures
        case home
        case homeFailed(partial: Bool, removed: [Sibling])
        case cancelled(hosts: [String], removed: [Sibling])
    }

    @State private var phase: Phase = .confirm
    @State private var plan: AppState.BurnPlan?
    @State private var results: [String: IslandBurnResult] = [:]
    /// The drains are held for the burn: set once Phase R or H starts, and
    /// cleared on every way out, so a sheet swiped away or torn down never
    /// leaves the account without its drains.
    @State private var held = false
    /// The step in flight (Phase R or H).
    @State private var flow: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("settings.account.burn".localized)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(phase == .remote || phase == .failures || phase == .home)
        .onAppear {
            guard plan == nil else { return }
            if let p = AppState.shared.burnPlan() {
                plan = p
            } else {
                dismiss()
            }
        }
        .onDisappear {
            // ⚠ Torn down with no button pressed: the lock swapped the root,
            // say. During Phase R the islands are still being asked, so the
            // burn is NOT released here (the drains would start minting tokens
            // for copies being deleted). The flow is cancelled instead; it
            // releases the burn itself once the requests in the air are back,
            // and never goes on to the home island with nobody watching.
            // During Phase H the home delete may already have landed, so that
            // step runs to its end and releases on its own if it failed.
            if phase == .remote, let flow {
                flow.cancel()
            } else if held, phase != .home {
                AppState.shared.releaseBurn(plan ?? .empty, forgetting: settledHosts)
                held = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .confirm:
            confirmView
        case .remote:
            working("burn.progress".localized)
        case .failures:
            failuresView
        case .home:
            working("settings.account.burning".localized)
        case .homeFailed(let partial, let removed):
            paragraph((partial ? "burn.home_failed.partial" : "settings.account.burn_failed").localized)
            removedLines(removed)
            actionButton("common.ok".localized, style: .primary) { dismiss() }
        case .cancelled(let hosts, let removed):
            if !hosts.isEmpty {
                paragraph(String(format: "burn.cancel.partial".localized, hosts.joined(separator: ", ")))
            }
            removedLines(removed)
            actionButton("common.ok".localized, style: .primary) { dismiss() }
        }
    }

    @ViewBuilder
    private var confirmView: some View {
        let p = plan ?? .empty
        Text("settings.account.burn.title".localized)
            .font(.headline)
            .foregroundColor(Theme.Color.textPrimary)
        paragraph("settings.account.burn.message".localized)
        if !p.hosts.isEmpty {
            paragraph(String(
                format: PluralKey.pick("burn.islands.body", p.hosts.count).localized,
                p.hosts.count, p.hosts.joined(separator: ", ")
            ))
            if !p.ownedGroups.isEmpty {
                paragraph(String(format: "burn.islands.owned_groups".localized, p.ownedGroups.joined(separator: ", ")))
            }
        }
        ForEach(p.siblings) { s in
            // The number as plain digits: a formatted Int would group them.
            paragraph(String(format: "burn.sibling".localized, String(s.uin), s.host))
        }
        note("burn.not_covered".localized)
        actionButton("settings.account.burn.confirm".localized, style: .destructive) { start() }
        actionButton("common.cancel".localized, style: .plain) { dismiss() }
    }

    @ViewBuilder
    private var failuresView: some View {
        let failedCount = results.values.filter { !$0.isSettled }.count
        Text(String(format: PluralKey.pick("burn.failures.title", failedCount).localized, failedCount))
            .font(.headline)
            .foregroundColor(Theme.Color.textPrimary)
        ForEach(resultHosts, id: \.self) { host in
            let result = results[host] ?? .notTried
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: host)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(Theme.Color.textPrimary)
                Text(rowText(result))
                    .font(.caption)
                    .foregroundColor(result.isSettled ? Theme.Color.textSecondary : Theme.Color.statusBusy)
            }
        }
        note("burn.anyway.hint".localized)
        actionButton("burn.retry".localized, style: .primary) { retryFailed() }
        actionButton("burn.anyway".localized, style: .destructive) { runHome() }
        actionButton("common.cancel".localized, style: .plain) { cancelBurn() }
    }

    // MARK: pieces

    /// Same-key accounts whose island confirmed the delete while the burn
    /// then stopped: they no longer exist there, so they left this device too.
    @ViewBuilder
    private func removedLines(_ removed: [Sibling]) -> some View {
        ForEach(removed) { s in
            paragraph(String(format: "burn.sibling_removed".localized, String(s.uin), s.host))
        }
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundColor(Theme.Color.textSecondary)
        }
        .padding(.vertical, 8)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(Theme.Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(Theme.Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private enum ButtonKind { case primary, destructive, plain }

    @ViewBuilder
    private func actionButton(_ title: String, style: ButtonKind, action: @escaping () -> Void) -> some View {
        switch style {
        case .destructive:
            Button(role: .destructive, action: action) { buttonLabel(title) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Color.statusBusy)
        case .primary:
            Button(action: action) { buttonLabel(title) }
                .buttonStyle(.bordered)
                .tint(Theme.Color.accent)
        case .plain:
            Button(action: action) { buttonLabel(title) }
                .buttonStyle(.plain)
                .foregroundColor(Theme.Color.textSecondary)
        }
    }

    private func buttonLabel(_ title: String) -> some View {
        Text(title)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private func rowText(_ result: IslandBurnResult) -> String {
        let key: String
        switch result {
        case .confirmed: key = "burn.row.confirmed"
        case .alreadyGone: key = "burn.row.already_gone"
        case .notTried: key = "burn.row.not_tried"
        case .failed(let reason):
            switch reason {
            case .offline: key = "burn.row.offline"
            case .timeout: key = "burn.row.timeout"
            case .suspended: key = "burn.row.suspended"
            case .tooOld: key = "burn.row.too_old"
            case .limit: key = "burn.row.limit"
            case .server: key = "burn.row.server"
            }
        }
        return key.localized
    }

    // MARK: flow

    /// In the plan's order, the islands that have an answer.
    private var resultHosts: [String] { (plan?.hosts ?? []).filter { results[$0] != nil } }

    /// Islands that confirmed or reported no copy: nothing left to do there.
    private var settledHosts: [String] { Self.settled(plan ?? .empty, results) }

    private static func settled(_ p: AppState.BurnPlan, _ r: [String: IslandBurnResult]) -> [String] {
        p.hosts.filter { r[$0]?.isSettled == true }
    }

    /// Islands that confirmed a deletion, the only ones a partial outcome is
    /// allowed to name as deleted.
    private var confirmedHosts: [String] {
        (plan?.hosts ?? []).filter {
            if case .confirmed = results[$0] { return true }
            return false
        }
    }

    private func start() {
        guard let p = plan else { return }
        guard !p.hosts.isEmpty else {
            runHome()
            return
        }
        phase = .remote
        held = true
        flow = Task {
            let got = await AppState.shared.burnRemote(p)
            guard !Task.isCancelled, !got.isEmpty else {
                // Cancelled by the teardown, or refused (locked): hand the
                // drains back now that nothing is in the air, and stop.
                AppState.shared.releaseBurn(p, forgetting: Self.settled(p, got))
                held = false
                flow = nil
                if !Task.isCancelled { dismiss() }
                return
            }
            results = got
            flow = nil
            advance()
        }
    }

    private func retryFailed() {
        guard let p = plan else { return }
        let failed = Set(results.filter { !$0.value.isSettled }.map(\.key))
        let before = results
        phase = .remote
        flow = Task {
            let again = await AppState.shared.burnRemote(p, only: failed)
            let merged = before.merging(again) { _, fresh in fresh }
            guard !Task.isCancelled, !again.isEmpty else {
                AppState.shared.releaseBurn(p, forgetting: Self.settled(p, merged))
                held = false
                flow = nil
                if !Task.isCancelled { dismiss() }
                return
            }
            results = merged
            flow = nil
            advance()
        }
    }

    private func advance() {
        if results.values.allSatisfy(\.isSettled) {
            runHome()
        } else {
            phase = .failures
        }
    }

    private func runHome() {
        guard let p = plan else { return }
        // Read now: once the wipe reboots the app this view is gone, and
        // its state reads back empty.
        let settledNow = settledHosts
        let partial = !confirmedHosts.isEmpty
        let confirmedCount = confirmedHosts.count
        phase = .home
        held = true
        flow = Task {
            let burned = await AppState.shared.burnFinish(p, confirmedIslands: confirmedCount)
            flow = nil
            held = false
            if burned {
                onBurned()
            } else {
                let removed = AppState.shared.releaseBurn(p, forgetting: settledNow)
                phase = .homeFailed(partial: partial, removed: removed)
            }
        }
    }

    private func cancelBurn() {
        guard let p = plan else { return }
        let removed = AppState.shared.releaseBurn(p, forgetting: settledHosts)
        held = false
        let gone = confirmedHosts
        if gone.isEmpty && removed.isEmpty {
            dismiss()
        } else {
            phase = .cancelled(hosts: gone, removed: removed)
        }
    }
}

/// `<base>.one` or `<base>.other` for `n` in the language the app is showing.
///
/// The count in these lines sits inside a phrase ("on 1 other island", "на 21
/// острове"), and the strings tables carry one form for one and one for the
/// rest. Russian and Ukrainian take the singular for 1, 21, 31 and so on (the
/// locative plural is the same for "few" and "many"); Chinese has one form;
/// the other shipped languages switch at exactly 1.
enum PluralKey {
    static func pick(_ base: String, _ n: Int) -> String {
        "\(base).\(isOne(n) ? "one" : "other")"
    }

    private static func isOne(_ n: Int) -> Bool {
        let bundle = LanguageManager.currentBundle
        let lang = bundle == .main
            ? (Bundle.main.preferredLocalizations.first ?? "en")
            : bundle.bundleURL.deletingPathExtension().lastPathComponent
        if lang.hasPrefix("ru") || lang.hasPrefix("uk") { return n % 10 == 1 && n % 100 != 11 }
        if lang.hasPrefix("zh") { return false }
        return n == 1
    }
}
