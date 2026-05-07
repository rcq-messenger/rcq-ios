import SwiftUI

/// Stand-in flat-color avatar derived from the UIN. Will be replaced by uploaded images.
struct Avatar: View {
    let uin: Int
    let nickname: String
    var size: CGFloat = Theme.Metrics.avatarMd

    private var seedColor: Color {
        let palette: [UInt32] = [0x4FA3E3, 0xF26B6B, 0x6BBE6B, 0xE0A53A, 0xA479D9, 0x57C7BC, 0xE2769B]
        return Color(hex: palette[abs(uin) % palette.count])
    }

    private var initial: String {
        nickname.first.map(String.init)?.uppercased() ?? "?"
    }

    var body: some View {
        ZStack {
            Circle().fill(seedColor)
            Text(initial)
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}
