import SwiftUI
import Kingfisher

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

    private let charLimit = 300

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
                        onReport: {
                            await reportComment(comment)
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

    private var canSend: Bool {
        !commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && commentText.count <= charLimit
        && !isSending
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
            let comment = try await env.postsService.addComment(
                postId: post.id,
                text: trimmed,
                authorId: profile.id,
                mentionedIds: mentionedUserIds(in: trimmed)
            )
            comments.append(comment)
            commentText = ""
            mentionQuery = nil
        } catch {
            sendError = "Couldn't post comment. Please try again."
        }
        isSending = false
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
    let onReport: () async -> Void

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
                    if canReport {
                        Menu {
                            Button(role: .destructive) {
                                Task { await onReport() }
                            } label: {
                                Label("Report comment", systemImage: "flag")
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
                MentionText(comment.text)
                    .font(.subheadline)
                    .foregroundStyle(Color.mlrText)
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
