import SwiftUI

// MARK: - PostsView (Feed tab root)
//
// A Messages-style router: if the member has committee chat channels, the Feed
// tab shows a conversation LIST — "Main Feed" pinned on top, then one row per
// role channel they're in (Family Fest → "General", "Meals", …). Tapping a row
// opens that chat. If they have no channels (or aren't signed in), the Feed tab
// drops straight into the Main Feed — no redundant one-row list.

struct PostsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var channels: [ChatChannel] = []

    // The member's house comes from the observed service value (resolved on profile
    // load) so the "Your house" row shows reliably; reading it in `showList` also
    // re-renders the body when it arrives, which re-fires the channels task below.
    private var myHouse: House? { env.housesService.myHouse }
    private var showList: Bool { env.isSignedIn && (!channels.isEmpty || myHouse != nil) }

    var body: some View {
        NavigationStack {
            Group {
                if showList {
                    ConversationsList(channels: channels, house: myHouse)
                } else {
                    MainFeedView(title: "Feed")
                }
            }
        }
        // Keyed on the signed-in user id so it (re)loads once the profile finishes
        // loading after launch — not just on the first appear when it may still be nil.
        .task(id: env.currentProfile?.id) {
            guard let uid = env.currentProfile?.id, env.isSignedIn else { return }
            channels = await env.committeeService.fetchMyChannels(userId: uid)
        }
    }
}

// MARK: - Conversations list

private struct ConversationsList: View {
    @Environment(AppEnvironment.self) private var env
    let channels: [ChatChannel]
    let house: House?

    @State private var summaries: [String: ChannelSummary] = [:]

    private func houseKey(_ id: UUID) -> String { "house-\(id.uuidString)" }

    var body: some View {
        List {
            // Main Feed pinned on top.
            NavigationLink {
                MainFeedView(title: "Main Feed")
            } label: {
                ConversationRow(
                    emoji: "📰",
                    title: "Main Feed",
                    subtitle: "Everyone",
                    summary: nil
                )
            }

            if let house {
                Section("Your house") {
                    NavigationLink {
                        HouseChatView(house: house, assumeMember: true)
                    } label: {
                        ConversationRow(
                            emoji: house.emoji,
                            title: house.name,
                            subtitle: "Your house",
                            summary: summaries[houseKey(house.id)]
                        )
                    }
                }
            }

            if !channels.isEmpty {
                Section("Committee chats") {
                    ForEach(channels) { channel in
                        NavigationLink {
                            ChannelChatLoader(channel: channel)
                        } label: {
                            ConversationRow(
                                emoji: channel.committee.emoji ?? "💬",
                                title: channel.title,
                                subtitle: channel.subtitle,
                                summary: summaries[channel.id]
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSummaries() }
        .refreshable { await loadSummaries() }
    }

    private func loadSummaries() async {
        guard let uid = env.currentProfile?.id else { return }
        if let house {
            summaries[houseKey(house.id)] = await env.housesService.fetchChannelSummary(
                houseId: house.id, userId: uid)
        }
        for channel in channels {
            summaries[channel.id] = await env.committeeService.fetchChannelSummary(
                committeeId: channel.committee.id, area: channel.area, userId: uid)
        }
    }
}

// MARK: - Conversation row

private struct ConversationRow: View {
    let emoji: String
    let title: String
    let subtitle: String?
    let summary: ChannelSummary?

    var body: some View {
        HStack(spacing: 12) {
            Text(emoji)
                .font(.mlrScaled(24))
                .frame(width: 46, height: 46)
                .background(Color.mlrPrimary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.mlrScaled(16, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                    if summary?.muted == true {
                        Image(systemName: "bell.slash.fill")
                            .font(.mlrScaled(10))
                            .foregroundStyle(Color.mlrTextSubtle)
                    }
                    Spacer()
                    if let at = summary?.lastAt {
                        Text(Self.relative(at))
                            .font(.mlrScaled(11))
                            .foregroundStyle(Color.mlrTextMuted)
                    }
                }
                HStack(spacing: 6) {
                    Text(summary?.lastText ?? subtitle ?? "")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrTextMuted)
                        .lineLimit(1)
                    Spacer()
                    if let unread = summary?.unread, unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.mlrScaled(11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(summary?.muted == true ? Color.mlrTextSubtle : Color.mlrDanger)
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Compact "when" label for the last message.
    static func relative(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Channel chat loader
// Loads the committee's members (for @mention autocomplete) then shows the
// area-scoped chat. Membership is known (the channel came from the user's own
// roster), so we skip the members-only gate.

private struct ChannelChatLoader: View {
    @Environment(AppEnvironment.self) private var env
    let channel: ChatChannel
    @State private var members: [CommitteeMember] = []

    var body: some View {
        CommitteeChatView(
            committee: channel.committee,
            members: members,
            area: channel.area,
            channelTitle: channel.title,
            assumeMember: true
        )
        .task {
            members = (try? await env.committeeService.fetchMembers(committeeId: channel.committee.id)) ?? []
        }
    }
}

// MARK: - MainFeedView (the multimedia posts feed)
// The resort-wide feed: posts with photos/video, reactions, comments, tags.
// Extracted from the old Feed tab so it can be the top "Main Feed" conversation.

struct MainFeedView: View {
    @Environment(AppEnvironment.self) private var env
    var title: String = "Main Feed"

    @State private var showComposer = false
    @State private var showSignIn = false
    @State private var showTaggedOnly = false
    @State private var reactionMap: [UUID: [PostReaction]] = [:]

    private var displayedPosts: [Post] {
        guard showTaggedOnly, let myId = env.currentProfile?.id else { return env.postsService.posts }
        return env.postsService.posts.filter { post in post.tags.contains { $0.id == myId } }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            if env.isSignedIn {
                composeButton
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if env.isSignedIn {
                    Button {
                        withAnimation { showTaggedOnly.toggle() }
                    } label: {
                        Label("Tagged me", systemImage: showTaggedOnly ? "tag.fill" : "tag")
                            .font(.mlrScaled(14, weight: .medium))
                            .foregroundStyle(showTaggedOnly ? Color.mlrPrimary : Color.mlrTextMuted)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if !env.isSignedIn {
                    Button("Sign in") { showSignIn = true }
                        .font(.mlrScaled(15, weight: .medium))
                        .foregroundStyle(Color.mlrPrimary)
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
        }
        .onChange(of: env.postsService.posts) { _, newPosts in
            Task { await fetchReactions(for: newPosts) }
        }
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
                .font(.mlrScaled(44))
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
        .accessibilityLabel("New post")
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
        let myReaction = existing.first(where: { $0.userId == userId })
        let isRemoving = myReaction?.emoji == emoji
        let withoutMine = existing.filter { $0.userId != userId }

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
            if let fresh = try? await env.postsService.fetchReactions(postId: post.id) {
                reactionMap[post.id] = fresh
            }
        } catch {
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
