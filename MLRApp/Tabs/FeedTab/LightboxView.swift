import SwiftUI
import AVKit
import Kingfisher

// MARK: - LightboxView
// Full-screen media viewer presented over the feed.
//
// Features:
//   • Multi-item carousel (swipe between a post's photos/videos)
//   • Photos: pinch-to-zoom (1×–5×) with pan clamped to bounds, double-tap to
//     toggle zoom, swipe-down to dismiss (only at 1×)
//   • Videos: native AVKit VideoPlayer with transport controls
//   • Kingfisher-cached images (no redundant re-download)
//   • Close (top-left) + Share current item (top-right)

struct LightboxView: View {
    let urls: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int
    @State private var shareItem: IdentifiableURL?

    init(urls: [String], startIndex: Int = 0) {
        self.urls = urls
        _selection = State(initialValue: max(0, min(startIndex, max(0, urls.count - 1))))
    }

    /// Convenience for a single image (keeps existing call sites working).
    init(imageUrl: String) {
        self.init(urls: [imageUrl], startIndex: 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(urls.enumerated()), id: \.offset) { idx, url in
                    Group {
                        if url.isVideoURL, let u = URL(string: url) {
                            VideoPage(url: u)
                        } else if let u = URL(string: url) {
                            ZoomableImage(url: u) { dismiss() }
                        } else {
                            Image(systemName: "photo.slash")
                                .font(.mlrScaled(44))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .automatic : .never))

            controls
        }
        .statusBarHidden()
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.mlrScaled(28))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(16)
                }
                Spacer()
                if selection < urls.count, let u = URL(string: urls[selection]) {
                    Button { shareItem = IdentifiableURL(url: u) } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.mlrScaled(22))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(16)
                    }
                }
            }
            Spacer()
        }
    }
}

// MARK: - Zoomable image page

private struct ZoomableImage: View {
    let url: URL
    var onDismiss: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragDown: CGFloat = 0

    private let maxScale: CGFloat = 5
    private let dismissThreshold: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            KFImage(url)
                .fade(duration: 0.2)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(x: offset.width, y: offset.height + dragDown)
                .highPriorityGesture(magnification(geo))
                .gesture(panOrDismiss(geo))
                .onTapGesture(count: 2) { toggleZoom() }
                .animation(.interactiveSpring(response: 0.3), value: scale)
                .animation(.interactiveSpring(response: 0.3), value: offset)
                .animation(.interactiveSpring(response: 0.3), value: dragDown)
        }
    }

    private func magnification(_ geo: GeometryProxy) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(maxScale, max(1, lastScale * value))
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { resetZoom() } else { clamp(geo) }
            }
    }

    private func panOrDismiss(_ geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if scale <= 1 {
                    dragDown = max(0, value.translation.height)   // swipe-down only
                } else {
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                }
            }
            .onEnded { value in
                if scale <= 1 {
                    if dragDown > dismissThreshold || value.predictedEndTranslation.height > dismissThreshold * 1.5 {
                        onDismiss()
                    } else {
                        dragDown = 0
                    }
                } else {
                    clamp(geo)
                    lastOffset = offset
                }
            }
    }

    private func toggleZoom() {
        if scale > 1 { resetZoom() } else { scale = 2.5; lastScale = 2.5 }
    }

    private func resetZoom() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
    }

    /// Keep the panned image within its scaled bounds so it can't fly off-screen.
    private func clamp(_ geo: GeometryProxy) {
        let maxX = max(0, geo.size.width  * (scale - 1) / 2)
        let maxY = max(0, geo.size.height * (scale - 1) / 2)
        offset = CGSize(width: min(maxX, max(-maxX, offset.width)),
                        height: min(maxY, max(-maxY, offset.height)))
    }
}

// MARK: - Video page

private struct VideoPage: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                if player == nil { player = AVPlayer(url: url) }
                player?.play()
            }
            .onDisappear { player?.pause() }
    }
}

// MARK: - Helpers

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - ShareSheet
// UIActivityViewController wrapper.

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
