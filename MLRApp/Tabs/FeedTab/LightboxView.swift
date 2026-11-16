import SwiftUI
import AVKit
import Kingfisher
import CoreTransferable
import UniformTypeIdentifiers

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
//   • Close (top-left) + ShareLink for the current item (top-right)
//   • Drag a photo down (or up) to dismiss: it follows the finger and the black
//     backdrop fades. The pan is a UIKit recognizer on the zoom scroll view for
//     the same negotiation reason as the zoom (see below).
//   • Optional iOS 18 zoom transition from the tapped tile: callers pass the
//     source namespace; the source id tracks the visible page so the dismiss
//     zooms back into the tile for the photo you are actually looking at.
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
    /// Namespace of the `matchedTransitionSource(id: index, in:)` tiles in the
    /// presenting view. nil = plain full-screen cover (other call sites).
    var zoomNamespace: Namespace.ID? = nil
    /// Reports the visible page so the presenter can keep its carousel in sync.
    var onSelectionChange: ((Int) -> Void)? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: Int
    /// Live drag-to-dismiss translation (photo follows the finger).
    @State private var dragOffset: CGSize = .zero

    init(urls: [String], isVideo: [Bool] = [], startIndex: Int = 0,
         zoomNamespace: Namespace.ID? = nil,
         onSelectionChange: ((Int) -> Void)? = nil) {
        self.urls = urls
        self.isVideo = isVideo
        self.zoomNamespace = zoomNamespace
        self.onSelectionChange = onSelectionChange
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

    /// 0 at rest → 1 after ~300pt of drag.
    private var dragProgress: CGFloat {
        min(1, max(abs(dragOffset.width), abs(dragOffset.height)) / 300)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dragProgress * 0.9)
                .ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(Array(urls.enumerated()), id: \.offset) { idx, url in
                    Group {
                        if isVideoItem(idx, url), let u = env.mediaTokenService.url(url) {
                            VideoPage(url: u)
                        } else if let u = env.mediaTokenService.url(url) {
                            // `isCurrent` resets the zoom on a page you've
                            // swiped away from, so coming back to it doesn't
                            // land you still zoomed into a corner.
                            ZoomableImage(url: u, isCurrent: selection == idx, onPan: handlePan)
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
            .scaleEffect(1 - dragProgress * 0.15)
            .offset(dragOffset)

            controls
                .opacity(max(0, 1 - dragProgress * 3))
        }
        .statusBarHidden()
        // Clear cover background so the fading black layer reveals the feed.
        .presentationBackground(.clear)
        .modifier(LightboxZoomTransition(namespace: zoomNamespace, sourceID: selection))
        .onChange(of: selection) { _, new in
            Haptics.select()
            onSelectionChange?(new)
        }
    }

    private func handlePan(translation: CGPoint, velocity: CGPoint, state: UIGestureRecognizer.State) {
        switch state {
        case .changed:
            dragOffset = CGSize(width: translation.x, height: translation.y)
        case .ended, .cancelled, .failed:
            if state == .ended, abs(translation.y) > 110 || abs(velocity.y) > 900 {
                dismiss()
            } else if reduceMotion {
                dragOffset = .zero
            } else {
                withAnimation(MLRMotion.spring) { dragOffset = .zero }
            }
        default:
            break
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
                .accessibilityLabel("Close")
                Spacer()
                if urls.count > 1 {
                    Text("\(min(selection + 1, urls.count)) of \(urls.count)")
                        .font(.mlrScaled(13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : MLRMotion.spring, value: selection)
                        .accessibilityLabel("Photo \(selection + 1) of \(urls.count)")
                }
                Spacer()
                shareControl
            }
            Spacer()
        }
    }

    /// System ShareLink: photos share as an image (so "Save Image" appears in
    /// the share sheet with no photo-library permission of our own); videos
    /// share their link.
    @ViewBuilder
    private var shareControl: some View {
        if selection < urls.count, let u = env.mediaTokenService.url(urls[selection]) {
            Group {
                if isVideoItem(selection, urls[selection]) {
                    ShareLink(item: u) { shareIcon }
                } else {
                    ShareLink(item: SharedPhoto(url: u), preview: SharePreview("Photo")) { shareIcon }
                }
            }
            .accessibilityLabel("Share")
        } else {
            // Balances the close button so the counter stays centred.
            Color.clear.frame(width: 54, height: 1)
        }
    }

    private var shareIcon: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.mlrScaled(22))
            .foregroundStyle(.white.opacity(0.85))
            .padding(16)
    }
}

/// Applies the iOS 18 zoom navigation transition only when a source namespace
/// was supplied; `sourceID` follows the visible page.
private struct LightboxZoomTransition: ViewModifier {
    let namespace: Namespace.ID?
    let sourceID: Int

    func body(content: Content) -> some View {
        if let namespace {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}

/// A photo exported as JPEG data for ShareLink (downloaded on demand).
private struct SharedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { photo in
            let (data, _) = try await URLSession.shared.data(from: photo.url)
            guard let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.95) else {
                throw URLError(.cannotDecodeContentData)
            }
            return jpeg
        }
    }
}

// MARK: - Zoomable image page (UIScrollView-backed)

private struct ZoomableImage: UIViewRepresentable {
    let url: URL
    /// False for a page that's been swiped away from — see the reset below.
    let isCurrent: Bool
    /// Vertical drag-to-dismiss updates (only fired while at 1× zoom).
    var onPan: ((CGPoint, CGPoint, UIGestureRecognizer.State) -> Void)? = nil

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        let view = ZoomableImageScrollView()
        view.onPan = onPan
        view.load(url)
        return view
    }

    func updateUIView(_ view: ZoomableImageScrollView, context: Context) {
        view.onPan = onPan
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

    /// translation, velocity, state — see `dismissPan`.
    var onPan: ((CGPoint, CGPoint, UIGestureRecognizer.State) -> Void)?
    private let dismissPan = UIPanGestureRecognizer()
    private let panDelegate = DismissPanDelegate()

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

        // Drag-to-dismiss. A separate delegate object (not self) so we never
        // fight UIScrollView's own delegate conformance for its internal
        // recognizers. It only begins for a vertical-dominant drag at 1×, so
        // horizontal paging and zoomed panning are untouched.
        panDelegate.owner = self
        dismissPan.delegate = panDelegate
        dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
        addGestureRecognizer(dismissPan)
    }

    @objc private func handleDismissPan(_ g: UIPanGestureRecognizer) {
        onPan?(g.translation(in: self), g.velocity(in: self), g.state)
    }

    fileprivate func shouldBeginDismissPan(_ g: UIPanGestureRecognizer) -> Bool {
        guard zoomScale <= minimumZoomScale + 0.01 else { return false }
        let v = g.velocity(in: self)
        return abs(v.y) > abs(v.x)
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

private final class DismissPanDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var owner: ZoomableImageScrollView?

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return false }
        return owner?.shouldBeginDismissPan(pan) ?? false
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
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

// MARK: - ShareSheet
// UIActivityViewController wrapper.

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
