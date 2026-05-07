import SwiftUI
import UIKit

/// Telegram-style long-press popover for a message, minus the background blur.
///
/// The screen behind stays visible (no scrim), only a transparent tap-catcher
/// dismisses on tap-outside. Two stacked panels appear in the centre:
///
///   ┌──────────────────────────────┐   reactions panel — animated KOLOBOK
///   │ 😀 😂 😯 😢 👍 ❤️             │   smileys, custom-styled (not a system
///   └──────────────────────────────┘   menu, since the system one can't show
///                                       animated GIFs).
///
///   ┌──────────────────────────────┐   actions panel — system-styled rows.
///   │ Delete            🗑  ›       │   For my own message, "Delete" reveals
///   └──────────────────────────────┘   a sub-state with "Delete for me" /
///                                       "Delete for everyone". For received
///                                       messages, the root row is already
///                                       "Delete for me" with no sub-state.
struct MessageActionOverlay: View {
    let message: Message
    /// Resolved by the parent (`ChatView`) via its
    /// `senderNickname(_:)` helper — for random chats this is
    /// already collapsed to "You" / "Stranger" so we surface a
    /// label that matches what the body sees, not the real
    /// account nickname.
    let senderNickname: String
    let canDeleteForEveryone: Bool
    let canReply: Bool
    /// True when this message is one we sent AND a text bubble (the
    /// only kind editable in v1). Caller decides; the overlay just
    /// reads the flag to gate the Edit row.
    let canEdit: Bool
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onEdit: () -> Void
    let onForward: () -> Void
    let onTranslate: () -> Void
    /// True when the host bubble is currently rendering a stored
    /// translation; flips the row label from "Translate" to "Show
    /// original" so the same tap reverts.
    var isTranslated: Bool = false
    let onDeleteForMe: () -> Void
    let onDeleteForEveryone: () -> Void
    let onDismiss: () -> Void
    /// Fired when the reporter taps "Report content" on a non-own
    /// media bubble. Caller (ChatView) opens `ReportEvidenceSheet`
    /// with the message + decrypted bytes attached. Optional —
    /// non-media surfaces don't surface the row at all.
    var onReport: (() -> Void)? = nil

    @State private var showDeleteSubmenu = false

    /// Six classic KOLOBOK reactions — same set as the picker row, animated.
    private static let assets: [String] = [
        "smile", "biggrin", "shok", "cray", "good", "heart",
    ]

    var body: some View {
        ZStack {
            // Material backdrop — same `.regularMaterial` glass we
            // use everywhere else for modal-ish overlays. Tap
            // anywhere outside the panels closes the menu.
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            // Reactions panel above, focused bubble preview in
            // the middle, actions panel below. The sender label
            // sits tight against the bubble (spacing 2) so the
            // pair reads as one unit "lifted" out of the chat.
            VStack(spacing: 10) {
                reactionsPanel
                VStack(alignment: message.isFromMe ? .trailing : .leading, spacing: 2) {
                    Text(senderNickname)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.Color.accent)
                    MessagePreviewCard(message: message)
                }
                // Wider cap so the lifted bubble can match its actual
                // chat-row width. 280pt was visibly clipping wrapped
                // text and made the 240pt photo bubble look pinched
                // (the surrounding frame was only 40pt wider than the
                // photo). 320pt fits both shapes without forcing a
                // wrap that the original row didn't have.
                .frame(maxWidth: 320, alignment: message.isFromMe ? .trailing : .leading)
                actionsPanel
                    .frame(width: 260)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        }
    }

    // MARK: - reactions

    private var reactionsPanel: some View {
        HStack(spacing: 2) {
            ForEach(Self.assets, id: \.self) { asset in
                Button {
                    onReact(asset)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onDismiss()
                } label: {
                    ZStack {
                        if message.reactions.values.contains(asset) {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Theme.Color.accent.opacity(0.3))
                        }
                        GIFImage(name: asset)
                            .frame(width: 30, height: 30)
                    }
                    .frame(width: 42, height: 42)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    // MARK: - actions

    private var actionsPanel: some View {
        VStack(spacing: 0) {
            if showDeleteSubmenu {
                actionRow("chat.action.delete_for_me".localized, icon: "trash", destructive: true) {
                    onDeleteForMe(); onDismiss()
                }
                rowDivider
                actionRow("chat.action.delete_for_everyone".localized, icon: "trash.fill", destructive: true) {
                    onDeleteForEveryone(); onDismiss()
                }
            } else {
                if canReply && canForward {
                    actionRow("chat.action.reply".localized, icon: "arrowshape.turn.up.left", destructive: false) {
                        onReply(); onDismiss()
                    }
                    rowDivider
                }
                if canEdit {
                    actionRow("chat.action.edit".localized, icon: "pencil", destructive: false) {
                        onEdit(); onDismiss()
                    }
                    rowDivider
                }
                if canForward, message.kind == .text, !message.text.isEmpty {
                    actionRow("chat.action.copy".localized, icon: "doc.on.doc", destructive: false) {
                        UIPasteboard.general.string = message.text
                        UISelectionFeedbackGenerator().selectionChanged()
                        onDismiss()
                    }
                    rowDivider
                    // In-place translation toggle. First tap kicks
                    // the iOS 18 TranslationSession in the host
                    // chat's `InPlaceTranslator` modifier and writes
                    // the result into `vm.translatedTexts`, swapping
                    // the bubble's text. Second tap (label now reads
                    // "Show original") clears the cache entry and
                    // reverts. No modal sheet, no Apple "Open in
                    // Translate" hand-off.
                    actionRow(
                        (isTranslated ? "chat.action.show_original" : "chat.action.translate").localized,
                        icon: "globe",
                        destructive: false
                    ) {
                        onTranslate(); onDismiss()
                    }
                    rowDivider
                }
                if canForward {
                    actionRow("chat.action.forward".localized, icon: "arrowshape.turn.up.right", destructive: false) {
                        onForward(); onDismiss()
                    }
                    rowDivider
                }
                // Report content — only for media bubbles received from
                // someone else. Caller (ChatView) wires this up only
                // when the message kind is .photo / .video / .premiumPhoto
                // / .premiumVideo AND the local user has unlocked /
                // viewed it (i.e. plaintext bytes are obtainable for
                // upload as evidence).
                if let onReport, !canDeleteForEveryone {
                    actionRow(
                        "chat.action.report_content".localized,
                        icon: "exclamationmark.bubble",
                        destructive: true
                    ) {
                        onReport(); onDismiss()
                    }
                    rowDivider
                }
                if canDeleteForEveryone {
                    actionRow("chat.action.delete".localized, icon: "trash", destructive: true) {
                        withAnimation(.easeInOut(duration: 0.2)) { showDeleteSubmenu = true }
                    }
                } else {
                    actionRow("chat.action.delete_for_me".localized, icon: "trash", destructive: true) {
                        onDeleteForMe(); onDismiss()
                    }
                }
            }
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }

    /// Hairline separator between rows — matches iOS system menu
    /// styling (~0.33pt, low-contrast, tinted to the panel material).
    private var rowDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.33)
    }

    /// Forward only makes sense for actual content. Hide for
    /// already-tombstoned messages, system notices, and offline
    /// markers — there's nothing meaningful to re-send.
    private var canForward: Bool {
        if message.deletedForEveryone { return false }
        switch message.kind {
        case .text, .photo, .video: return true
        default: return false
        }
    }

    /// Telegram / iOS-system-menu row layout: icon **on the left**
    /// (fixed-width column for vertical alignment of all rows), text
    /// after the icon, no right-side glyph. Destructive role tints
    /// both icon and label red. Layout hugs iOS's native
    /// `UIMenu`/`UIAction` row dimensions so the overlay reads as
    /// system-style without us actually using the system menu API.
    private func actionRow(
        _ title: String,
        icon: String?,
        destructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let tint: Color = destructive ? Color.red : Theme.Color.textPrimary
        return Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundColor(tint)
                        .frame(width: 22, alignment: .center)
                }
                Text(title)
                    .font(.system(size: 16))
                    .foregroundColor(tint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Material-blur background to match the iOS native context
    /// menu look. `.regularMaterial` adapts to dark/light mode out
    /// of the box and gives the same translucent backdrop the system
    /// menu uses on top of the dimmed chat.
    private var panelBackground: some View {
        Rectangle().fill(.regularMaterial)
    }
}
