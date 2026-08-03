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
/// Reachable regardless of the shop toggle — an operator who closes their shop
/// must not strand people on the wrong number, and a self-hoster can hand a
/// member a second number by hand (POST /admin/uin/grant).
struct MyUINsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var data: AppState.MyUINs?
    @State private var loading = true
    @State private var switching: Int?
    @State private var confirmTarget: Int?
    @State private var error: String?

    private var activeUIN: Int { data?.active ?? AuthService.shared.ownUIN ?? 0 }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                Theme.Color.bgPrimary.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        caption("my_uins.active".localized)
                        activeCard

                        Spacer().frame(height: 6)
                        caption("my_uins.held".localized)

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

                        if let error {
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundColor(.red.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 4)
                        }

                        Text("my_uins.footer".localized)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 10)
                            .fixedSize(horizontal: false, vertical: true)
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
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "\(item.uin)")
                    .font(.system(size: 19, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.Color.textPrimary)
                    .monospacedDigit()
                Text(String(format: "uin_shop.plate.digits".localized, item.length))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.Color.textSecondary)
            }
            Spacer()
            if switching == item.uin {
                ProgressView().scaleEffect(0.8)
            } else {
                Button("my_uins.use".localized) { confirmTarget = item.uin }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.Color.accent)
                    .disabled(switching != nil)
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
            error = msg
        }
    }
}
