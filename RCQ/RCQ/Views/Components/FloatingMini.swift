import SwiftUI

/// Free-floating draggable container for a game mini-bubble.
/// Drag to reposition, snap to nearest edge on release, fling past
/// the edge to dock with a peek tab. Position persists to UserDefaults.
struct FloatingMini<Content: View>: View {
    let storageKey: String
    let initialPosition: CGPoint
    let bubbleSize: CGSize
    var peekWidth: CGFloat = 28
    @ViewBuilder var content: () -> Content

    @State private var position: CGPoint
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false
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

    private func clampedDragX(_ x: CGFloat, in size: CGSize) -> CGFloat {
        let halfW = bubbleSize.width / 2
        return max(-halfW + peekWidth, min(size.width + halfW - peekWidth, x))
    }

    private func clampedDragY(_ y: CGFloat, in size: CGSize) -> CGFloat {
        return clampedY(y, in: size)
    }

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
                        dockedEdge = e
                        position = CGPoint(x: position.x, y: clampedY(predicted.y, in: size))
                    } else {
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
