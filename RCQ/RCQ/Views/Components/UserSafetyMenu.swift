import SwiftUI

/// Shared Block + Report actions for any per-user surface. App Review (Guideline 1.2 — UGC) requires
/// block reachable everywhere a user can surface another's content. `context` tags the report for triage.
/// `.menu` emits Buttons for SwiftUI `Menu`; `.rows` emits HStack rows for custom bottom sheets.
struct UserSafetyActions: View {
    let targetUIN: Int
    let targetNickname: String
    let context: String

    enum Style { case menu, rows }
    let style: Style

    @State private var showBlockConfirm: Bool = false
    @State private var showReportSheet: Bool = false
    @State private var blocking: Bool = false
    @State private var nowBlocked: Bool = false

    @StateObject private var contacts = ContactService.shared

    private var isBlocked: Bool {
        if nowBlocked { return true }
        return contacts.contacts.first(where: { $0.uin == targetUIN })?.blocked ?? false
    }

    var body: some View {
        Group {
            switch style {
            case .menu:
                // iOS 26 Menu re-tints Label icons to parent tint; use Image with .template to honor foregroundStyle.
                Button(role: .destructive) {
                    showBlockConfirm = true
                } label: {
                    Label {
                        Text((isBlocked ? "safety.unblock" : "safety.block").localized)
                    } icon: {
                        Image(systemName: isBlocked ? "hand.raised.slash" : "hand.raised.fill")
                            .renderingMode(.template)
                            .foregroundStyle(.red)
                    }
                }
                Button(role: .destructive) {
                    showReportSheet = true
                } label: {
                    Label {
                        Text("safety.report".localized)
                    } icon: {
                        Image(systemName: "exclamationmark.bubble")
                            .renderingMode(.template)
                            .foregroundStyle(.red)
                    }
                }
            case .rows:
                actionRow(
                    systemImage: isBlocked ? "hand.raised.slash" : "hand.raised.fill",
                    label: (isBlocked ? "safety.unblock" : "safety.block").localized,
                    destructive: true,
                    action: { showBlockConfirm = true }
                )
                actionRow(
                    systemImage: "exclamationmark.bubble",
                    label: "safety.report".localized,
                    destructive: true,
                    action: { showReportSheet = true }
                )
            }
        }
        .alert(
            (isBlocked ? "safety.unblock.confirm.title" : "safety.block.confirm.title").localized,
            isPresented: $showBlockConfirm
        ) {
            Button("common.cancel".localized, role: .cancel) {}
            Button(
                (isBlocked ? "safety.unblock" : "safety.block").localized,
                role: isBlocked ? .none : .destructive
            ) {
                Task { await toggleBlock() }
            }
        } message: {
            Text(String(
                format: (isBlocked
                    ? "safety.unblock.confirm.body"
                    : "safety.block.confirm.body").localized,
                targetNickname
            ))
        }
        .sheet(isPresented: $showReportSheet) {
            ReportContactSheet(
                targetUIN: targetUIN,
                targetNickname: targetNickname,
                context: context,
            )
        }
    }

    private func actionRow(
        systemImage: String,
        label: String,
        destructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let tint: Color = destructive ? Color.red : Theme.Color.textPrimary
        return Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundColor(tint)
                    .frame(width: 24)
                Text(label)
                    .font(.system(size: 16))
                    .foregroundColor(tint)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleBlock() async {
        guard !blocking else { return }
        blocking = true
        defer { blocking = false }
        do {
            try await contacts.toggleBlock(targetUIN)
            nowBlocked = !isBlocked
        } catch {
            // Silent on failure — state doesn't flip; user can re-tap.
        }
    }
}
