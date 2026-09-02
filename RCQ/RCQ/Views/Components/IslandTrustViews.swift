import SwiftUI

/// The two things the trust layer says to a person
/// (docs/island-fingerprint-design.md §5). Both are strips in the app's banner
/// style, not dialogs: a modal would stop onboarding on a question most
/// people cannot evaluate, and the careful person types `host#fp` instead.

/// §5.2: an island presented a certificate other than the one on file. Drawn
/// at the top of the main screen from `IslandTrust.changed`, and inline in an
/// address form when the value just typed is the one that disagrees. Red,
/// because this is the one sentence in the app that may mean an interception;
/// not blocking, because the island is already refused and nothing is at risk
/// while the person reads.
struct IslandTrustChangedBanner: View {
    let change: IslandTrust.Change
    /// Runs after the new value is on file. The main screen reconnects here;
    /// a form re-runs the add the person asked for.
    var onAccepted: () -> Void = {}
    /// "Not now" folds the banner to its first line; it does not leave,
    /// because the island stays refused and this is the only place that says so.
    @State private var folded = false

    /// The sentence for a refusal. `entered` FIRST: that change came out of
    /// `admit`, where nothing was dialled and no island presented anything, so
    /// the two sentences below would accuse a host of an interception over a
    /// value the person had just typed themselves. Then, of the two the
    /// handshake raises, whether the value on file was typed or picked up.
    private var headline: String {
        if change.entered { return "island.trust.changed_entered" }
        return change.typed ? "island.trust.changed_typed" : "island.trust.changed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: headline.localized, change.host))
            .font(.system(size: 12))
            .foregroundColor(Theme.Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .lineLimit(folded ? 1 : nil)
            if !folded {
                HStack(alignment: .top, spacing: 16) {
                    column(
                        "island.trust.on_file".localized,
                        change.old.map(IslandTrust.displayFingerprint) ?? "island.trust.via_ca".localized
                    )
                    column(
                        (change.entered ? "island.trust.entered" : "island.trust.presented").localized,
                        IslandTrust.displayFingerprint(change.new)
                    )
                }
                HStack(spacing: 18) {
                    Button {
                        IslandTrust.shared.accept(change)
                        onAccepted()
                    } label: {
                        Text("island.trust.accept".localized)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.Color.accent)
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { folded = true }
                    } label: {
                        Text("island.trust.later".localized)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Color.statusBusy.opacity(0.15))
        .contentShape(Rectangle())
        .onTapGesture {
            if folded { withAnimation(.easeInOut(duration: 0.15)) { folded = false } }
        }
    }

    private func column(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.Color.textSecondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Theme.Color.textMono)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// §5.1: the first connection to an island this device had never seen, said
/// once and then never again for that host (`noticed`). Dismissible, and it
/// stays until dismissed rather than fading on a timer, because it is the one
/// chance to compare the fingerprint with what the operator published.
struct IslandTrustFirstUseNotice: View {
    let notice: IslandTrust.FirstUse

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    format: "island.trust.first_use".localized,
                    notice.host, IslandTrust.inlineFingerprint(notice.fp)
                ))
                .font(.system(size: 12))
                .foregroundColor(Theme.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                IslandTrust.shared.markNoticed(notice)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.Color.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("common.close".localized)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.Color.bgSecondary)
    }
}
