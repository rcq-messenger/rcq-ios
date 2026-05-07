import SwiftUI

/// Read-only inventory of another user. Same grid + ItemDetailSheet
/// flow as the owner-side `InventoryView`, but with no Open / Buy /
/// Equip / Temper / Disassemble actions — peers can only inspect.
///
/// Backed by `GET /users/{uin}/inventory` which is privacy-gated:
/// a 403 from the server means the user has flipped their inventory
/// to private and we surface a "private" empty state.
struct PublicInventoryView: View {
    let uin: Int
    let nickname: String

    @StateObject private var items = ItemsService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var theirItems: [Item] = []
    @State private var isPublic = true
    @State private var loading = true
    @State private var detailItem: Item?

    /// Same five-column grid as the owner-side inventory.
    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 5,
    )

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Color.bgPrimary.ignoresSafeArea()
                if loading {
                    ProgressView().tint(Theme.Color.accent)
                } else if !isPublic {
                    privateState
                } else if theirItems.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle(String(format: "public_inventory.title".localized, nickname))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("common.close".localized) { dismiss() }
                        .foregroundColor(Theme.Color.accent)
                }
            }
            .task {
                if items.catalog == nil { await items.refreshCatalog() }
                await load()
            }
            .sheet(item: $detailItem) { item in
                ItemDetailSheet(item: item, readOnly: true)
                    .presentationDetents([.large])
            }
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(sortedSections, id: \.self) { section in
                    let bucket = theirItems
                        .filter { itemSection($0) == section }
                        .sorted { $0.rarity.rollWeight < $1.rarity.rollWeight }
                    if !bucket.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.displayName.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(Theme.Color.textSecondary)
                                .tracking(2)
                            LazyVGrid(columns: columns, spacing: 6) {
                                ForEach(bucket) { item in
                                    Button {
                                        detailItem = item
                                    } label: {
                                        ItemCard(item: item)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(Theme.Color.divider)
            Text(String(format: "public_inventory.empty".localized, nickname))
                .font(Theme.Font.statusLabel)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var privateState: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(Theme.Color.divider)
            Text("public_inventory.private.title".localized)
                .font(Theme.Font.nickname)
                .foregroundColor(Theme.Color.textPrimary)
            Text(String(format: "public_inventory.private.body".localized, nickname))
                .font(Theme.Font.statusLabel)
                .foregroundColor(Theme.Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var sortedSections: [ItemSection] {
        Array(Set(theirItems.compactMap { itemSection($0) }))
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    private func itemSection(_ item: Item) -> ItemSection? {
        items.catalog?.kind(by: item.kindID)?.section
    }

    @MainActor
    private func load() async {
        struct Resp: Codable {
            let items: [Item]
            let `public`: Bool
        }
        loading = true
        defer { loading = false }
        do {
            let res: Resp = try await APIClient.shared.request(
                "GET", "/users/\(uin)/inventory",
            )
            self.theirItems = res.items
            self.isPublic = res.public
        } catch {
            // 403 → private. Other errors fall through to "private"
            // state too — server is the only authoritative reader,
            // and we don't have anything else to show.
            self.theirItems = []
            self.isPublic = false
        }
    }
}
