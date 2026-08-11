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
    let isVideo: [Bool]

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int
    @State private var shareItem: IdentifiableURL?
    @State private var dragDown: CGFloat = 0

    private let dismissThreshold: CGFloat = 120

    init(urls: [String], isVideo: [Bool] = [], startIndex: Int = 0) {
        self.urls = urls
        self.isVideo = isVideo
        _selection = State(initialValue: max(0, min(startIndex, max(0, urls.count - 1))))
    }

    /// Convenience for a single image (keeps existing call sites working).
    init(imageUrl: String) {
        self.init(urls: [imageUrl], startIndex: 0)
    }

    /// Authoritative video flag (from media_type), falling back to the URL
    /// extension for legacy call sites that don't pass the flags.
    private func isVideoItem(_ index: Int, _ url: String) -> Bool {
        index >= 0 && index < isVideo.count ? isVideo[index] : url.isVideoURL
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(urls.enumerated()), id: \.offset) { idx, url in
                    Group {
                        if isVideoItem(idx, url), let u = env.mediaTokenService.url(url) {
                            VideoPage(url: u)
                        } else if let u = env.mediaTokenService.url(url) {
                            ZoomableImage(url: u)
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
            .offset(y: dragDown)

            controls
        }
        .statusBarHidden()
        // Swipe-down-to-dismiss on the outer ZStack using simultaneousGesture so
        // TabView's horizontal page swipe is never blocked.
        .simultaneousGesture(swipeDownToDismiss)
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    /// Fires only on clear downward drags; horizontal swipes pass through to TabView.
    private var swipeDownToDismiss: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) * 1.5 else { return }
                dragDown = value.translation.height
            }
            .onEnded { value in
                if dragDown > dismissThreshold || value.predictedEndTranslation.height > dismissThreshold * 1.5 {
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.3)) { dragDown = 0 }
                }
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
                if selection < urls.count, let u = env.mediaTokenService.url(urls[selection]) {
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

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            KFImage(url)
                .fade(duration: 0.2)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(x: offset.width, y: offset.height)
                .highPriorityGesture(magnification(geo))
                // simultaneousGesture: TabView keeps receiving horizontal swipes at
                // scale=1; onChanged guards on scale>1 so nothing moves unless zoomed.
                .simultaneousGesture(panGesture(geo))
                .onTapGesture(count: 2) { toggleZoom() }
                .animation(.interactiveSpring(response: 0.3), value: scale)
                .animation(.interactiveSpring(response: 0.3), value: offset)
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

    private func panGesture(_ geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in
                guard scale > 1 else { return }
                clamp(geo)
                lastOffset = offset
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
