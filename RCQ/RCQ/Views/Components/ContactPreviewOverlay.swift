import SwiftUI
import UIKit

/// Telegram-style long-press preview for a contact list row.
///
/// Why we don't use SwiftUI's `.contextMenu(menuItems:preview:)`:
/// - The system slot wobbles under finger pressure (iOS rubber-band).
/// - It does NOT pass scroll gestures to the preview content (a
///   long-standing SwiftUI limitation), so a scrollable chat history
///   preview just sat motionless.
/// - Position is auto-anchored next to the source row, not centered.
///
/// This overlay matches the Telegram contract: fixed-centred preview
/// card with a real `ScrollView` inside (because we're rendering inside
/// a normal SwiftUI parent now, not the static contextMenu slot), an
/// action list directly below, and a tap-outside-to-dismiss material
/// scrim. Stays put when touched. Scrolls. Sibling of the in-chat
/// `MessageActionOverlay`, same construction.
struct ContactPreviewOverlay: View {
    let target: ChatTarget
    let actions: [ContextAction]
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }
                // Cap the preview card so the card + the full action list
                // fit within the safe area. On a short screen (iPhone SE)
                // the fixed 520pt card pushed the last actions (Block /
                // Report / Remove) off the bottom, unreachable. Reserve room
                // for the action list (~52pt per row) + spacing, then let the
                // whole column scroll if it still overflows so every action
                // is always reachable.
                let reservedForActions = CGFloat(actions.count) * 52 + 40
                let previewCap = max(200, geo.size.height - reservedForActions)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        // The cap goes INTO the card, not around it: capping
                        // from here made the card a flexible view that this
                        // stack then stretched to the full cap, so the rounding
                        // curved a rectangle much taller than the card and the
                        // card itself stayed square. The card owns its shape.
                        ChatPreviewView(target: target, compact: true, maxHeight: previewCap)
                            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                        actionList
                    }
                    .padding(.vertical, 16)
                    // Center the column when it's shorter than the screen,
                    // scroll when it's taller.
                    .frame(minHeight: geo.size.height)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .center)))
            }
        }
    }

    private var actionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { idx, action in
                actionRow(action)
                if idx < actions.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.33)
                }
            }
        }
        .background(Rectangle().fill(.regularMaterial))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .frame(width: 260)
    }

    @ViewBuilder
    private func actionRow(_ action: ContextAction) -> some View {
        let tint: Color = action.destructive ? .red : Theme.Color.textPrimary
        Button {
            action.handler()
            UISelectionFeedbackGenerator().selectionChanged()
            onDismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(tint)
                    .frame(width: 22, alignment: .center)
                Text(action.title)
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
}

/// One entry in a `ContactPreviewOverlay` action list. Mirrors a
/// `UIAction`'s shape (title + icon + destructive flag + handler) so
/// the call sites read like building a system menu — but rendered
/// through pure SwiftUI for the overlay path.
struct ContextAction: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let destructive: Bool
    let handler: () -> Void

    init(
        title: String,
        systemImage: String,
        destructive: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.destructive = destructive
        self.handler = handler
    }
}
