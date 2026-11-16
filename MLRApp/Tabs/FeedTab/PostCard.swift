import SwiftUI
import Kingfisher

// MARK: - PostCard
// A single post in the Feed. Mirrors the PostCard component in the web app.
//
// Layout:
//   avatar + author name (PrivateName masked for guests) + timestamp
//   optional image (AsyncImage + tap → Lightbox)
//   text body with @mention highlights (MentionText from Shared)
//   reaction row (emoji buttons + counts, optimistic toggle)
//   comment count button → CommentsView sheet
//   ⋯ menu → Report / admin Remove

struct PostCard: View {
    let post: Post
    let reactions: [PostReaction]
    let onReactionToggle: @MainActor (String) async -> Void
    let onReport: @MainActor () async -> Void
    let onAdminRemove: (@MainActor () async -> Void)?

    @Environment(AppEnvironment.self) private var env
    @State private var showComments = false
    @State private var lightbox: LightboxPresentation?
    @State private var showEdit = false
    @State private var comments: [PostComment] = []
    @State private var commentsLoaded = false
    @State private var shareState: ShareState?
    @State private var showReactors = false
    @State private var reactors: [PostReactor] = []
    @State private var showEmojiPicker = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Zoom-transition source namespace: each media tile is a
    /// `matchedTransitionSource(id: index)` and the lightbox zooms from/to the
    /// tile for whichever photo is visible.
    @Namespace private var zoomNS
    /// Visible page of the multi-photo carousel (kept in sync with the lightbox).
    @State private var carouselIndex: Int? = 0

    private var canEdit: Bool {
        env.isAdmin || env.currentProfile?.id == post.authorId
    }

    // Standard reaction emojis
    private let reactionEmojis = postReactionEmojis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            authorRow.padding(.horizontal, 16).padding(.top, 14)
            // Moderation banners — only the author + admins ever receive
            // non-visible rows (RLS), so this explains why it's held/hidden.
            if post.status == .pending {
                Label("Pending review — only you and admins can see this until it's approved.",
                      systemImage: "hourglass")
                    .font(.mlrScaled(12, weight: .medium))
                    .foregroundStyle(Color.mlrWarning)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.mlrWarning.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mlrWarning.opacity(0.35), lineWidth: 1))
                    .padding(.horizontal, 16)
            } else if post.status == .hidden {
                Label("Removed by an admin — hidden from the feed.", systemImage: "nosign")
                    .font(.mlrScaled(12, weight: .medium))
                    .foregroundStyle(Color.mlrDanger)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.mlrDanger.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mlrDanger.opacity(0.35), lineWidth: 1))
                    .padding(.horizontal, 16)
            }
            mediaContent
                .padding(.horizontal, post.mediaUrls.isEmpty ? 0 : 8)
                // simultaneousGesture: TabView's horizontal page swipe fires alongside
                // this long press rather than being blocked by it.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .onEnded { _ in
                            guard env.isSignedIn else { return }
                            Haptics.tap()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                showEmojiPicker = true
                            }
                        }
                )
            if let text = post.text, !text.isEmpty {
                MentionText(text)
                    .font(post.mediaUrls.isEmpty && text.count < 220 ? .system(size: 18) : .system(.body, design: .default))
                    .foregroundStyle(Color.mlrText)
                    .padding(.horizontal, 16)
                    .onLongPressGesture(minimumDuration: 0.4) {
                        guard env.isSignedIn else { return }
                        Haptics.tap()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            showEmojiPicker = true
                        }
                    }
            }
            if !post.tags.isEmpty {
                Label("With \(post.tags.map(\.name).joined(separator: ", "))", systemImage: "person.2.fill")
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrTextMuted)
                    .padding(.horizontal, 16)
            }
            reactionRow.padding(.horizontal, 16)
            commentPreviews.padding(.horizontal, 16)
            Color.clear.frame(height: 2)
        }
        .sheet(isPresented: $showComments) {
            CommentsView(post: post)
        }
        .fullScreenCover(item: $lightbox) { pres in
            LightboxView(urls: post.mediaUrls, isVideo: post.mediaIsVideo, startIndex: pres.startIndex,
                         zoomNamespace: zoomNS,
                         onSelectionChange: { carouselIndex = $0 })
        }
        .sheet(isPresented: $showEdit) {
            PostComposer(editing: post)
        }
        .shareSheet($shareState)
        .task {
            // Load comments eagerly so we can show the comment count without an extra fetch.
            if !commentsLoaded {
                comments = (try? await env.postsService.fetchComments(postId: post.id)) ?? []
                commentsLoaded = true
            }
        }
    }

    // MARK: - Author row

    private var authorRow: some View {
        HStack(alignment: .center, spacing: 10) {
            MLRAvatar(name: post.authorName, url: post.authorAvatarUrl, size: 36, ring: false)

            VStack(alignment: .leading, spacing: 1) {
                // PrivateName: guests see first name only
                Text(displayName)
                    .font(.mlrScaled(15, weight: .semibold))
                    .foregroundStyle(Color.mlrText)
                Text(MLRFormat.relativeTime(post.timelineDate))
                    .font(.mlrCaption13)
                    .foregroundStyle(Color.mlrTextMuted)
            }

            Spacer()

            // ⋯ overflow menu
            Menu {
                Button {
                    shareState = ShareState(items: shareItems)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if canEdit {
                    Divider()
                    Button {
                        showEdit = true
                    } label: {
                        Label("Edit post", systemImage: "pencil")
                    }
                }
                if env.isSignedIn {
                    Divider()
                    Button(role: .destructive) {
                        Task { await onReport() }
                    } label: {
                        Label("Report post", systemImage: "flag")
                    }
                }
                if let adminRemove = onAdminRemove {
                    Divider()
                    Button(role: .destructive) {
                        Task { await adminRemove() }
                    } label: {
                        Label("Remove post", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.mlrScaled(16))
                    .foregroundStyle(Color.mlrTextMuted)
                    .padding(8)
                    .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Media (single image or swipeable carousel)

    @ViewBuilder
    private var mediaContent: some View {
        let urls = post.mediaUrls
        if urls.count > 1 {
            // Square (1:1) paged carousel — mirrors the web MediaGrid so portrait and
            // landscape items share one uniform frame instead of a wide box.
            // A scroll-view pager (not TabView) so it gets scrollTransition and a
            // position binding the lightbox can drive.
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { idx, url in
                        mediaTile(idx, url)
                            .containerRelativeFrame(.horizontal)
                            .scrollTransition(axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(reduceMotion || phase.isIdentity ? 1 : 0.92)
                                    .opacity(reduceMotion || phase.isIdentity ? 1 : 0.55)
                            }
                            .id(idx)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $carouselIndex)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .bottom) {
                PageDots(count: urls.count, current: carouselIndex ?? 0)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
            }
            .sensoryFeedback(.selection, trigger: carouselIndex)
        } else if let first = urls.first {
            mediaTile(0, first)
        }
    }

    private func mediaTile(_ idx: Int, _ url: String) -> some View {
        PostMediaTile(
            url: url,
            isVideo: post.isVideo(at: idx),
            onTap: { lightbox = LightboxPresentation(startIndex: idx) },
            onDoubleTap: { likeFromDoubleTap() }
        )
        .matchedTransitionSource(id: idx, in: zoomNS) { source in
            source.clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    /// Double-tap on a photo = ❤️ through the SAME path as the reaction bar
    /// (`onReactionToggle`). It only ever adds: if my reaction is already ❤️ we
    /// skip the toggle (which would remove it) and just replay the heart.
    /// Returns whether the heart should pop (signed-in members only).
    private func likeFromDoubleTap() -> Bool {
        guard env.isSignedIn else { return false }
        Haptics.tap()
        if !isMineReaction(emoji: "❤️") {
            Task { await onReactionToggle("❤️") }
        }
        return true
    }

    private func openReactors() {
        withAnimation(.easeInOut(duration: 0.2)) { showReactors = true }
        Task { reactors = await env.postsService.fetchReactors(postId: post.id) }
    }

    // MARK: - Reaction row
    // Facebook/Messages style: only used reactions shown inline as pills.
    // A smiley button (or long-press on media) opens the emoji picker.

    private var reactionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Used reactions — only emojis with at least one reaction
                let used = reactionEmojis.filter { reactionCount(for: $0) > 0 }
                ForEach(used, id: \.self) { emoji in
                    let count = reactionCount(for: emoji)
                    Button {
                        Haptics.tap()
                        Task { await onReactionToggle(emoji) }
                    } label: {
                        HStack(spacing: 3) {
                            Text(emoji).font(.mlrScaled(17))
                                .modifier(EmojiBounce(trigger: isMineReaction(emoji: emoji)))
                            Text("\(count)")
                                .font(.mlrScaled(14, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(isMineReaction(emoji: emoji) ? Color.mlrPrimary : Color.mlrTextMuted)
                                .contentTransition(.numericText())
                                .animation(reduceMotion ? nil : MLRMotion.spring, value: count)
                        }
                        .padding(.horizontal, 12).frame(height: 32)
                        .contentShape(Rectangle().inset(by: -6))
                        .background(isMineReaction(emoji: emoji) ? Color.mlrPrimary.opacity(0.12) : Color.mlrCard)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(
                            isMineReaction(emoji: emoji) ? Color.mlrPrimary : Color.mlrBorder,
                            lineWidth: 1))
                    }
                    .buttonStyle(.pressable)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                    // Long-press: who reacted. Names come from the reactor list
                    // (fetched on demand by the card); until it's loaded the menu
                    // offers to load it rather than firing a per-card query.
                    .contextMenu {
                        let group = reactors.filter { $0.emoji == emoji }
                        if group.isEmpty {
                            Button { openReactors() } label: {
                                Label("See who reacted", systemImage: "person.2")
                            }
                        } else {
                            ForEach(group) { r in
                                Text(r.userId == env.currentProfile?.id ? "You" : r.name)
                            }
                        }
                    }
                }

                // Add-reaction button — opens the emoji picker
                if env.isSignedIn {
                    Button {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            showEmojiPicker.toggle()
                        }
                    } label: {
                        Image(systemName: "face.smiling")
                            .font(.mlrScaled(15))
                            .foregroundStyle(showEmojiPicker ? Color.mlrPrimary : Color.mlrTextMuted)
                            .padding(6)
                            .background(showEmojiPicker ? Color.mlrPrimary.opacity(0.1) : Color.clear)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.pressable)
                }

                Spacer()

                commentButton

                // "Who reacted" — only when there are reactions
                if !reactions.isEmpty {
                    Button {
                        if showReactors {
                            withAnimation(.easeInOut(duration: 0.2)) { showReactors = false }
                        } else {
                            openReactors()
                        }
                    } label: {
                        Image(systemName: showReactors ? "chevron.up" : "person.2.fill")
                            .font(.mlrScaled(11, weight: .semibold))
                            .foregroundStyle(Color.mlrTextMuted)
                            .padding(6)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(showReactors ? "Hide who reacted" : "See who reacted")
                }
            }
            .animation(reduceMotion ? nil : MLRMotion.spring, value: reactions)

            // Floating emoji picker — appears inline below used reactions
            if showEmojiPicker {
                HStack(spacing: 2) {
                    ForEach(reactionEmojis, id: \.self) { emoji in
                        Button {
                            Haptics.tap()
                            Task { await onReactionToggle(emoji) }
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                showEmojiPicker = false
                            }
                        } label: {
                            Text(emoji)
                                .font(.system(size: 28))
                                .scaleEffect(isMineReaction(emoji: emoji) ? 0.85 : 1.0)
                                .padding(6)
                                .background(isMineReaction(emoji: emoji) ? Color.mlrPrimary.opacity(0.12) : Color.clear)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
            }

            if showReactors {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(reactorLines, id: \.emoji) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.emoji).font(.mlrScaled(13))
                            Text(line.names)
                                .font(.mlrScaled(12))
                                .foregroundStyle(Color.mlrTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
        }
    }

    /// Reactor names grouped by emoji ("You" for self), in the standard emoji order.
    private var reactorLines: [(emoji: String, names: String)] {
        let myId = env.currentProfile?.id
        return reactionEmojis.compactMap { emoji in
            let group = reactors.filter { $0.emoji == emoji }
            guard !group.isEmpty else { return nil }
            let names = group.map { $0.userId == myId ? "You" : $0.name }
            return (emoji, names.joined(separator: ", "))
        }
    }

    // MARK: - Comment button + previews

    private var commentButton: some View {
        Button {
            showComments = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: comments.isEmpty ? "bubble.left" : "bubble.left.fill")
                    .font(.mlrScaled(15))
                    .foregroundStyle(comments.isEmpty ? Color.mlrTextMuted : Color.mlrPrimary)
                if !comments.isEmpty {
                    Text("\(comments.count)")
                        .font(.mlrScaled(14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.mlrTextMuted)
                }
            }
            .padding(.horizontal, 6).frame(height: 32)
            .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(commentLabel)
    }

    @ViewBuilder
    private var commentPreviews: some View {
        let visible = comments.filter { $0.status == .visible }
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(visible.suffix(2)) { c in
                    (Text(c.authorName + "  ").font(.mlrScaled(15, weight: .semibold))
                        + Text(c.text).font(.mlrScaled(15)))
                        .foregroundStyle(Color.mlrText)
                        .lineLimit(2)
                }
                if comments.count > 2 {
                    Button { showComments = true } label: {
                        Text("View all \(comments.count) comments")
                            .font(.mlrScaled(14))
                            .foregroundStyle(Color.mlrTextMuted)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    // MARK: - Helpers

    private var shareItems: [Any] {
        var items: [Any] = []
        if let text = post.text, !text.isEmpty {
            items.append(text)
        }
        if let urlString = post.imageUrl, let url = URL(string: urlString) {
            items.append(url)
        }
        // Always share something even if the post is text- or image-less.
        if items.isEmpty {
            items.append("Shared from the MLR app 🌲")
        }
        return items
    }

    private var displayName: String {
        if !env.isSignedIn {
            return post.authorName.components(separatedBy: " ").first ?? post.authorName
        }
        return post.authorName
    }

    private var commentLabel: String {
        switch comments.count {
        case 0: return "Comment"
        case 1: return "1 comment"
        default: return "\(comments.count) comments"
        }
    }

    private func reactionCount(for emoji: String) -> Int {
        reactions.filter { $0.emoji == emoji }.count
    }

    private func isMineReaction(emoji: String) -> Bool {
        guard let userId = env.currentProfile?.id else { return false }
        return reactions.contains(where: { $0.userId == userId && $0.emoji == emoji })
    }
}

// MARK: - PostMediaTile
// A single feed media item in a uniform SQUARE frame (matches the web MediaGrid):
// a portrait photo center-crops to a square (still reads upright — tap opens the
// full image in the lightbox) instead of being squeezed into a wide landscape
// slice. Videos sit on black so they're never cropped.
//
// Crucially, this owns a `failed` state: KFImage's `.placeholder` also shows on
// FAILURE, so without this an image that 404s, is still transcoding, or won't
// decode would spin forever. On failure we retry a couple times, then show a
// tappable fallback that opens the original in the browser.

private struct PostMediaTile: View {
    let url: String
    let isVideo: Bool
    let onTap: () -> Void
    /// Double-tap on a photo; returns true if a heart should pop at the tap point.
    var onDoubleTap: (() -> Bool)? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var failed = false
    @State private var hearts: [HeartBurst] = []

    private struct HeartBurst: Identifiable {
        let id = UUID()
        let point: CGPoint
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18)
        // `Color.clear` is the size anchor: full width, forced to 1:1 — so the
        // tile is ALWAYS square regardless of the image's own aspect ratio.
        // (A ZStack sized by the image let portrait photos render tall/native
        // instead of the square center-crop the web uses.)
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if isVideo {
                    videoAffordance
                } else if failed {
                    failureView
                } else if let imageURL = env.mediaTokenService.url(url) {
                    KFImage(imageURL)
                        .placeholder { ProgressView() }
                        .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 1200, height: 1200)))
                        .scaleFactor(UIScreen.main.scale)
                        .retry(maxCount: 2, interval: .seconds(2))
                        .onFailure { _ in failed = true }
                        .fade(duration: 0.2)
                        .resizable()
                        .scaledToFill()
                } else {
                    failureView
                }
            }
            .overlay {
                ZStack(alignment: .topLeading) {
                    ForEach(hearts) { h in
                        HeartPop().position(h.point)
                    }
                }
                .allowsHitTesting(false)
            }
            .background(isVideo ? Color.black : Color.mlrCard)
            .clipShape(shape)
            .contentShape(shape)
            .modifier(TileTaps(
                allowsDoubleTap: !isVideo && !failed && onDoubleTap != nil,
                single: {
                    // A failed image can't open in the (same-loader) lightbox, so send
                    // the user to the original in the browser instead of a dead tap.
                    if failed, let u = env.mediaTokenService.url(url) { openURL(u) } else { onTap() }
                },
                double: { point in
                    guard onDoubleTap?() == true else { return }
                    let burst = HeartBurst(point: point)
                    hearts.append(burst)
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        hearts.removeAll { $0.id == burst.id }
                    }
                }
            ))
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isVideo ? "Play video" : "Photo")
    }

    /// Clear play affordance: a frosted disc with a play glyph and a small
    /// video badge. (No poster frame is available, so the tile stays black.)
    private var videoAffordance: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [Color.black, Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 68, height: 68)
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.mlrScaled(28))
                        .foregroundStyle(.white)
                        .offset(x: 2)
                )
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Label("Video", systemImage: "video.fill")
                .font(.mlrScaled(11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(10)
        }
    }

    private var failureView: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.mlrScaled(34))
                .foregroundStyle(Color.mlrTextSubtle)
            Text("Couldn't load — tap to open")
                .font(.mlrScaled(12))
                .foregroundStyle(Color.mlrTextMuted)
        }
        .padding()
    }
}

/// Single tap always; double tap (with location) only when allowed. When a
/// double tap is allowed the single tap waits out the double-tap window
/// (`exclusively`), otherwise it fires immediately.
private struct TileTaps: ViewModifier {
    let allowsDoubleTap: Bool
    let single: () -> Void
    let double: (CGPoint) -> Void

    func body(content: Content) -> some View {
        if allowsDoubleTap {
            content.gesture(
                SpatialTapGesture(count: 2).onEnded { double($0.location) }
                    .exclusively(before: TapGesture().onEnded { single() })
            )
        } else {
            content.onTapGesture { single() }
        }
    }
}

private struct HeartFrame {
    var scale: CGFloat = 0.3
    var opacity: Double = 0
    var rise: CGFloat = 0
}

/// The heart that pops and fades where you double-tapped. Reduce Motion: a
/// plain fade, no scale or rise.
private struct HeartPop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var go = false

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 84))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 10)
            .keyframeAnimator(initialValue: HeartFrame(), trigger: go) { view, f in
                view
                    .scaleEffect(reduceMotion ? 1 : f.scale)
                    .offset(y: reduceMotion ? 0 : f.rise)
                    .opacity(f.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.2, duration: 0.28, spring: .bouncy)
                    CubicKeyframe(1.0, duration: 0.12)
                    CubicKeyframe(1.0, duration: 0.35)
                    CubicKeyframe(0.95, duration: 0.25)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.06)
                    LinearKeyframe(1, duration: 0.64)
                    LinearKeyframe(0, duration: 0.3)
                }
                KeyframeTrack(\.rise) {
                    LinearKeyframe(0, duration: 0.45)
                    CubicKeyframe(-44, duration: 0.55)
                }
            }
            .onAppear { go = true }
            .accessibilityHidden(true)
    }
}

/// Bounces its content whenever `trigger` flips (my reaction toggled on/off).
private struct EmojiBounce: ViewModifier {
    let trigger: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(1.5, duration: 0.14)
                    SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
                }
            }
        }
    }
}

/// Page indicator for the carousel: frosted capsule, active dot stretches.
private struct PageDots: View {
    let count: Int
    let current: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.white : Color.white.opacity(0.5))
                    .frame(width: i == current ? 16 : 6, height: 6)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.black.opacity(0.35), in: Capsule())
        .animation(reduceMotion ? nil : MLRMotion.spring, value: current)
        .accessibilityElement()
        .accessibilityLabel("Photo \(current + 1) of \(count)")
    }
}

// MARK: - PostCardSkeleton
// Pulsing loading placeholder for a post card.

struct PostCardSkeleton: View {
    @State private var opacity: Double = 0.4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.mlrCard)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.mlrCard).frame(width: 120, height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.mlrCard).frame(width: 60, height: 10)
                }
            }
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.mlrCard).frame(maxWidth: .infinity).frame(height: 14)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.mlrCard).frame(width: 200).frame(height: 14)
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                opacity = 1.0
            }
        }
    }
}

// Drives the full-screen lightbox at a specific carousel index.
private struct LightboxPresentation: Identifiable {
    let startIndex: Int
    var id: Int { startIndex }
}

// AvatarView — Shared/Components/AvatarView.swift
// MentionText — Shared/Components/MentionText.swift
