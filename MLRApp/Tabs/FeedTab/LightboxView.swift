import SwiftUI
import AVKit
import Kingfisher

// MARK: - LightboxView
// Full-screen media viewer presented over the feed, comments, drop-box albums,
// work items and fest photos — the one canonical viewer, so a fix here reaches
// every surface.
//
// Features:
//   • Multi-item carousel — swipe anywhere ON THE PHOTO to go to the next one,
//     the way Apple Photos and every other photo app behaves
//   • Photos: pinch-to-zoom (1×–5×), pan while zoomed, double-tap to toggle
//   • Videos: native AVKit VideoPlayer with transport controls
//   • Kingfisher-cached images (no redundant re-download)
//   • Close (top-left) + Share current item (top-right)
//
// ⚠️⚠️ WHY THE ZOOM IS A UIScrollView AND NOT SwiftUI GESTURES.
//
// This started as a SwiftUI `MagnificationGesture` + `DragGesture` pair on the
// page content, and it broke paging: swiping the photo itself did nothing, and
// only the page-indicator dots (which sit OUTSIDE the page content) would move
// between photos. A SwiftUI gesture attached to a `TabView(.page)` page claims
// the touch sequence before the TabView's own scroll view can begin its pan —
// via .gesture / .simultaneousGesture / .highPriorityGesture alike. Attaching
// the pan only while zoomed worked around half of it; the magnification gesture
// still swallowed swipes at rest.
//
// A UIScrollView doesn't have that problem, because UIKit recognizers actually
// negotiate: when the content fits (zoomScale == 1) the inner pan FAILS and the
// parent pager gets the swipe, and once zoomed the inner pan wins until you hit
// a content edge. That's exactly the nesting Photos itself uses.
//
// ⚠️ `alwaysBounceHorizontal/Vertical` MUST stay false. With bouncing on, the
// inner scroll view's pan recognizer claims the gesture even when there's
// nothing to scroll — which reintroduces the original bug in a subtler form
// (the photo jiggles and the page never turns).

struct LightboxView: View {
    let urls: [String]
    let isVideo: [Bool]

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int
    @State private var shareItem: IdentifiableURL?

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
                            // `isCurrent` resets the zoom on a page you've
                            // swiped away from, so coming back to it doesn't
                            // land you still zoomed into a corner.
                            ZoomableImage(url: u, isCurrent: selection == idx)
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
                if urls.count > 1 {
                    Text("\(min(selection + 1, urls.count)) of \(urls.count)")
                        .font(.mlrScaled(13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityLabel("Photo \(selection + 1) of \(urls.count)")
                }
                Spacer()
                if selection < urls.count, let u = env.mediaTokenService.url(urls[selection]) {
                    Button { shareItem = IdentifiableURL(url: u) } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.mlrScaled(22))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(16)
                    }
                } else {
                    // Balances the ✕ so the counter stays centred.
                    Color.clear.frame(width: 54, height: 1)
                }
            }
            Spacer()
        }
    }
}

// MARK: - Zoomable image page (UIScrollView-backed)

private struct ZoomableImage: UIViewRepresentable {
    let url: URL
    /// False for a page that's been swiped away from — see the reset below.
    let isCurrent: Bool

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        let view = ZoomableImageScrollView()
        view.load(url)
        return view
    }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        view.load(url)
        if !isCurrent { view.resetZoom(animated: false) }
    }
}

/// A UIScrollView that zooms a single image and centres it.
///
/// Deliberately a UIScrollView subclass rather than a coordinator juggling
/// frames: laying the image out in `layoutSubviews` is the only place that
/// reliably knows the final bounds, and getting that wrong is what makes a
/// zoomable image drift off-centre after a rotation.
final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {

    private let imageView = UIImageView()
    private var loadedURL: URL?
    private var lastSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)

        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .clear
        contentInsetAdjustmentBehavior = .never
        // ⚠️ Both false — see the warning at the top of the file. With bouncing
        // on, this scroll view's pan claims swipes it has no way to act on and
        // the parent pager never turns the page.
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        resetZoom(animated: false)
        imageView.kf.setImage(with: url, options: [.transition(.fade(0.2))])
    }

    func resetZoom(animated: Bool) {
        guard zoomScale != minimumZoomScale else { return }
        setZoomScale(minimumZoomScale, animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Only re-lay the image when the bounds actually change. Doing it on
        // every pass would stomp the transform UIScrollView applies while
        // zooming, snapping the photo back to 1× mid-pinch.
        if bounds.size != lastSize {
            lastSize = bounds.size
            zoomScale = minimumZoomScale
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
        centerImage()
    }

    /// Keep the image centred when it's smaller than the viewport — otherwise a
    /// zoomed-out photo sits in the top-left corner.
    private func centerImage() {
        var frame = imageView.frame
        frame.origin.x = frame.width  < bounds.width
            ? (bounds.width  - frame.width)  / 2 : 0
        frame.origin.y = frame.height < bounds.height
            ? (bounds.height - frame.height) / 2 : 0
        imageView.frame = frame
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            // Zoom toward the tapped point rather than the centre, so
            // double-tapping a face brings that face in.
            let point = gesture.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
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
