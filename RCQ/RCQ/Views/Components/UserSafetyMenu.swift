import SwiftUI

/// Shared Block + Report actions that drop into any per-user surface
/// (profile menu, chat header menu, group member sheet, audio-room
/// quick-actions sheet, story viewer non-owner menu, ...).
///
/// Why a shared component
/// ----------------------
/// Apple's App Review (Guideline 1.2 — UGC) expects "block abusive
/// users" to be reachable from every surface where one user can
/// surface another's content. Wiring it once and dropping the same
/// component in keeps the UX consistent + removes the temptation to
/// skip a surface "because it's tedious to wire". Each surface passes
/// its own `context` string — admin uses it to triage.
///
/// Two presentation modes
/// ----------------------
///   • `.menu`  — emits two `Button`s suitable for inside a SwiftUI
///                `Menu { ... }` (toolbar ellipsis, profile menu).
///   • `.rows`  — emits two HStack rows suitable for inside a custom
///                bottom sheet (audio-room QuickActionsSheet etc).
///
/// Both modes drive the same state: a Block confirmation alert (so
/// the action isn't fired by an accidental tap) + a Report sheet.
struct UserSafetyActions: View {
    let targetUIN: Int
    let targetNickname: String
    /// Surface tag for the report row's `context` column. Used by the
    /// admin to triage by where the report came from.
    let context: String

    enum Style { case menu, rows }
    let style: Style

    @State private var showBlockConfirm: Bool = false
    @State private var showReportSheet: Bool = false
    @State private var blocking: Bool = false
    @State private var nowBlocked: Bool = false

    /// Cached lookup of "is this user already blocked" so we can
    /// flip the label between "Block" and "Unblock". Re-evaluated
    /// after any successful block toggle.
    @StateObject private var contacts = ContactService.shared

    private var isBlocked: Bool {
        if nowBlocked { return true }
        return contacts.contacts.first(where: { $0.uin == targetUIN })?.blocked ?? false
    }

    var body: some View {
        Group {
            switch style {
            case .menu:
                // Both Block and Report are destructive so the text
                // rendered by the system menu is red. iOS 26 ignores
                // `.foregroundStyle(.red)` on `Label` content inside
                // a `Menu` body — the system Menu template re-tints
                // SF Symbols to the parent tint (the chat's accent
                // green), which is why the icons looked green even
                // with the destructive role + explicit red style.
                // The reliable workaround is to use a SwiftUI
                // `Image(systemName:)` rendered with the
                // `.palette` rendering mode, which forces the
                // symbol to honor the foreground style.
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
                // Sheet rows render with explicit red tint via the
                // `destructive` flag — both Block AND Report are
                // unconditionally destructive so the icon + text
                // both sit in red.
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

    /// Sheet-style action row. Same look as the existing actionRow
    /// helper inside AudioRoomQuickActionsSheet so the two surfaces
    /// feel uniform when they sit side by side.
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
            // Optimistic local flip — ContactService refresh will
            // re-derive the canonical value next pass anyway.
            nowBlocked = !isBlocked
        } catch {
            // Silent on failure — the state simply doesn't flip.
            // Could surface a toast in a follow-up; for v1 the user
            // can re-tap and the confirmation alert appears again.
        }
    }
}
