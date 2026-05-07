import SwiftUI

struct StatusDot: View {
    let status: UserStatus
    var size: CGFloat = Theme.Metrics.statusDot

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .overlay(
                Circle().stroke(Color.black.opacity(0.4), lineWidth: 0.5)
            )
    }
}
