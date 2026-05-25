import Foundation
import UIKit

/// Main-app-only extension. `UIApplication.shared` is unavailable in
/// app extensions, so the icon-sync entry point lives in its own file
/// that the NSE target does not compile.
extension BadgeCounter {
    @MainActor
    static func syncIcon() {
        UIApplication.shared.applicationIconBadgeNumber = total()
    }
}
