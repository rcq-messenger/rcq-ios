import SwiftUI

/// The numbers this account holds, and which one it answers as.
///
/// The shop and this screen are deliberately two places. Taking a number and
/// BECOMING it used to be the same tap, which put "everyone who knows me
/// loses me" one button away from browsing; the server split the two
/// (POST /uin/purchase{switch:false} then POST /uin/activate) and this is the
/// second half. Switching here is reversible: the number in use goes into the
/// collection rather than back into the pool, so there is always a way back.
///
/// Releasing (DELETE /uin/mine/{uin}) is the one thing here that is NOT
/// reversible, and it is the thing this screen was missing: every switch parks
/// the previous number in the collection whether anyone wanted it or not, so
/// the collection fills with numbers nobody chose and there was no way to say
/// no to one. Same place Android puts it, on the row itself.
///
/// Reachable regardless of the shop toggle — an operator who closes their shop
/// must not strand people on the wrong number, and a self-hoster can hand a
/// member a second number by hand (POST /admin/uin/grant).
struct MyUINsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var data: AppState.MyUINs?
    @State private var loading = true
    @State private var switching: Int?
    @State private var releasing: Int?
    @State private var unlisting: Int? = nil
    @State private var confirmTarget: Int?
    @State private var releaseTarget: Int?
    @State private var error: String?

    private var activeUIN: Int { data?.active ?? AuthService.shared.ownUIN ?? 0 }

    /// One number at a time, and nothing else while it is in flight: both calls
    /// rewrite the whole collection server-side.
    private var busy: Bool { switching != nil || releasing != nil }

    /// The island stopped handing out second numbers and this account holds
    /// none. Not a loading state: `data` has to be there for it to be true.
    private var collectionsClosed: Bool {
        guard let data else { return false }
        return data.maxOwned <= 0 && data.owned.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.Color.bgPrimary.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        caption("my_uins.active".localized)
                        activeCard

                        Spacer().frame(height: 6)
                        // A cap of zero means the island closed collections
                        // (2026-09-01: one number per account, everywhere).
                        // Then there is no shelf to draw and no count to draw
                        // it with — "0 of 10" over an empty list reads as a
                        // bug, and the honest version is one sentence.
                        if collectionsClosed {
                            Text("my_uins.closed".localized)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.Color.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 10)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                        // "3 of 10" — the cap exists, so it belongs on screen
                        // before you hit it, not only in the refusal.
                        caption(
                            "my_uins.held".localized + "  " +
                            String(
                                format: "my_uins.held_count".localized,
                                (data?.owned ?? []).count,
                                data?.maxOwned ?? 10
                            )
                        )

                        if loading, data == nil {
                            HStack {
                                Spacer()
                                ProgressView().padding(.vertical, 24)
                                Spacer()
                            }
                        } else if (data?.owned ?? []).isEmpty {
                            Text("my_uins.empty".localized)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.Color.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 18)
                        } else {
                            ForEach(data?.owned ?? []) { item in
                                heldRow(item)
                            }
                        }
                        }

                        if let error {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundColor(.red.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 4)
                        }

                        if !collectionsClosed {
                        Text("my_uins.footer".localized)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 10)
                            .fixedSize(horizontal: false, vertical: true)

                        // The rules the server actually enforces, said once
                        // here rather than only in a refusal: the cap, and
                        // that a release cannot be taken back.
                        Text(
                            String(
                                format: "my_uins.footer.rules".localized,
                                data?.maxOwned ?? 10
                            )
                        )
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                        .padding(.bottom, 16)
                        .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("my_uins.title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Theme.Color.textSecondary)
                    }
                    .accessibilityLabel("common.close".localized)
                }
            }
            .task { await reload() }
            .confirmationDialog(
                confirmTarget.map { String(format: "my_uins.confirm.title".localized, String($0)) } ?? "",
                isPresented: Binding(
                    get: { confirmTarget != nil },
                    set: { if !$0 { confirmTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("my_uins.use".localized) {
                    if let target = confirmTarget {
                        confirmTarget = nil
                        Task { await activate(target) }
                    }
                }
                Button("common.cancel".localized, role: .cancel) { confirmTarget = nil }
            } message: {
                Text(String(format: "my_uins.confirm.body".localized, String(activeUIN)))
            }
            // The warning lives in the dialog rather than on the row: the
            // number goes back into the pool and somebody else can take it, so
            // this is read once, not glanced at.
            .confirmationDialog(
                releaseTarget.map { String(format: "my_uins.release.confirm.title".localized, String($0)) } ?? "",
                isPresented: Binding(
                    get: { releaseTarget != nil },
                    set: { if !$0 { releaseTarget = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("my_uins.release.cta".localized, role: .destructive) {
                    if let target = releaseTarget {
                        releaseTarget = nil
                        Task { await release(target) }
                    }
                }
                Button("common.cancel".localized, role: .cancel) { releaseTarget = nil }
            } message: {
                Text("my_uins.release.confirm.body".localized)
            }
        }
    }

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(activeUIN)")
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.Color.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("my_uins.active.sub".localized)
                .font(.system(size: 12))
                .foregroundColor(Theme.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
        .padding(.horizontal, 18)
        .background(Theme.Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func heldRow(_ item: AppState.OwnedUIN) -> some View {
        let listing = data?.listed.first { $0.uin == item.uin }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(item.uin)")
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.Color.textPrimary)
                    .monospacedDigit()
                if let listing {
                    Text(String(format: "my_uins.listed".localized, listing.priceDisplay))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Color.accent)
                } else {
                    Text(String(format: "uin_shop.plate.digits".localized, item.length))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.Color.textSecondary)
                }
            }
            Spacer()
            if switching == item.uin || releasing == item.uin || unlisting == item.uin {
                ProgressView().scaleEffect(0.8)
            } else if let listing {
                // ⚠ On sale: neither released nor moved onto while a buyer may
                // be paying for it. Listed from another client (iOS cannot
                // sell); the one door here is back off the market, and the
                // island refuses even that while somebody is paying.
                if listing.held {
                    Text("uin_shop.being_paid".localized)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Color.textSecondary)
                } else {
                    Button("my_uins.unlist".localized) { Task { await unlist(item.uin) } }
                        .font(.system(size: 13))
                        .foregroundColor(Theme.Color.textSecondary)
                        .disabled(busy)
                }
            } else {
                // Release sits before Switch and quieter than it, same order
                // Android uses: this is tidying up, not the thing the screen
                // is for, and the confirm dialog carries the warning.
                Button("my_uins.release".localized) { releaseTarget = item.uin }
                    .font(.system(size: 13))
                    .foregroundColor(Theme.Color.textSecondary)
                    .disabled(busy)
                Button("my_uins.use".localized) { confirmTarget = item.uin }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Color.accent)
                    .disabled(busy)
            }
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 16)
        .background(Theme.Color.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.Color.textSecondary)
    }

    private func reload() async {
        loading = true
        error = nil
        data = await AppState.shared.myUINs()
        loading = false
    }

    private func activate(_ uin: Int) async {
        switching = uin
        let result = await AppState.shared.activateUIN(uin)
        switching = nil
        switch result {
        case .success:
            // The account is now answering as the new number and boot() has
            // already re-run; close and let the caller's screen show it.
            dismiss()
        case .taken:
            await reload()
        case .cooldown:
            error = "uin_shop.error.cooldown".localized
        case .other(let msg):
            // /activate refuses a suspended account with a JSON body; showing
            // it raw is how somebody meets `{"detail":{"code":...}}`.
            error = AppState.uinRefusalText(msg)
        }
    }

    /// Give a number back. The server answers with the whole collection, so the
    /// screen takes that rather than dropping the row locally and hoping.
    private func unlist(_ uin: Int) async {
        unlisting = uin
        defer { unlisting = nil }
        if await AppState.shared.unlistUIN(uin) {
            // A transport blip on the re-read must not blank the collection.
            if let fresh = await AppState.shared.myUINs() { data = fresh }
        } else {
            error = "my_uins.unlist.error".localized
        }
    }

    private func release(_ uin: Int) async {
        releasing = uin
        error = nil
        let result = await AppState.shared.releaseUIN(uin)
        releasing = nil
        switch result {
        case .success(let updated):
            data = updated
        case .inUse:
            error = "my_uins.release.error.in_use".localized
        case .notOwned:
            // Already gone, most likely from another device. Re-reading is the
            // honest answer, not an error about a number nobody holds.
            await reload()
        case .unsupported:
            error = "my_uins.release.error.unsupported".localized
        case .rateLimited:
            error = "my_uins.release.error.too_often".localized
        case .suspended:
            error = "uin.error.suspended".localized
        case .other(let msg):
            error = AppState.uinRefusalText(msg)
        }
    }
}
