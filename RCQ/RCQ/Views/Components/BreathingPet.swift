import SwiftUI

/// Subtle scale-breath modifier for pet renders. Time-driven via
/// TimelineView so it survives LazyVGrid cell recycling without
/// @State weirdness — identical pets on screen breathe in sync.
struct BreathingPet: ViewModifier {
    var amplitude: CGFloat = 0.04
    var period: TimeInterval = 1.8

    func body(content: Content) -> some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSince1970
            let phase = sin(t * 2 * .pi / period)
            let scale = 1.0 + CGFloat(phase) * amplitude
            content.scaleEffect(scale)
        }
    }
}

extension View {
    func breathingPet(amplitude: CGFloat = 0.04, period: TimeInterval = 1.8) -> some View {
        modifier(BreathingPet(amplitude: amplitude, period: period))
    }
}

/// Conditional breath — apply only when the host knows the item is a pet.
struct PetBreathIf: ViewModifier {
    let active: Bool
    init(_ active: Bool) { self.active = active }
    func body(content: Content) -> some View {
        if active { content.breathingPet() } else { content }
    }
}
