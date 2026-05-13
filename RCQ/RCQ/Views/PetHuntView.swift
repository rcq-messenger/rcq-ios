import SwiftUI

/// Pet Hunt: passive token/gem mining + 3 hunt slots per day.
struct PetHuntView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = PetHuntService.shared
    @StateObject private var items = ItemsService.shared

    @State private var showInfo: Bool = false
    @State private var showZonePicker: Bool = false
    @State private var showMemorial: Bool = false
    @State private var showInventory: Bool = false
    @State private var claimingFlash: Bool = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                content
            }
            .navigationTitle("games.pets_hunt.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button { showInfo = true } label: {
                            Image(systemName: "info.circle")
                                .foregroundColor(Theme.Color.textPrimary)
                        }
                        walletBadge
                    }
                }
            }
            .task { await svc.refreshState() }
            .onReceive(ticker) { now in
                svc.tickTo(now)
            }
            .sheet(isPresented: $showInfo) {
                PetHuntInfoSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showZonePicker) {
                HuntZonePickerSheet { zone in
                    showZonePicker = false
                    Task {
                        await svc.sendHunt(zone: zone)
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showMemorial) {
                MemorialSheet()
                    .presentationDetents([.large])
            }
            .fullScreenCover(isPresented: $showInventory, onDismiss: {
                // Re-pull pet-hunt state after the inventory closes —
                // the user might have just equipped a different pet,
                // and without this refresh the Hunt screen would
                // keep showing the previous active pet until the
                // user manually relaunched the view.
                Task { await svc.refreshState() }
            }) {
                InventoryView()
            }
            .sheet(item: $svc.lastResult) { result in
                HuntResultSheet(result: result) {
                    svc.acknowledgeResult()
                }
                .presentationDetents([.height(380)])
                .interactiveDismissDisabled(false)
            }
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        if svc.state == nil {
            ProgressView()
                .tint(Theme.Color.textSecondary)
        } else if svc.state?.pet == nil {
            noPetEmptyState
        } else {
            mainPanel
        }
    }

    /// Markdown-parsed empty-state body. `AttributedString(markdown:)`
    /// throws when the localized template has no markdown, so we fall
    /// back to a plain attributed string in that case to avoid an
    /// empty Text.
    private var emptyStateBody: AttributedString {
        let raw = "pet_hunt.empty.no_pet.body".localized
        return (try? AttributedString(markdown: raw)) ?? AttributedString(raw)
    }

    private var noPetEmptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "pawprint.circle")
                .font(.system(size: 56))
                .foregroundColor(Theme.Color.divider)
            Text("pet_hunt.empty.no_pet.title".localized)
                .font(.system(.headline, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
                .multilineTextAlignment(.center)
            // Markdown-parsed so the "inventory" word becomes a
            // tappable link (accent-tinted). Open URL intercept below
            // catches `rcq://inventory` and flips the fullScreenCover
            // without the user having to leave the Hunt screen.
            Text(emptyStateBody)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .tint(Theme.Color.accent)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .environment(\.openURL, OpenURLAction { url in
                    if url.scheme == "rcq" && url.host == "inventory" {
                        showInventory = true
                        return .handled
                    }
                    return .systemAction
                })
            Spacer()
            Button {
                showMemorial = true
            } label: {
                Label("pet_hunt.cta.open_memorial".localized, systemImage: "leaf.arrow.circlepath")
                    .font(.callout)
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 30)
        }
    }

    private var mainPanel: some View {
        ScrollView {
            VStack(spacing: 18) {
                petHero
                petSpecTable
                accumulatorCard
                huntButton
                HStack(spacing: 10) {
                    inventoryLink
                    memorialLink
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Pet hero block

    private var petHero: some View {
        let pet = svc.state?.pet
        return VStack(spacing: 10) {
            ZStack {
                if let pet {
                    Circle()
                        .fill(pet.rarity.color.opacity(0.45))
                        .frame(width: 180, height: 180)
                        .blur(radius: 32)
                }
                ItemAssetImage(
                    bundleSubdir: petAssetSubdir,
                    filename: petAssetStem,
                    ext: petAssetExt,
                )
                .frame(width: 144, height: 144)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            }
            if let pet {
                Text(ItemDisplay.name(for: pet.kindID))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text(pet.rarity.label.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(pet.rarity.color))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var petSpecTable: some View {
        guard let pet = svc.state?.pet, let s = svc.state else {
            return AnyView(EmptyView())
        }
        let perHour = Double(s.dailyYield) / 24.0
        return AnyView(
            VStack(spacing: 0) {
                specRow(label: "market.spec.tier".localized) {
                    Text(pet.rarity.label)
                        .font(.callout.weight(.medium))
                        .foregroundColor(pet.rarity.color)
                }
                if pet.level > 0 {
                    specDivider
                    specRow(label: "market.spec.level".localized) {
                        Text("+\(pet.level)")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
                specDivider
                specRow(label: "market.spec.purity".localized) {
                    Text(String(format: "%.2f×", pet.purity))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.Color.textPrimary)
                }
                if let mint = pet.mintNumber {
                    specDivider
                    specRow(label: "item.stat.mint".localized) {
                        Text(verbatim: "#\(mint)")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
                specDivider
                specRow(label: "market.spec.essence".localized) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                        Text("\(pet.baseEssence)")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(Theme.Color.accent)
                }
                specDivider
                specRow(label: "pet_hunt.spec.daily_yield".localized) {
                    HStack(spacing: 4) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 16, height: 16)
                        Text("\(s.dailyYield)")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
                specDivider
                specRow(label: "pet_hunt.spec.daily_gems".localized) {
                    HStack(spacing: 4) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "gem", ext: "gif")
                            .frame(width: 16, height: 16)
                        Text("\(s.dailyGems)")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
                specDivider
                specRow(label: "pet_hunt.spec.hourly_rate".localized) {
                    HStack(spacing: 4) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 16, height: 16)
                        Text(perHour >= 1
                             ? String(format: "%.1f", perHour)
                             : String(format: "%.2f", perHour))
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
            }
            .background(Theme.Color.bgSecondary)
            .cornerRadius(12)
        )
    }

    private func specRow<Content: View>(
        label: String, @ViewBuilder value: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
            value()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var specDivider: some View {
        Rectangle()
            .fill(Theme.Color.divider.opacity(0.4))
            .frame(height: 0.5)
            .padding(.leading, 14)
    }

    private var petAssetSubdir: String {
        guard let pet = svc.state?.pet,
              let kind = items.catalog?.kind(by: pet.kindID) else { return "Items" }
        let trimmed = kind.assetRef.hasPrefix("items/")
            ? String(kind.assetRef.dropFirst("items/".count))
            : kind.assetRef
        let subdir = (trimmed as NSString).deletingLastPathComponent
        return subdir.isEmpty ? "Items" : "Items/\(subdir)"
    }
    private var petAssetStem: String {
        guard let pet = svc.state?.pet,
              let kind = items.catalog?.kind(by: pet.kindID) else { return "" }
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
    private var petAssetExt: String {
        guard let pet = svc.state?.pet,
              let kind = items.catalog?.kind(by: pet.kindID) else { return "png" }
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).pathExtension
    }

    // MARK: - Accumulator + claim

    private var accumulatorCard: some View {
        VStack(spacing: 12) {
            Text("pet_hunt.accumulator.title".localized.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundColor(Theme.Color.textSecondary)
            HStack(spacing: 24) {
                accumulatorCounter(
                    iconName: "coin",
                    value: svc.displayedAccumulated,
                )
                Rectangle()
                    .fill(Theme.Color.divider.opacity(0.5))
                    .frame(width: 0.5, height: 36)
                accumulatorCounter(
                    iconName: "gem",
                    value: svc.displayedAccumulatedGems,
                )
            }
            if let s = svc.state {
                VStack(spacing: 2) {
                    Text(String(format: "pet_hunt.daily_yield".localized, s.dailyYield))
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                    Text(String(format: "pet_hunt.daily_gems".localized, s.dailyGems))
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                if s.capReached {
                    Text("pet_hunt.cap_reached".localized)
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Color.orange)
                }
            }
            Button {
                Task {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        claimingFlash = true
                    }
                    let claimed = await svc.claim()
                    if claimed != nil {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            claimingFlash = false
                        }
                    }
                }
            } label: {
                Text("pet_hunt.claim".localized)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(hasAnythingToClaim
                                ? Theme.Color.accent
                                : Theme.Color.divider)
                    .cornerRadius(10)
            }
            .disabled(!hasAnythingToClaim)
            .scaleEffect(claimingFlash ? 0.96 : 1.0)
        }
        .padding(16)
        .background(Theme.Color.bgSecondary)
        .cornerRadius(14)
    }

    private var hasAnythingToClaim: Bool {
        svc.displayedAccumulated > 0 || svc.displayedAccumulatedGems > 0
    }

    private func accumulatorCounter(iconName: String, value: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ItemAssetImage(bundleSubdir: "Items", filename: iconName, ext: "gif")
                .frame(width: 32, height: 32)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 4 }
            Text("\(value)")
                .font(.system(size: 32, weight: .bold, design: .monospaced).monospacedDigit())
                .foregroundColor(Theme.Color.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: value)
        }
    }

    // MARK: - Hunt button

    private var huntButton: some View {
        let huntsLeft = svc.state?.huntsLeft ?? 0
        let canHunt = huntsLeft > 0
        return Button {
            showZonePicker = true
        } label: {
            VStack(spacing: 4) {
                Text("pet_hunt.send".localized)
                    .font(.system(.headline, weight: .bold))
                    .foregroundColor(.white)
                Text(String(format: "pet_hunt.hunts_left".localized, huntsLeft, svc.state?.huntsPerDay ?? 3))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: canHunt
                        ? [Color(hex: 0xD9923A), Color(hex: 0xB8702A)]
                        : [Theme.Color.divider, Theme.Color.divider],
                    startPoint: .top, endPoint: .bottom,
                )
            )
            .cornerRadius(14)
        }
        .disabled(!canHunt)
        .buttonStyle(.plain)
    }

    private var inventoryLink: some View {
        Button {
            showInventory = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                    .foregroundColor(Theme.Color.textSecondary)
                Text("pet_hunt.cta.open_inventory".localized)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private var memorialLink: some View {
        Button {
            showMemorial = true
            Task { await svc.refreshMemorial() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill")
                    .foregroundColor(Theme.Color.textSecondary)
                Text("pet_hunt.cta.open_memorial".localized)
                    .font(.callout)
                    .foregroundColor(Theme.Color.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Wallet badge

    private var walletBadge: some View {
        HStack(spacing: 4) {
            ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                .frame(width: 18, height: 18)
            Text("\(items.wallet.tokens)")
                .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                .foregroundColor(Theme.Color.textPrimary)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: items.wallet.tokens)
        }
        .padding(.trailing, 8)
    }
}

// MARK: - Info sheet

private struct PetHuntInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // ScrollView + `.fixedSize` so death-section copy claims full intrinsic height instead of clipping.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    infoSection(
                        icon: "leaf.fill",
                        title: "pet_hunt.info.passive.title".localized,
                        body: "pet_hunt.info.passive.body".localized,
                    )
                    infoSection(
                        icon: "mountain.2.fill",
                        title: "pet_hunt.info.zones.title".localized,
                        body: "pet_hunt.info.zones.body".localized,
                    )
                    infoSection(
                        icon: "exclamationmark.triangle.fill",
                        title: "pet_hunt.info.death.title".localized,
                        body: "pet_hunt.info.death.body".localized,
                    )
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("pet_hunt.info.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done".localized) { dismiss() }
                }
            }
        }
    }

    private func infoSection(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(Theme.Color.accent)
                .frame(width: 28, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text(body)
                    .font(.footnote)
                    .foregroundColor(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Zone picker

private struct HuntZonePickerSheet: View {
    let onSelect: (HuntZone) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("pet_hunt.zone_picker.intro".localized)
                        .font(.footnote)
                        .foregroundColor(Theme.Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 6)
                    zoneCard(
                        zone: .forest,
                        rewardLabel: "pet_hunt.zone.forest.reward".localized,
                        riskLabel: "pet_hunt.zone.forest.risk".localized,
                        accent: Color(hex: 0x4FA85F),
                    )
                    zoneCard(
                        zone: .mountain,
                        rewardLabel: "pet_hunt.zone.mountain.reward".localized,
                        riskLabel: "pet_hunt.zone.mountain.risk".localized,
                        accent: Color(hex: 0xC8923A),
                    )
                    zoneCard(
                        zone: .cave,
                        rewardLabel: "pet_hunt.zone.cave.reward".localized,
                        riskLabel: "pet_hunt.zone.cave.risk".localized,
                        accent: Color(hex: 0xC0392B),
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
            .background(Theme.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("pet_hunt.zone_picker.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel".localized) { dismiss() }
                }
            }
        }
    }

    private func zoneCard(
        zone: HuntZone, rewardLabel: String, riskLabel: String, accent: Color,
    ) -> some View {
        Button {
            onSelect(zone)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: zone.icon)
                    .font(.system(size: 26))
                    .foregroundColor(accent)
                    .frame(width: 44, height: 44)
                    .background(accent.opacity(0.15))
                    .cornerRadius(10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(zone.displayName)
                        .font(.system(.headline, weight: .semibold))
                        .foregroundColor(Theme.Color.textPrimary)
                    Text(rewardLabel)
                        .font(.caption)
                        .foregroundColor(Theme.Color.textSecondary)
                    Text(riskLabel)
                        .font(.caption2)
                        .foregroundColor(accent.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(Theme.Color.textSecondary)
            }
            .padding(14)
            .background(Theme.Color.bgSecondary)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Result sheet

private struct HuntResultSheet: View {
    let result: HuntResult
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entryAnimated: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbolName)
                .font(.system(size: 56))
                .foregroundColor(symbolColor)
                .scaleEffect(entryAnimated ? 1.0 : 0.6)
                .opacity(entryAnimated ? 1.0 : 0)
            Text(headline)
                .font(.system(.title2, weight: .bold))
                .foregroundColor(Theme.Color.textPrimary)
                .multilineTextAlignment(.center)
                .opacity(entryAnimated ? 1.0 : 0)

            Text(bodyText)
                .font(.callout)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .opacity(entryAnimated ? 1.0 : 0)

            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 28, height: 28)
                    Text("+\(result.reward)")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.Color.accent)
                }
                if result.gemReward > 0 {
                    HStack(spacing: 6) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "gem", ext: "gif")
                            .frame(width: 28, height: 28)
                        Text("+\(result.gemReward)")
                            .font(.system(size: 22, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.Color.accent)
                    }
                }
            }
            .opacity(entryAnimated ? 1.0 : 0)

            Spacer(minLength: 4)

            Button {
                onDismiss()
                dismiss()
            } label: {
                Text("common.continue".localized)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.Color.accent)
                    .cornerRadius(10)
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bgPrimary)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                    entryAnimated = true
                }
                switch result.outcome {
                case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .wound:   UINotificationFeedbackGenerator().notificationOccurred(.warning)
                case .death:   UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private var symbolName: String {
        switch result.outcome {
        case .success: return "checkmark.seal.fill"
        case .wound:   return "bandage.fill"
        case .death:   return "leaf.fill"
        }
    }
    private var symbolColor: Color {
        switch result.outcome {
        case .success: return Theme.Color.accent
        case .wound:   return Color.orange
        case .death:   return Theme.Color.textSecondary
        }
    }
    private var headline: String {
        switch result.outcome {
        case .success: return "pet_hunt.result.success".localized
        case .wound:   return "pet_hunt.result.wound".localized
        case .death:   return "pet_hunt.result.death".localized
        }
    }
    private var bodyText: String {
        switch result.outcome {
        case .success:
            return String(format: "pet_hunt.result.success.body".localized,
                          result.zone.displayName)
        case .wound:
            return String(format: "pet_hunt.result.wound.body".localized,
                          result.newLevel)
        case .death:
            return "pet_hunt.result.death.body".localized
        }
    }
}

// MARK: - Memorial sheet

private struct MemorialSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var svc = PetHuntService.shared
    @StateObject private var items = ItemsService.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if svc.memorial.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("pet_hunt.memorial.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.done".localized) { dismiss() }
                }
            }
            .task { await svc.refreshMemorial() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 48))
                .foregroundColor(Theme.Color.divider)
            Text("pet_hunt.memorial.empty.title".localized)
                .font(.system(.headline, weight: .semibold))
                .foregroundColor(Theme.Color.textPrimary)
            Text("pet_hunt.memorial.empty.body".localized)
                .font(.caption)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(svc.memorial) { entry in
                    memorialRow(entry)
                }
            }
            .padding(16)
        }
    }

    private func memorialRow(_ entry: MemorialEntry) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Rectangle()
                    .fill(Theme.Color.bgSecondary)
                if let kind = items.catalog?.kind(by: entry.kindID) {
                    ItemAssetImage(
                        bundleSubdir: subdir(for: kind),
                        filename: stem(for: kind),
                        ext: ext(for: kind),
                    )
                    .padding(8)
                    .saturation(0.0)
                    .opacity(0.6)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(ItemDisplay.name(for: entry.kindID))
                    .font(.system(.callout, weight: .semibold))
                    .foregroundColor(Theme.Color.textPrimary)
                Text(entry.rarity.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(entry.rarity.color)
                if let zone = entry.diedZone {
                    Text(String(format: "pet_hunt.memorial.died_in".localized,
                                zone.displayName))
                        .font(.caption2)
                        .foregroundColor(Theme.Color.textSecondary)
                }
                Text(DateFormatter.itemAcquired.string(from: entry.diedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.Color.bgSecondary.opacity(0.55))
        .cornerRadius(10)
    }

    private func subdir(for kind: ItemKind) -> String {
        let trimmed = kind.assetRef.hasPrefix("items/")
            ? String(kind.assetRef.dropFirst("items/".count))
            : kind.assetRef
        let s = (trimmed as NSString).deletingLastPathComponent
        return s.isEmpty ? "Items" : "Items/\(s)"
    }
    private func stem(for kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).deletingPathExtension
    }
    private func ext(for kind: ItemKind) -> String {
        let basename = (kind.assetRef as NSString).lastPathComponent
        return (basename as NSString).pathExtension
    }
}
