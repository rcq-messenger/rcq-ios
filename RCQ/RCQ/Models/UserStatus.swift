import SwiftUI

enum UserStatus: String, CaseIterable, Codable, Hashable, Identifiable {
    case online
    case away
    case dnd
    case invisible
    case offline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .online: return "status.online".localized
        case .away: return "status.away".localized
        case .dnd: return "status.dnd".localized
        case .invisible: return "status.invisible".localized
        case .offline: return "status.offline".localized
        }
    }

    var color: Color {
        switch self {
        case .online: return Theme.Color.statusOnline
        case .away: return Theme.Color.statusAway
        case .dnd: return Theme.Color.statusBusy
        case .invisible: return Theme.Color.statusInvisible
        case .offline: return Theme.Color.statusOffline
        }
    }

    /// What other contacts see — invisible looks like offline to them.
    var asVisible: UserStatus {
        self == .invisible ? .offline : self
    }
}
