import SwiftUI
import Kingfisher
import PhotosUI

// MARK: - CommentsView
// Sheet presenting the comment thread for a post.
// Mirrors the comments sheet in the web app.
//
// Features:
//   • Post recap at top (author, text snippet, optional image thumbnail)
//   • List of PostComments with MentionText + relative timestamp
//   • Sign-in guard on the comment input box
//   • TextEditor + send button with @mention autocomplete
//   • Report button (⋯) per comment
//   • "Be the first to comment" empty state

struct CommentsView: View {
    let post: Post
    /// A specific comment to scroll to on open — set from a post_comment/reply/
    /// mention notification's `&comment=<id>` (migration 0164).
    var focusCommentId: UUID? = nil

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var comments: [PostComment] = []
    @State private var isLoading = true
    @State private var commentText = ""
    @State private var isSending = false
    @State private var sendError: String? = nil
    @State private var showSignIn = false
    @State private var mentionQuery: String? = nil
    @State private var allProfiles: [Profile] = []
    @State private var commentReactions: [CommentReaction] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Live updates + optimistic send
    @State private var live = CommentsLiveChannel()
    /// Ids of optimistic (not yet confirmed) comments; the merge keeps them.
    @State private var pendingTempIds: Set<UUID> = []
    /// Comments whose reaction I am toggling right now (realtime echo skipped).
    @State private var reactionInFlight: Set<UUID> = []
    /// Set to your own just-sent comment so the list scrolls to it.
    @State private var scrollTarget: UUID? = nil
    @FocusState private var composerFocused: Bool

    // Attachments (migration 0162) — same compress/upload pipeline as a post.
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var selectedVideo: PhotosPickerItem?
    @State private var videoData: Data?
    @State private var isUploading = false

    private let charLimit = 300
    private let maxPhotos = 5

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                postRecap
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                Divider()

                commentList
            }
            .mlrBackdrop()
            // Pinned above the keyboard (safe-area inset rides up with it) and
            // grows with the text.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    if env.isSignedIn {
                        commentInput
                    } else {
                        signInPrompt
                    }
                }
                .background(.bar)
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
        }
        .task {
            await loadComments()
            startLiveUpdates()
            // Pre-load member list for @mention autocomplete
            if env.isSignedIn {
                allProfiles = (try? await fetchMemberList()) ?? []
            }
        }
        .onDisappear { live.stop() }
        .onChange(of: selectedPhotos) { _, items in
            Task { await loadPhotos(items) }
        }
        .onChange(of: selectedVideo) { _, item in
            Task {
                guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
                await MainActor.run { videoData = data }
            }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        var loaded: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                loaded.append(img)
            }
        }
        await MainActor.run { images = loaded }
    }

    // MARK: - Post recap

    private var postRecap: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: post.authorAvatarUrl, size: .small)
            VStack(alignment: .leading, spacing: 3) {
                Text(env.isSignedIn
                     ? post.authorName
                     : (post.authorName.components(separatedBy: " ").first ?? post.authorName))
                    .font(.mlrScaled(13, weight: .semibold))
                    .foregroundStyle(Color.mlrText)
                if let text = post.text {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(Color.mlrTextMuted)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let imageUrl = post.imageUrl, let url = env.mediaTokenService.url(imageUrl) {
                KFImage(url)
                    .placeholder { Color.mlrCard }
                    .setProcessor(DownsamplingImageProcessor(size: CGSize(width: 132, height: 132)))
                    .scaleFactor(UIScreen.main.scale)
                    .fade(duration: 0.2)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Comment list

    @ViewBuilder
    private var commentList: some View {
        if isLoading {
            List {
                ForEach(0..<4, id: \.self) { _ in CommentSkeleton() }
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        } else if comments.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "bubble.left")
                    .font(.mlrScaled(36))
                    .foregroundStyle(Color.mlrTextSubtle)
                Text("Be the first to comment")
                    .font(.subheadline)
                    .foregroundStyle(Color.mlrTextMuted)
                Spacer()
            }
        } else {
            ScrollViewReader { proxy in
                List {
                    ForEach(comments) { comment in
                        CommentRow(
                            comment: comment,
                            isSignedIn: env.isSignedIn,
                            canReport: env.isSignedIn && comment.authorId != env.currentProfile?.id,
                            canDelete: canDelete(comment),
                            reactions: commentReactions.filter { $0.commentId == comment.id },
                            myUserId: env.currentProfile?.id,
                            canReact: env.isSignedIn && env.isVerifiedMember,
                            onReact: { emoji in await toggleReaction(comment, emoji) },
                            onReport: {
                                await reportComment(comment)
                            },
                            onDelete: {
                                await deleteComment(comment)
                            }
                        )
                        .id(comment.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        // An optimistic (still-sending) comment is dimmed and inert.
                        .opacity(pendingTempIds.contains(comment.id) ? 0.55 : 1)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !pendingTempIds.contains(comment.id) {
                                if canDelete(comment) {
                                    Button(role: .destructive) {
                                        Task { await deleteComment(comment) }
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                                if env.isSignedIn && comment.authorId != env.currentProfile?.id {
                                    Button {
                                        Task { await reportComment(comment) }
                                    } label: { Label("Report", systemImage: "flag") }
                                    .tint(Color.mlrWarning)
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if env.isSignedIn && !pendingTempIds.contains(comment.id) {
                                Button { replyTo(comment) } label: {
                                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                                }
                                .tint(Color.mlrPineText)
                                if env.isVerifiedMember {
                                    Button {
                                        Task { await toggleReaction(comment, "❤️") }
                                    } label: { Label("Like", systemImage: "heart.fill") }
                                    .tint(.pink)
                                }
                            }
                        }
                        .contextMenu {
                            if env.isSignedIn && !pendingTempIds.contains(comment.id) {
                                Button { replyTo(comment) } label: {
                                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                                }
                                if env.isVerifiedMember {
                                    Menu {
                                        ForEach(commentReactionEmojis, id: \.self) { emoji in
                                            Button(emoji) { Task { await toggleReaction(comment, emoji) } }
                                        }
                                    } label: { Label("React", systemImage: "face.smiling") }
                                }
                                if env.isSignedIn && comment.authorId != env.currentProfile?.id {
                                    Button(role: .destructive) {
                                        Task { await reportComment(comment) }
                                    } label: { Label("Report comment", systemImage: "flag") }
                                }
                                if canDelete(comment) {
                                    Button(role: .destructive) {
                                        Task { await deleteComment(comment) }
                                    } label: { Label("Delete comment", systemImage: "trash") }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: scrollTarget) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : MLRMotion.entrance) { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onAppear {
                    if let id = scrollTarget {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                    guard let focusCommentId, comments.contains(where: { $0.id == focusCommentId }) else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation { proxy.scrollTo(focusCommentId, anchor: .center) }
                    }
                }
            }
        }
    }

    // MARK: - Comment input

    @ViewBuilder
    private var commentInput: some View {
        VStack(spacing: 0) {
            // @mention autocomplete overlay above the input row
            if let query = mentionQuery, !allProfiles.isEmpty {
                MentionAutocomplete(
                    members: allProfiles,
                    query: query,
                    onSelect: { insertMention($0) }
                )
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .animation(.easeOut(duration: 0.15), value: mentionQuery)
            }

            if !images.isEmpty || videoData != nil {
                attachmentPreviews
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            HStack(spacing: 4) {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: maxPhotos, matching: .images) {
                    Image(systemName: "photo.on.rectangle").font(.mlrScaled(16))
                }
                .disabled(isSending || isUploading)

                PhotosPicker(selection: $selectedVideo, matching: .videos) {
                    Image(systemName: "video.badge.plus").font(.mlrScaled(16))
                }
                .disabled(isSending || isUploading)
                Spacer()
                if isUploading {
                    ProgressView().font(.caption)
                }
            }
            .tint(Color.mlrPineText)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            HStack(alignment: .bottom, spacing: 10) {
                AvatarView(url: env.currentProfile?.avatarUrl, size: .small)

                // Vertical-axis TextField: one line that grows to 5 as you type.
                TextField("Add a comment…", text: $commentText, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.subheadline)
                    .focused($composerFocused)
                    .onChange(of: commentText) { _, val in
                        mentionQuery = detectMentionQuery(in: val)
                    }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.mlrCard)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.mlrBorder, lineWidth: 1))

                Button {
                    Task { await sendComment() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? Color.mlrPrimary : Color.mlrTextSubtle))
                }
                .disabled(!canSend || isSending)
                .animation(reduceMotion ? nil : MLRMotion.spring, value: canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if let err = sendError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Color.mlrDanger)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
        }
        .animation(reduceMotion ? nil : MLRMotion.spring, value: commentText.isEmpty)
    }

    private var attachmentPreviews: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { idx, image in
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button {
                            images.remove(at: idx)
                            if idx < selectedPhotos.count { selectedPhotos.remove(at: idx) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.mlrScaled(15)).foregroundStyle(.white).shadow(radius: 2).padding(2)
                        }
                    }
                }
                if videoData != nil {
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.mlrCard)
                            .frame(width: 64, height: 64)
                            .overlay(Image(systemName: "play.circle.fill").font(.mlrScaled(20)).foregroundStyle(Color.mlrTextMuted))
                        Button {
                            videoData = nil
                            selectedVideo = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.mlrScaled(15)).foregroundStyle(.white).shadow(radius: 2).padding(2)
                        }
                    }
                }
            }
        }
    }

    private var signInPrompt: some View {
        HStack {
            Text("Sign in to comment")
                .font(.subheadline)
                .foregroundStyle(Color.mlrTextMuted)
            Spacer()
            Button("Sign in") { showSignIn = true }
                .font(.mlrScaled(15, weight: .semibold))
                .foregroundStyle(Color.mlrPineText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Helpers

    /// A photo/video on its own is a perfectly good comment — text OR at
    /// least one file, mirroring the post composer's own rule.
    private var canSend: Bool {
        let hasText = !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMedia = !images.isEmpty || videoData != nil
        return (hasText || hasMedia)
        && commentText.count <= charLimit
        && !isSending && !isUploading
    }

    @MainActor
    private func loadComments() async {
        isLoading = true
        comments = (try? await env.postsService.fetchComments(postId: post.id)) ?? []
        isLoading = false
        await loadCommentReactions()
    }

    // MARK: Comment reactions

    @MainActor
    private func loadCommentReactions() async {
        guard env.isSignedIn else { return }
        commentReactions = await env.postsService.fetchCommentReactions(commentIds: comments.map(\.id))
    }

    /// Optimistic toggle with rollback: same emoji removes, different emoji upserts.
    @MainActor
    private func toggleReaction(_ comment: PostComment, _ emoji: String) async {
        guard env.isSignedIn else { showSignIn = true; return }
        guard env.isVerifiedMember, let me = env.currentProfile else { return }
        let snapshot = commentReactions
        reactionInFlight.insert(comment.id)
        defer { reactionInFlight.remove(comment.id) }
        let mine = commentReactions.first { $0.commentId == comment.id && $0.userId == me.id }
        let removing = mine?.emoji == emoji
        let apply = {
            commentReactions.removeAll { $0.commentId == comment.id && $0.userId == me.id }
            if !removing {
                commentReactions.append(CommentReaction(commentId: comment.id, userId: me.id, emoji: emoji, name: me.name))
            }
        }
        if reduceMotion { apply() } else { withAnimation(MLRMotion.spring) { apply() } }
        Haptics.tap()
        do {
            if removing {
                try await env.postsService.removeCommentReaction(commentId: comment.id, userId: me.id)
            } else {
                try await env.postsService.setCommentReaction(commentId: comment.id, emoji: emoji, userId: me.id)
            }
        } catch {
            print("[Comments] reaction error: \(error)")
            if reduceMotion { commentReactions = snapshot } else { withAnimation(MLRMotion.spring) { commentReactions = snapshot } }
            Haptics.error()
        }
    }

    /// Run a list mutation with the app's spring (instantly under Reduce Motion).
    @MainActor
    private func animated(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(MLRMotion.spring, change) }
    }

    @MainActor
    private func sendComment() async {
        guard let profile = env.currentProfile, canSend else { return }
        sendError = nil
        let trimmed = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let mentioned = mentionedUserIds(in: trimmed)

        // Text-only: optimistic. The comment appears (dimmed) at once, the
        // composer clears and the list scrolls to it; on failure the row is
        // rolled back and the draft restored.
        if images.isEmpty && videoData == nil {
            let draft = commentText
            let tempId = UUID()
            let temp = PostComment(
                id: tempId, postId: post.id, authorId: profile.id,
                authorName: profile.name, authorAvatarUrl: profile.avatarUrl,
                text: trimmed, status: .visible, createdAt: .now)
            pendingTempIds.insert(tempId)
            commentText = ""
            mentionQuery = nil
            Haptics.tap()
            animated { comments.append(temp) }
            scrollTarget = tempId
            do {
                let real = try await env.postsService.addComment(
                    postId: post.id, text: trimmed, authorId: profile.id,
                    mentionedIds: mentioned, media: [])
                pendingTempIds.remove(tempId)
                // Swap temp -> real in place; if realtime already delivered the
                // real row, just drop the temp. No animation: same content.
                if let idx = comments.firstIndex(where: { $0.id == tempId }) {
                    if comments.contains(where: { $0.id == real.id }) {
                        comments.remove(at: idx)
                    } else {
                        comments[idx] = real
                    }
                } else if !comments.contains(where: { $0.id == real.id }) {
                    comments.append(real)
                }
                scrollTarget = real.id
            } catch {
                pendingTempIds.remove(tempId)
                animated { comments.removeAll { $0.id == tempId } }
                // Restore the draft (keep anything typed since, below it).
                commentText = commentText.isEmpty ? draft : draft + "\n" + commentText
                sendError = "Couldn't post comment. Please try again."
                Haptics.error()
            }
            return
        }

        // With attachments: upload first, then insert (no optimistic row).
        isSending = true
        do {
            var media: [(path: String, type: String)] = []
            isUploading = true
            for image in images {
                let url = try await env.mediaService.uploadPostImage(image: image, userId: profile.id)
                media.append((path: url, type: "image"))
            }
            if let videoData {
                let url = try await env.mediaService.uploadPostVideo(data: videoData, userId: profile.id)
                media.append((path: url, type: "video"))
            }
            isUploading = false
            let comment = try await env.postsService.addComment(
                postId: post.id,
                text: trimmed,
                authorId: profile.id,
                mentionedIds: mentioned,
                media: media
            )
            if !comments.contains(where: { $0.id == comment.id }) {
                animated { comments.append(comment) }
            }
            scrollTarget = comment.id
            images = []; selectedPhotos = []; videoData = nil; selectedVideo = nil
            commentText = ""
            mentionQuery = nil
            Haptics.success()
        } catch {
            sendError = "Couldn't post comment. Please try again."
            Haptics.error()
        }
        isUploading = false
        isSending = false
    }

    // MARK: Live updates (merge, never reload)

    @MainActor
    private func startLiveUpdates() {
        live.start(
            postId: post.id,
            onCommentsChanged: { Task { await mergeRemoteComments() } },
            onCommentDeleted: { id in
                guard comments.contains(where: { $0.id == id }) else { return }
                animated {
                    comments.removeAll { $0.id == id }
                    commentReactions.removeAll { $0.commentId == id }
                }
            },
            onReactionChanged: { id in Task { await refreshReactions(for: id) } }
        )
    }

    /// Fetch the thread and fold it into what's on screen: new rows animate in,
    /// edited rows update in place, deleted rows drop out, and optimistic rows
    /// that haven't been confirmed yet stay put (unless the server copy of the
    /// same comment has already arrived).
    @MainActor
    private func mergeRemoteComments() async {
        guard let fresh = try? await env.postsService.fetchComments(postId: post.id) else { return }
        let known = Set(comments.map(\.id))
        let newOnes = fresh.filter { !known.contains($0.id) }
        var merged = fresh
        for temp in comments where pendingTempIds.contains(temp.id) {
            let echoed = newOnes.contains { $0.authorId == temp.authorId && $0.text == temp.text }
            if !echoed { merged.append(temp) }
        }
        guard merged != comments else { return }
        animated { comments = merged }
        if env.isSignedIn, !newOnes.isEmpty {
            let more = await env.postsService.fetchCommentReactions(commentIds: newOnes.map(\.id))
            commentReactions.removeAll { r in newOnes.contains { $0.id == r.commentId } }
            commentReactions.append(contentsOf: more)
        }
    }

    /// Re-read one comment's reactions. Skipped for a comment I'm toggling
    /// right now (my optimistic state is the truth until the write settles).
    @MainActor
    private func refreshReactions(for commentId: UUID) async {
        guard env.isSignedIn,
              comments.contains(where: { $0.id == commentId }),
              !reactionInFlight.contains(commentId) else { return }
        let fresh = await env.postsService.fetchCommentReactions(commentIds: [commentId])
        guard !reactionInFlight.contains(commentId) else { return }
        animated {
            commentReactions.removeAll { $0.commentId == commentId }
            commentReactions.append(contentsOf: fresh)
        }
    }

    /// Reply = drop an @mention of the author into the composer and focus it.
    @MainActor
    private func replyTo(_ comment: PostComment) {
        let tag = "@\(comment.authorName) "
        if !commentText.contains(tag) {
            commentText = commentText.isEmpty ? tag : commentText + (commentText.hasSuffix(" ") ? "" : " ") + tag
        }
        composerFocused = true
        Haptics.tap()
    }

    /// Author within the 24h window, or an admin anytime (RLS is the real gate).
    private func canDelete(_ comment: PostComment) -> Bool {
        guard env.isSignedIn else { return false }
        if env.isAdmin { return true }
        guard comment.authorId == env.currentProfile?.id else { return false }
        return Date.now.timeIntervalSince(comment.createdAt) <= 24 * 3600
    }

    private func deleteComment(_ comment: PostComment) async {
        do {
            try await env.postsService.deleteComment(commentId: comment.id)
            Haptics.tap()
            await MainActor.run { animated { comments.removeAll { $0.id == comment.id } } }
        } catch {
            print("[Comments] delete error: \(error)")
        }
    }

    private func reportComment(_ comment: PostComment) async {
        guard let userId = env.currentProfile?.id else { return }
        try? await env.postsService.reportContent(
            targetType: "post_comment",
            targetId: comment.id,
            reason: nil
        )
    }

    private func insertMention(_ profile: Profile) {
        commentText = applyMention(profile, to: commentText)
        mentionQuery = nil
    }

    /// Resolve "@First Last" tokens in the text to member ids (so the server can
    /// fire post_mention notifications). Matches the loaded member list by name.
    private func mentionedUserIds(in text: String) -> [UUID] {
        guard !allProfiles.isEmpty else { return [] }
        let lower = text.lowercased()
        var ids: [UUID] = []
        for p in allProfiles where !p.name.isEmpty {
            if lower.contains("@\(p.name.lowercased())") { ids.append(p.id) }
        }
        return Array(Set(ids))
    }

    // Fetch the member list via Supabase for @mention autocomplete.
    private func fetchMemberList() async throws -> [Profile] {
        let profiles: [Profile] = try await supabase
            .from("profiles")
            .select("id, display_name, avatar_url, is_admin, beta_tester, willing_to_help, intro_seen, email_alerts, push_level, push_types, notif_types, push_prompted, contact_email, created_at")
            .order("display_name", ascending: true)
            .execute()
            .value
        return profiles
    }
}

// MARK: - CommentRow

struct CommentRow: View {
    let comment: PostComment
    let isSignedIn: Bool
    let canReport: Bool
    var canDelete: Bool = false
    var reactions: [CommentReaction] = []
    var myUserId: UUID? = nil
    var canReact: Bool = false
    var onReact: ((String) async -> Void)? = nil
    let onReport: () async -> Void
    var onDelete: (() async -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPalette = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: comment.authorAvatarUrl, size: .small)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(displayName)
                        .font(.mlrScaled(13, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                    Text(MLRFormat.relativeTime(comment.createdAt))
                        .font(.caption2)
                        .foregroundStyle(Color.mlrTextMuted)
                    Spacer()
                    if canReact {
                        Button {
                            Haptics.tap()
                            if reduceMotion { showPalette.toggle() } else { withAnimation(MLRMotion.spring) { showPalette.toggle() } }
                        } label: {
                            Image(systemName: "face.smiling")
                                .font(.caption)
                                .foregroundStyle(showPalette ? Color.mlrPineText : Color.mlrTextMuted)
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("React")
                    }
                    if canReport || canDelete {
                        Menu {
                            if canDelete {
                                Button(role: .destructive) {
                                    Task { await onDelete?() }
                                } label: {
                                    Label("Delete comment", systemImage: "trash")
                                }
                            }
                            if canReport {
                                Button(role: .destructive) {
                                    Task { await onReport() }
                                } label: {
                                    Label("Report comment", systemImage: "flag")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.caption)
                                .foregroundStyle(Color.mlrTextMuted)
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                    }
                }
                if !comment.text.isEmpty {
                    MentionText(comment.text)
                        .font(.subheadline)
                        .foregroundStyle(Color.mlrText)
                }
                if !comment.mediaUrls.isEmpty {
                    CommentMediaRow(comment: comment)
                }
                reactionChips
            }
        }
    }

    // MARK: Reaction chips

    private var myEmoji: String? { reactions.first { $0.userId == myUserId }?.emoji }

    /// Emojis with counts, most used first (palette order breaks ties).
    private var chipSummary: [(emoji: String, count: Int)] {
        commentReactionEmojis.compactMap { e in
            let n = reactions.filter { $0.emoji == e }.count
            return n > 0 ? (e, n) : nil
        }
        .enumerated()
        .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
        .map(\.element)
    }

    @ViewBuilder
    private var reactionChips: some View {
        if !chipSummary.isEmpty || showPalette {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 6) {
                    ForEach(chipSummary, id: \.emoji) { item in
                        let mine = myEmoji == item.emoji
                        Button {
                            guard canReact else { return }
                            Task { await onReact?(item.emoji) }
                        } label: {
                            HStack(spacing: 3) {
                                Text(item.emoji).font(.mlrScaled(13))
                                Text("\(item.count)")
                                    .font(.mlrScaled(12, weight: .semibold))
                                    .foregroundStyle(mine ? Color.mlrPineText : Color.mlrTextMuted)
                                    .contentTransition(.numericText())
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(mine ? Color.mlrPrimary.mlrTint(0.12) : Color.secondary.opacity(0.08))
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(mine ? Color.mlrPrimary.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("\(item.emoji) \(item.count)\(mine ? ", you reacted" : "")")
                        // Long-press: who reacted with this emoji.
                        .contextMenu {
                            ForEach(reactions.filter { $0.emoji == item.emoji }) { r in
                                Text(r.userId == myUserId ? "You" : (r.name ?? "Member"))
                            }
                        }
                    }
                }
                if showPalette && canReact {
                    HStack(spacing: 2) {
                        ForEach(commentReactionEmojis, id: \.self) { emoji in
                            Button {
                                Task { await onReact?(emoji) }
                                if reduceMotion { showPalette = false } else { withAnimation(MLRMotion.spring) { showPalette = false } }
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 24))
                                    .padding(5)
                                    .background(myEmoji == emoji ? Color.mlrPrimary.mlrTint(0.12) : Color.clear)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(MLRChipFill())
                    .clipShape(Capsule())
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
                }
            }
            .padding(.top, 2)
        }
    }

    private var displayName: String {
        if !isSignedIn {
            return comment.authorName.components(separatedBy: " ").first ?? comment.authorName
        }
        return comment.authorName
    }
}

// MARK: - CommentMediaRow
// A small wrapping row of thumbnails for a comment's attachments (migration
// 0162) — deliberately lighter than a post's full-bleed MediaGrid/carousel,
// since this sits inline under a comment. Tapping opens the shared Lightbox,
// same as a post's own photos.

private struct CommentMediaRow: View {
    let comment: PostComment
    @State private var lightbox: CommentLightboxPresentation?

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(comment.mediaUrls.enumerated()), id: \.offset) { idx, url in
                let isVideo = idx < comment.mediaIsVideo.count && comment.mediaIsVideo[idx]
                Button { lightbox = CommentLightboxPresentation(startIndex: idx) } label: {
                    ZStack {
                        if isVideo {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.mlrCard)
                                .overlay(Image(systemName: "play.circle.fill").font(.mlrScaled(20)).foregroundStyle(Color.mlrTextMuted))
                        } else {
                            MediaThumb(url: url)
                        }
                    }
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.pressable)
            }
        }
        .fullScreenCover(item: $lightbox) { pres in
            LightboxView(urls: comment.mediaUrls, isVideo: comment.mediaIsVideo, startIndex: pres.startIndex)
        }
    }
}

private struct CommentLightboxPresentation: Identifiable {
    let startIndex: Int
    var id: Int { startIndex }
}

/// A simple wrapping row layout — no shared component exists yet, so this
/// mirrors the private copies already in CommitteeDetailView.swift /
/// HouseCalendarSheets.swift.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? max(0, x - spacing) : maxWidth,
                      height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x - bounds.minX + size.width > bounds.width && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - CommentSkeleton

struct CommentSkeleton: View {
    @State private var opacity: Double = 0.4

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.mlrCard)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(Color.mlrCard).frame(width: 90, height: 11)
                RoundedRectangle(cornerRadius: 4).fill(Color.mlrCard).frame(maxWidth: .infinity).frame(height: 11)
            }
        }
        .padding(.vertical, 4)
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                opacity = 1
            }
        }
    }
}

// AvatarView — Shared/Components/AvatarView.swift
// MentionText / MentionAutocomplete / detectMentionQuery / applyMention — Shared/Components/MentionText.swift
