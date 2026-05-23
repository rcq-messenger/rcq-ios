import SwiftUI

/// Full-screen avatar preview with pinch-zoom and swipe-to-dismiss.
struct FullScreenAvatarView: View {
    let mediaID: String?
    let keyBase64: String?

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var gifData: Data?
    @State private var dragOffset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1.0
    @State private var committedScale: CGFloat = 1.0

    private var scale: CGFloat {
        max(1.0, committedScale * pinch)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let gifData {
                AnimatedGIFView(data: gifData, contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(dragOffset)
                    .gesture(
                        MagnificationGesture()
                            .updating($pinch) { value, state, _ in state = value }
                            .onEnded { value in
                                committedScale = max(1.0, committedScale * value)
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { v in
                                guard scale <= 1.01 else { return }
                                dragOffset = CGSize(width: 0, height: max(0, v.translation.height))
                            }
                            .onEnded { v in
                                if scale <= 1.01 && v.translation.height > 120 {
                                    dismiss()
                                } else {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        dragOffset = .zero
                                    }
                                }
                            }
                    )
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(dragOffset)
                    .gesture(
                        MagnificationGesture()
                            .updating($pinch) { value, state, _ in state = value }
                            .onEnded { value in
                                committedScale = max(1.0, committedScale * value)
                            }
                    )
                    .simultaneousGesture(
                        // Swipe-down dismiss; suppressed while zoomed.
                        DragGesture()
                            .onChanged { v in
                                guard scale <= 1.01 else { return }
                                dragOffset = CGSize(width: 0, height: max(0, v.translation.height))
                            }
                            .onEnded { v in
                                if scale <= 1.01 && v.translation.height > 120 {
                                    dismiss()
                                } else {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        dragOffset = .zero
                                    }
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            committedScale = committedScale > 1.01 ? 1.0 : 2.0
                        }
                    }
            } else {
                ProgressView().tint(.white)
            }
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
        }
        .task(id: cacheKey) { await load() }
    }

    private var cacheKey: String {
        "\(mediaID ?? "")|\(keyBase64 ?? "")"
    }

    private func load() async {
        guard let id = mediaID, !id.isEmpty,
              let key = keyBase64, !key.isEmpty else {
            image = nil
            gifData = nil
            return
        }
        if let pair = await MediaService.shared.loadImageWithData(mediaID: id, keyBase64: key) {
            image = pair.0
            gifData = AnimatedGIFView.isGIF(pair.1) ? pair.1 : nil
        }
    }
}
