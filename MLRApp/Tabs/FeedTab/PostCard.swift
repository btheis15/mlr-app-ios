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

    private var canEdit: Bool {
        env.isAdmin || env.currentProfile?.id == post.authorId
    }

    // Standard reaction emojis
    private let reactionEmojis = ["❤️", "👍", "😂", "🙌", "🎉"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            authorRow
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
            } else if post.status == .hidden {
                Label("Removed by an admin — hidden from the feed.", systemImage: "nosign")
                    .font(.mlrScaled(12, weight: .medium))
                    .foregroundStyle(Color.mlrDanger)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.mlrDanger.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.mlrDanger.opacity(0.35), lineWidth: 1))
            }
            mediaContent
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
                    .font(.body)
                    .foregroundStyle(Color.mlrText)
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
            }
            reactionRow
            actionRow
        }
        .sheet(isPresented: $showComments) {
            CommentsView(post: post)
        }
        .fullScreenCover(item: $lightbox) { pres in
            LightboxView(urls: post.mediaUrls, isVideo: post.mediaIsVideo, startIndex: pres.startIndex)
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
            AvatarView(url: post.authorAvatarUrl, size: .small)

            VStack(alignment: .leading, spacing: 1) {
                // PrivateName: guests see first name only
                Text(displayName)
                    .font(.mlrScaled(14, weight: .semibold))
                    .foregroundStyle(Color.mlrText)
                Text(MLRFormat.relativeTime(post.timelineDate))
                    .font(.caption)
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
            // Square (1:1) carousel — mirrors the web MediaGrid so portrait and
            // landscape items share one uniform frame instead of a wide box.
            TabView {
                ForEach(Array(urls.enumerated()), id: \.offset) { idx, url in
                    PostMediaTile(url: url, isVideo: post.isVideo(at: idx)) {
                        lightbox = LightboxPresentation(startIndex: idx)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let first = urls.first {
            PostMediaTile(url: first, isVideo: post.isVideo(at: 0)) {
                lightbox = LightboxPresentation(startIndex: 0)
            }
        }
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
                    Button {
                        Haptics.tap()
                        Task { await onReactionToggle(emoji) }
                    } label: {
                        HStack(spacing: 3) {
                            Text(emoji).font(.mlrScaled(15))
                            Text("\(reactionCount(for: emoji))")
                                .font(.mlrScaled(12, weight: .semibold))
                                .foregroundStyle(isMineReaction(emoji: emoji) ? Color.mlrPrimary : Color.mlrTextMuted)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(isMineReaction(emoji: emoji) ? Color.mlrPrimary.opacity(0.12) : Color.secondary.opacity(0.08))
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(
                            isMineReaction(emoji: emoji) ? Color.mlrPrimary.opacity(0.35) : Color.secondary.opacity(0.18),
                            lineWidth: 1))
                    }
                    .buttonStyle(.pressable)
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

                // "Who reacted" — only when there are reactions
                if !reactions.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showReactors.toggle() }
                        if showReactors { Task { reactors = await env.postsService.fetchReactors(postId: post.id) } }
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

    // MARK: - Action row (comment count + open CommentsView)

    private var actionRow: some View {
        Button {
            showComments = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: comments.isEmpty ? "bubble.left" : "bubble.left.fill")
                    .font(.mlrScaled(14))
                    .foregroundStyle(comments.isEmpty ? Color.mlrTextMuted : Color.mlrPrimary)
                Text(commentLabel)
                    .font(.mlrScaled(14, weight: .medium))
                    .foregroundStyle(Color.mlrTextMuted)
            }
        }
        .buttonStyle(.pressable)
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

    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var failed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        // `Color.clear` is the size anchor: full width, forced to 1:1 — so the
        // tile is ALWAYS square regardless of the image's own aspect ratio.
        // (A ZStack sized by the image let portrait photos render tall/native
        // instead of the square center-crop the web uses.)
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.mlrScaled(46))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
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
            .background(isVideo ? Color.black : Color.mlrCard)
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture {
                // A failed image can't open in the (same-loader) lightbox, so send
                // the user to the original in the browser instead of a dead tap.
                if failed, let u = env.mediaTokenService.url(url) { openURL(u) } else { onTap() }
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
