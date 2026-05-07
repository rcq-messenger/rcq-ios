import SwiftUI

/// Free-floating draggable container for a game mini-bubble.
/// Lives at app root in a global ZStack so it persists across
/// navigation pushes / dismisses (NavigationStack and tab swaps
/// don't tear it down, the way a top-`safeAreaInset` mini does).
///
/// Behaviour:
/// - **Drag anywhere** to move the bubble. The container clamps
///   the position so the bubble can't be pushed entirely off
///   the visible area unless the user explicitly docks it.
/// - **Snap to edge** on release: the bubble lands with one of
///   its sides flush to the nearest horizontal screen edge,
///   vertical position preserved within bounds. Velocity-based
///   `predictedEndTranslation` is honoured so a fling toward an
///   edge always lands there even if the finger let go mid-screen.
/// - **Peek-from-edge**: when dragged off-screen past a small
///   threshold, the bubble docks with only ~28pt visible past
///   the edge. Tap the visible peek to pull it back on-screen;
///   another drag re-docks. The leading icon of each game's
///   bubble (rocket / hammer) is always the visible bit, so the
///   user knows what's hiding there.
/// - **Position persists** to UserDefaults under `storageKey`
///   so the user's preferred docking spot survives app
///   restarts and round transitions.
///
/// Two minis can be active simultaneously (Crash + Auction) and
/// the host stacks them vertically when their snapped positions
/// would otherwise overlap.
struct FloatingMini<Content: View>: View {
    /// Distinct UserDefaults bucket per mini type so Crash and
    /// Auction don't fight over the same persisted x/y.
    let storageKey: String
    /// Initial spot when no persisted value exists. Typically
    /// `(screenWidth - 80, screenHeight - 200)` so a fresh user
    /// finds the bubble in the lower-right.
    let initialPosition: CGPoint
    /// Card dimensions — drives bounds clamping + snap-edge math.
    let bubbleSize: CGSize
    /// Number of points of the docked bubble that remain visible
    /// past the edge (the "peek tab"). 28pt comfortably shows the
    /// bubble's leading SF Symbol icon.
    var peekWidth: CGFloat = 28
    @ViewBuilder var content: () -> Content

    @State private var position: CGPoint
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false
    /// True once the user flicked the bubble past an edge — peek
    /// tab visible only. Cleared by a tap or a fresh inward drag.
    @State private var dockedEdge: Edge?

    private enum Edge { case leading, trailing }

    init(
        storageKey: String,
        initialPosition: CGPoint,
        bubbleSize: CGSize,
        peekWidth: CGFloat = 28,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.storageKey = storageKey
        self.initialPosition = initialPosition
        self.bubbleSize = bubbleSize
        self.peekWidth = peekWidth
        self.content = content
        let stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: CGFloat]
        let p = CGPoint(
            x: stored?["x"] ?? initialPosition.x,
            y: stored?["y"] ?? initialPosition.y
        )
        _position = State(initialValue: p)
    }

    var body: some View {
        GeometryReader { geo in
            content()
                .frame(width: bubbleSize.width, height: bubbleSize.height)
                .scaleEffect(isDragging ? 1.05 : 1.0)
                .shadow(color: .black.opacity(0.25), radius: isDragging ? 18 : 10, y: isDragging ? 8 : 4)
                .position(displayPosition(in: geo.size))
                .gesture(dragGesture(in: geo.size))
                .onTapGesture {
                    // Tap on a docked peek — un-dock + animate the
                    // bubble back to its full on-screen edge spot.
                    if dockedEdge != nil {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                            position = onScreenEdgeAnchor(for: dockedEdge!, in: geo.size)
                            dockedEdge = nil
                        }
                        persist()
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.78), value: dockedEdge)
                .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isDragging)
        }
        .ignoresSafeArea(.keyboard)
    }

    // MARK: - Position math

    /// Where to draw the bubble right now — accounts for live drag
    /// translation and the docked-peek-past-edge offset.
    private func displayPosition(in size: CGSize) -> CGPoint {
        if let edge = dockedEdge, !isDragging {
            return dockedPosition(for: edge, in: size, baseY: position.y)
        }
        let liveX = position.x + dragOffset.width
        let liveY = position.y + dragOffset.height
        return CGPoint(
            x: clampedDragX(liveX, in: size),
            y: clampedDragY(liveY, in: size)
        )
    }

    private func dockedPosition(for edge: Edge, in size: CGSize, baseY: CGFloat) -> CGPoint {
        let halfW = bubbleSize.width / 2
        let visibleX: CGFloat
        switch edge {
        case .leading:  visibleX = -halfW + peekWidth
        case .trailing: visibleX = size.width + halfW - peekWidth
        }
        return CGPoint(x: visibleX, y: clampedY(baseY, in: size))
    }

    private func onScreenEdgeAnchor(for edge: Edge, in size: CGSize) -> CGPoint {
        let halfW = bubbleSize.width / 2
        let pad: CGFloat = 8
        switch edge {
        case .leading:  return CGPoint(x: halfW + pad, y: clampedY(position.y, in: size))
        case .trailing: return CGPoint(x: size.width - halfW - pad, y: clampedY(position.y, in: size))
        }
    }

    /// Clamp during drag — allow the bubble to be dragged a bit
    /// past the edge (so the user feels it pulling out) but not
    /// so far that the whole thing disappears mid-drag.
    private func clampedDragX(_ x: CGFloat, in size: CGSize) -> CGFloat {
        let halfW = bubbleSize.width / 2
        // Allow ~half the bubble to overshoot in either direction
        // while dragging — visually pleasing "pulling past edge".
        return max(-halfW + peekWidth, min(size.width + halfW - peekWidth, x))
    }

    private func clampedDragY(_ y: CGFloat, in size: CGSize) -> CGFloat {
        return clampedY(y, in: size)
    }

    /// Y-clamp leaves room for top/bottom safe areas + bars so the
    /// bubble doesn't end up under a status bar or home indicator.
    private func clampedY(_ y: CGFloat, in size: CGSize) -> CGFloat {
        let halfH = bubbleSize.height / 2
        let topPad: CGFloat = 80   // status bar + nav bar comfort
        let bottomPad: CGFloat = 100 // home indicator + tab/composer comfort
        return max(halfH + topPad, min(size.height - halfH - bottomPad, y))
    }

    // MARK: - Gesture

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
                // While dragging, un-dock implicitly so the bubble
                // follows the finger fully.
                if dockedEdge != nil {
                    let baseX = onScreenEdgeAnchor(for: dockedEdge!, in: size).x
                    position = CGPoint(x: baseX, y: position.y)
                    dockedEdge = nil
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                let predicted = CGPoint(
                    x: position.x + value.predictedEndTranslation.width,
                    y: position.y + value.predictedEndTranslation.height
                )
                let halfW = bubbleSize.width / 2
                let dockThreshold: CGFloat = halfW * 0.4
                let edge: Edge?
                if predicted.x < dockThreshold {
                    edge = .leading
                } else if predicted.x > size.width - dockThreshold {
                    edge = .trailing
                } else {
                    edge = nil
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                    if let e = edge {
                        // Past the threshold — dock to that edge.
                        dockedEdge = e
                        position = CGPoint(x: position.x, y: clampedY(predicted.y, in: size))
                    } else {
                        // Snap to the closer edge but stay fully
                        // on-screen (no peek) — the standard PiP
                        // behaviour for short drags.
                        let snapEdge: Edge = predicted.x < size.width / 2 ? .leading : .trailing
                        dockedEdge = nil
                        position = onScreenEdgeAnchor(for: snapEdge, in: size)
                        position = CGPoint(x: position.x, y: clampedY(predicted.y, in: size))
                    }
                    dragOffset = .zero
                    isDragging = false
                }
                persist()
            }
    }

    // MARK: - Persistence

    private func persist() {
        UserDefaults.standard.set(
            ["x": position.x, "y": position.y],
            forKey: storageKey
        )
    }
}
