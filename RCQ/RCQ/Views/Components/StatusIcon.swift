import SwiftUI

/// PNG status icon from the RCQ in-house status set (replaces the
/// original ICQ5 set we shipped with at launch). Falls back to a
/// colored dot if the asset is missing (e.g. dev builds without
/// the pack copied in).
struct StatusIcon: View {
    let status: UserStatus
    var size: CGFloat = 14

    var body: some View {
        if let ui = UIImage(named: assetName) {
            Image(uiImage: ui)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            StatusDot(status: status, size: max(8, size * 0.7))
        }
    }

    private var assetName: String {
        switch status {
        case .online: return "status_online"
        case .away: return "status_away"
        case .dnd: return "status_dnd"
        case .invisible: return "status_invisible"
        case .offline: return "status_offline"
        }
    }
}
