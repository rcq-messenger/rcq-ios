import SwiftUI

/// Confirmation sheet for disassembly — burn the item, recover
/// scrolls. Single tap commits, no second confirmation (the user
/// already opened the sheet from the detail view's "Disassemble"
/// button — that's the affordance).
struct DisassembleConfirmSheet: View {
    let item: Item
    /// `true` if the item was disassembled (so the parent can dismiss
    /// the detail sheet too).
    let onComplete: (Bool) -> Void

    @StateObject private var items = ItemsService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var working = false
    @State private var resultYield: DisassembleYield? = nil

    private var expectedScrolls: Int {
        DisassembleTables.scrollYield(rarity: item.rarity, level: item.level)
    }
    private var expectedTokens: Int {
        DisassembleTables.tokenYield(rarity: item.rarity, level: item.level)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if let yield = resultYield {
                    successScreen(yield: yield)
                } else {
                    confirmScreen
                }
            }
            .navigationTitle("disassemble.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.cancel".localized) {
                        onComplete(false)
                        dismiss()
                    }
                    .foregroundColor(Theme.Color.accent)
                }
            }
        }
    }

    private var confirmScreen: some View {
        VStack(spacing: 18) {
            ItemCard(item: item)
                .frame(width: 120, height: 120)
                .padding(.top, 20)
            Text(ItemDisplay.name(for: item.kindID))
                .font(Theme.Font.nickname)
                .foregroundColor(Theme.Color.textPrimary)
            Text("disassemble.body".localized)
                .font(Theme.Font.statusLabel)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "gem", ext: "gif")
                        .frame(width: 24, height: 24)
                    Text("≈ \(expectedScrolls)")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundColor(Theme.Color.textPrimary)
                }
                HStack(spacing: 6) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                        .frame(width: 24, height: 24)
                    Text("≈ \(expectedTokens)")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundColor(Theme.Color.textPrimary)
                }
            }
            .padding(.vertical, 8)
            Spacer()
            Button {
                Task { await commit() }
            } label: {
                Text((working ? "disassemble.cta.busy" : "disassemble.cta").localized)
                    .font(Theme.Font.nickname)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(working ? Theme.Color.divider : Color.red.opacity(0.8))
                    .cornerRadius(8)
            }
            .disabled(working)
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
    }

    private func successScreen(yield: DisassembleYield) -> some View {
        VStack(spacing: 16) {
            Spacer()
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    ItemAssetImage(bundleSubdir: "Items", filename: "gem", ext: "gif")
                        .frame(width: 64, height: 64)
                    Text("+\(yield.scrolls)")
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundColor(Theme.Color.textPrimary)
                }
                if yield.tokens > 0 {
                    VStack(spacing: 4) {
                        ItemAssetImage(bundleSubdir: "Items", filename: "coin", ext: "gif")
                            .frame(width: 64, height: 64)
                        Text("+\(yield.tokens)")
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .foregroundColor(Theme.Color.textPrimary)
                    }
                }
            }
            Text(String(format: "disassemble.success.body".localized, ItemDisplay.name(for: item.kindID)))
                .font(Theme.Font.statusLabel)
                .foregroundColor(Theme.Color.textSecondary)
            Spacer()
            Button {
                onComplete(true)
                dismiss()
            } label: {
                Text("common.done".localized)
                    .font(Theme.Font.nickname)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Theme.Color.accent)
                    .cornerRadius(8)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
    }

    @MainActor
    private func commit() async {
        guard !working else { return }
        working = true
        let yield = await items.disassemble(item)
        working = false
        if let yield {
            withAnimation(.easeInOut(duration: 0.25)) {
                resultYield = yield
            }
        }
    }
}
