import SwiftUI

/// Bottom-sheet attachment picker for the chat composer. Replaces
/// the previous `.confirmationDialog` which on iOS 26 occasionally
/// anchored as a popover ABOVE the paperclip button (small source
/// view → popover heuristic) instead of as the bottom action
/// sheet. A real `.sheet` with a fixed-height detent always rises
/// from the bottom edge — same affordance as iMessage's `+` menu.
struct AttachmentPickerSheet: View {
    let isRandom: Bool
    /// Hide the Premium row even outside random chat — used in groups
    /// where only the owner can post paid content.
    var premiumDisabled: Bool = false
    /// Combined photo+video gallery picker — replaces the prior split
    /// "Photo" / "Video" rows. Single row reads cleaner and matches
    /// the system Photos picker which itself shows both kinds.
    let onMedia: () -> Void
    let onCamera: () -> Void
    let onPremium: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.title) { row in
                Button(action: row.action) {
                    HStack(spacing: 14) {
                        Image(systemName: row.icon)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Theme.Color.accent)
                            .frame(width: 32, alignment: .center)
                        Text(row.title)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.Color.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if row.title != rows.last?.title {
                    Divider().padding(.leading, 64)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
    }

    private var rows: [Row] {
        var items: [Row] = [
            Row(
                title: "chat.attach.gallery".localized,
                icon: "photo.on.rectangle.angled",
                action: onMedia
            ),
            Row(
                title: "chat.attach.camera".localized,
                icon: "camera",
                action: onCamera
            ),
        ]
        if !isRandom && !premiumDisabled {
            items.append(Row(
                title: "chat.attach.premium".localized,
                icon: "lock.fill",
                action: onPremium
            ))
        }
        return items
    }

    private struct Row {
        let title: String
        let icon: String
        let action: () -> Void
    }
}
