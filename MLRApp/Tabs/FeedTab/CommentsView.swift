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

                Divider()

                if env.isSignedIn {
                    commentInput
                } else {
                    signInPrompt
                }
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
            // Pre-load member list for @mention autocomplete
            if env.isSignedIn {
                allProfiles = (try? await fetchMemberList()) ?? []
            }
        }
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
            if let imageUrl = post.imageUrl, let url = URL(string: imageUrl) {
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
            List {
                ForEach(comments) { comment in
                    CommentRow(
                        comment: comment,
                        isSignedIn: env.isSignedIn,
                        canReport: env.isSignedIn && comment.authorId != env.currentProfile?.id,
                        canDelete: canDelete(comment),
                        onReport: {
                            await reportComment(comment)
                        },
                        onDelete: {
                            await deleteComment(comment)
                        }
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
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
            .tint(Color.mlrPrimary)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            HStack(alignment: .bottom, spacing: 10) {
                AvatarView(url: env.currentProfile?.avatarUrl, size: .small)

                ZStack(alignment: .topLeading) {
                    if commentText.isEmpty {
                        Text("Add a comment…")
                            .foregroundStyle(Color.mlrTextSubtle)
                            .font(.subheadline)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                    }
                    TextEditor(text: $commentText)
                        .frame(minHeight: 36, maxHeight: 100)
                        .font(.subheadline)
                        .onChange(of: commentText) { _, val in
                            mentionQuery = detectMentionQuery(in: val)
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.mlrCard)
                .clipShape(RoundedRectangle(cornerRadius: 18))

                Button {
                    Task { await sendComment() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.mlrScaled(30))
                        .foregroundStyle(canSend ? Color.mlrPrimary : Color.mlrTextSubtle)
                }
                .disabled(!canSend || isSending)
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
        .background(Color.mlrSurface)
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
                .foregroundStyle(Color.mlrPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.mlrSurface)
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
    }

    @MainActor
    private func sendComment() async {
        guard let profile = env.currentProfile, canSend else { return }
        isSending = true
        sendError = nil
        let trimmed = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var media: [(path: String, type: String)] = []
            if !images.isEmpty || videoData != nil {
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
            }
            let comment = try await env.postsService.addComment(
                postId: post.id,
                text: trimmed,
                authorId: profile.id,
                mentionedIds: mentionedUserIds(in: trimmed),
                media: media
            )
            comments.append(comment)
            images = []; selectedPhotos = []; videoData = nil; selectedVideo = nil
            commentText = ""
            mentionQuery = nil
        } catch {
            sendError = "Couldn't post comment. Please try again."
        }
        isUploading = false
        isSending = false
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
            comments.removeAll { $0.id == comment.id }
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
    let onReport: () async -> Void
    var onDelete: (() async -> Void)? = nil

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
            }
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
