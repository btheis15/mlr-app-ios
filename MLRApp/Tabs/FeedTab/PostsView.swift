import SwiftUI

// MARK: - PostsView
// The main Feed tab. Mirrors components/PostsView.tsx.
//
// Layout:
//   • Driven by env.postsService.posts (an @Observable array)
//   • Pull-to-refresh (.refreshable)
//   • Floating "new post" pencil button (signed-in only)
//   • SignInWall is not used here — the feed is fully browsable;
//     compose is conditionally shown when signed in
//   • Realtime subscription fires in .task

struct PostsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var showComposer = false
    @State private var showSignIn = false
    @State private var showTaggedOnly = false
    @State private var reactionMap: [UUID: [PostReaction]] = [:]

    // Committee chats reachable from the Feed (pills), matching the web.
    @State private var myCommittees: [Committee] = []
    @State private var committeeUnread: [UUID: Int] = [:]

    private var displayedPosts: [Post] {
        guard showTaggedOnly, let myId = env.currentProfile?.id else { return env.postsService.posts }
        return env.postsService.posts.filter { post in post.tags.contains { $0.id == myId } }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if env.isSignedIn && !myCommittees.isEmpty {
                    committeePills
                }
                ZStack(alignment: .bottomTrailing) {
                    content

                    if env.isSignedIn {
                        composeButton
                    }
                }
            }
            .navigationTitle("Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if env.isSignedIn {
                        Button {
                            withAnimation { showTaggedOnly.toggle() }
                        } label: {
                            Label("Tagged me", systemImage: showTaggedOnly ? "tag.fill" : "tag")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(showTaggedOnly ? Color.mlrPrimary : Color.mlrTextMuted)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !env.isSignedIn {
                        Button("Sign in") { showSignIn = true }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.mlrPrimary)
                    }
                }
            }
        }
        .sheet(isPresented: $showComposer, onDismiss: {
            Task { await env.postsService.fetchPosts(userId: env.currentProfile?.id) }
        }) {
            PostComposer()
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
        }
        .task {
            await env.postsService.fetchPosts(userId: env.currentProfile?.id)
            await fetchReactions(for: env.postsService.posts)
            env.postsService.subscribeToRealtime()
            await loadCommittees()
        }
        .onChange(of: env.postsService.posts) { _, newPosts in
            Task { await fetchReactions(for: newPosts) }
        }
    }

    // MARK: - Committee chat pills

    private var committeePills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // The Posts feed is the active tab here.
                pill(label: "📰 Posts", active: true, unread: 0)

                ForEach(myCommittees) { committee in
                    NavigationLink {
                        CommitteeChatLoader(committee: committee)
                    } label: {
                        pill(
                            label: "\(committee.emoji ?? "💬") \(committee.name)",
                            active: false,
                            unread: committeeUnread[committee.id] ?? 0
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.mlrSurface)
    }

    private func pill(label: String, active: Bool, unread: Int) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.mlrDanger)
                    .clipShape(Capsule())
            }
        }
        .foregroundStyle(active ? .white : Color.mlrPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(active ? Color.mlrPrimary : Color.mlrPrimary.opacity(0.1))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.mlrPrimary.opacity(active ? 0 : 0.25), lineWidth: 1))
    }

    private func loadCommittees() async {
        guard env.isSignedIn, let uid = env.currentProfile?.id else {
            myCommittees = []
            committeeUnread = [:]
            return
        }
        if env.committeeService.committees.isEmpty {
            await env.committeeService.fetchCommittees()
        }
        // Membership lives in the roster now (migration 0057).
        let mySlugs = await env.committeeService.fetchMyCommitteeSlugs(userId: uid)
        myCommittees = env.committeeService.committees.filter { mySlugs.contains($0.slug) }
        committeeUnread = await env.committeeService.fetchUnreadByCommittee(
            userId: uid, committeeIds: myCommittees.map(\.id)
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if env.postsService.isLoading && env.postsService.posts.isEmpty {
            loadingState
        } else if env.postsService.posts.isEmpty {
            emptyState
        } else {
            feedList
        }
    }

    private var feedList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(displayedPosts) { post in
                    postRow(for: post)
                }
            }
            .padding(.top, 8)
        }
        .refreshable {
            await env.postsService.fetchPosts(userId: env.currentProfile?.id)
        }
    }

    private func postRow(for post: Post) -> some View {
        VStack(spacing: 0) {
            PostCard(
                post: post,
                reactions: reactionMap[post.id] ?? [],
                onReactionToggle: { emoji in
                    await toggleReaction(post: post, emoji: emoji)
                },
                onReport: {
                    await reportPost(post)
                },
                onAdminRemove: env.isAdmin
                    ? ({ await adminRemove(post) } as (@MainActor () async -> Void))
                    : nil
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider().padding(.horizontal, 16)
        }
    }

    private var loadingState: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { _ in
                    PostCardSkeleton()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    Divider().padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "rectangle.stack")
                .font(.system(size: 44))
                .foregroundStyle(Color.mlrTextSubtle)
            Text("Nothing here yet")
                .font(.headline)
                .foregroundStyle(Color.mlrText)
            Text("Be the first to share something with the family.")
                .font(.subheadline)
                .foregroundStyle(Color.mlrTextMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if env.isSignedIn {
                Button {
                    showComposer = true
                } label: {
                    Text("Write a post")
                }
                .buttonStyle(.glassPrimary)
                .padding(.horizontal, 40)
            }
            Spacer()
        }
    }

    private var composeButton: some View {
        Button {
            showComposer = true
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .buttonStyle(.glassCircle())
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }

    // MARK: - Reactions

    @MainActor
    private func fetchReactions(for posts: [Post]) async {
        for post in posts {
            if let reactions = try? await env.postsService.fetchReactions(postId: post.id) {
                reactionMap[post.id] = reactions
            }
        }
    }

    private func toggleReaction(post: Post, emoji: String) async {
        guard let userId = env.currentProfile?.id else { return }
        let existing = reactionMap[post.id] ?? []
        // One reaction per user per post (composite PK): tapping the current
        // emoji removes it; tapping a different one switches it.
        let myReaction = existing.first(where: { $0.userId == userId })
        let isRemoving = myReaction?.emoji == emoji
        let withoutMine = existing.filter { $0.userId != userId }

        // Optimistic update
        if isRemoving {
            reactionMap[post.id] = withoutMine
        } else {
            let optimistic = PostReaction(
                postId: post.id, userId: userId,
                emoji: emoji, createdAt: .now
            )
            reactionMap[post.id] = withoutMine + [optimistic]
        }

        do {
            if isRemoving {
                try await env.postsService.removeReaction(postId: post.id, emoji: emoji, userId: userId)
            } else {
                try await env.postsService.addReaction(postId: post.id, emoji: emoji, userId: userId)
            }
            // Refetch authoritative state
            if let fresh = try? await env.postsService.fetchReactions(postId: post.id) {
                reactionMap[post.id] = fresh
            }
        } catch {
            // Roll back optimistic update
            if let fresh = try? await env.postsService.fetchReactions(postId: post.id) {
                reactionMap[post.id] = fresh
            }
        }
    }

    private func reportPost(_ post: Post) async {
        try? await env.postsService.reportContent(
            targetType: "post",
            targetId: post.id,
            reason: nil
        )
    }

    private func adminRemove(_ post: Post) async {
        // The web app uses set_content_status RPC; the iOS PostsService doesn't expose it yet.
        // Call the Supabase RPC directly until PostsService gains this method.
        struct StatusParams: Encodable {
            let p_target_type: String
            let p_target_id: String
            let p_status: String
        }
        try? await supabase
            .rpc("set_content_status", params: StatusParams(
                p_target_type: "post",
                p_target_id: post.id.uuidString,
                p_status: "hidden"
            ))
            .execute()
        await env.postsService.fetchPosts(userId: env.currentProfile?.id)
    }
}

// MARK: - Committee Chat Loader
// Pushed from a Feed pill: loads the committee's members (for @mentions) then
// shows the existing chat view. Keeps CommitteeChatView unchanged.

private struct CommitteeChatLoader: View {
    @Environment(AppEnvironment.self) private var env
    let committee: Committee
    @State private var members: [CommitteeMember] = []

    var body: some View {
        CommitteeChatView(committee: committee, members: members)
            .task {
                members = (try? await env.committeeService.fetchMembers(committeeId: committee.id)) ?? []
            }
    }
}
