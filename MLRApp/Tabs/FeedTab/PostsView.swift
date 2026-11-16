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

/// What a row can do, built from what each room type's service actually supports
/// (committee/house/event chats: mute + mark read; Main Feed: mute only).
private struct RowActions {
    var unread: Int
    var muted: Bool
    var toggleMute: () -> Void
    var markRead: (() -> Void)?
}

private extension View {
    /// Leading "Mark read" / trailing "Mute" swipe actions plus the same pair in
    /// the long-press menu. No-op when `actions` is nil (archived rooms, preview).
    @ViewBuilder
    func conversationActions(_ actions: RowActions?) -> some View {
        if let actions {
            self
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if let markRead = actions.markRead, actions.unread > 0 {
                        Button(action: markRead) {
                            Label("Mark read", systemImage: "checkmark.message")
                        }
                        .tint(Color.mlrPrimary)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(action: actions.toggleMute) {
                        Label(actions.muted ? "Unmute" : "Mute",
                              systemImage: actions.muted ? "bell.fill" : "bell.slash.fill")
                    }
                    .tint(actions.muted ? Color.mlrPrimary : Color.mlrTextMuted)
                }
                .contextMenu {
                    if let markRead = actions.markRead, actions.unread > 0 {
                        Button(action: markRead) {
                            Label("Mark as read", systemImage: "checkmark.message")
                        }
                    }
                    Button(action: actions.toggleMute) {
                        Label(actions.muted ? "Unmute" : "Mute",
                              systemImage: actions.muted ? "bell.fill" : "bell.slash.fill")
                    }
                }
        } else {
            self
        }
    }
}

private struct ConversationsList: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    let channels: [ChatChannel]
    let house: House?

    @State private var summaries: [String: ChannelSummary] = [:]
    /// Source/destination pair for the zoom transition from a row into its chat.
    @Namespace private var zoom

    private func houseKey(_ id: UUID) -> String { "house-\(id.uuidString)" }
    private var motion: Animation? { MLRMotion.reduceMotion ? nil : MLRMotion.spring }
    /// Writes (mute / read) are never made while an admin previews as someone else.
    private var canWrite: Bool { !env.isPreviewing }

    /// Most recent activity first within a section; ties and never-active rooms
    /// keep their original (alphabetical) order.
    private func byActivity(_ list: [ChatChannel]) -> [ChatChannel] {
        list.enumerated().sorted { a, b in
            let da = summaries[a.element.id]?.lastAt ?? .distantPast
            let db = summaries[b.element.id]?.lastAt ?? .distantPast
            return da != db ? da > db : a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            // Main Feed pinned on top.
            NavigationLink {
                MainFeedView(title: "Main Feed")
                    .navigationTransition(.zoom(sourceID: "feed", in: zoom))
            } label: {
                ConversationRow(
                    emoji: "📰",
                    title: "Main Feed",
                    subtitle: "Everyone",
                    summary: env.feedMuteService.isMuted
                        ? ChannelSummary(lastText: nil, lastAt: nil, unread: 0, muted: true)
                        : nil
                )
                .matchedTransitionSource(id: "feed", in: zoom)
            }
            .id("conversations-top")
            .conversationActions(canWrite ? RowActions(
                unread: 0, muted: env.feedMuteService.isMuted,
                toggleMute: toggleFeedMute, markRead: nil) : nil)

            if let house {
                Section("Your house") {
                    NavigationLink {
                        HouseChatView(house: house, assumeMember: true)
                            .navigationTransition(.zoom(sourceID: houseKey(house.id), in: zoom))
                    } label: {
                        ConversationRow(
                            emoji: house.emoji,
                            title: house.name,
                            subtitle: "Your house",
                            summary: summaries[houseKey(house.id)]
                        )
                        .matchedTransitionSource(id: houseKey(house.id), in: zoom)
                    }
                    .conversationActions(canWrite ? houseActions(house) : nil)
                }
            }

            // Event chats — one per event you're going to (migration 0216).
            // Their own section, because they're transient in a way committee
            // rooms aren't: each one archives itself 7 days after its event.
            let eventChats = env.eventChatService.liveChats
            if !eventChats.isEmpty {
                Section("Events you're going to") {
                    ForEach(eventChats) { chat in
                        NavigationLink {
                            EventChatView(chat: chat)
                                .navigationTransition(.zoom(sourceID: "event-\(chat.eventId)", in: zoom))
                        } label: {
                            ConversationRow(
                                emoji: chat.emoji ?? "📅",
                                title: chat.title ?? "Event",
                                subtitle: chat.canPost
                                    ? "Just the people going"
                                    : "Reading along — RSVP to join in",
                                summary: ChannelSummary(
                                    lastText: nil, lastAt: chat.lastAt,
                                    unread: chat.unread, muted: chat.isMuted)
                            )
                            .matchedTransitionSource(id: "event-\(chat.eventId)", in: zoom)
                        }
                        .conversationActions(canWrite ? eventActions(chat) : nil)
                    }
                }
            }

            let live = channels.filter { !$0.isArchived }
            let archived = channels.filter { $0.isArchived }

            // Mirror the web Feed grouping: Lead chats → Full helping crew → Roles.
            let leadChats    = byActivity(live.filter { $0.area?.lowercased() == "leads" })
            let generalChats = byActivity(live.filter { $0.area == nil })
            let roleChats    = byActivity(live.filter { let a = $0.area; return a != nil && a?.lowercased() != "leads" })

            if !leadChats.isEmpty {
                Section("Lead chats") {
                    ForEach(leadChats) { channelLink($0) }
                }
            }
            if !generalChats.isEmpty {
                Section("Full helping crew") {
                    ForEach(generalChats) { channelLink($0) }
                }
            }
            if !roleChats.isEmpty {
                Section("Roles & subcommittees") {
                    ForEach(roleChats) { channelLink($0) }
                }
            }

            // Archived committee/role chats stay reachable (read-only) under a
            // quiet disclosure at the foot of the list (migration 0112).
            let archivedEventChats = env.eventChatService.archivedChats
            if !archived.isEmpty || !archivedEventChats.isEmpty {
                Section {
                    DisclosureGroup("Archived chats") {
                        ForEach(archived) { channelLink($0, actionable: false) }
                        // A finished event's room is kept as a read-only record
                        // rather than deleted — the 7-day tail exists so
                        // last-minute details can still land after the weekend.
                        ForEach(archivedEventChats) { chat in
                            NavigationLink {
                                EventChatView(chat: chat)
                                    .navigationTransition(.zoom(sourceID: "event-\(chat.eventId)", in: zoom))
                            } label: {
                                ConversationRow(
                                    emoji: chat.emoji ?? "📅",
                                    title: chat.title ?? "Event",
                                    subtitle: "Finished",
                                    summary: nil
                                )
                                .matchedTransitionSource(id: "event-\(chat.eventId)", in: zoom)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Rows glide to their new place when a message re-ranks a room.
        .animation(motion, value: summaries)
        .animation(motion, value: env.eventChatService.liveChats.map(\.eventId))
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSummaries()
            await env.eventChatService.loadChats()
        }
        .refreshable {
            await loadSummaries()
            await env.eventChatService.loadChats()
        }
        // Quietly pick up messages that arrived while the app was in the background.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await loadSummaries()
                await env.eventChatService.loadChats()
            }
        }
        // Tapping the Feed tab again scrolls back to the top of the list.
        .onReceive(NotificationCenter.default.publisher(for: .tabReselected)) { note in
            guard (note.object as? Tab) == .feed else { return }
            withAnimation(motion) { proxy.scrollTo("conversations-top", anchor: .top) }
        }
        }
    }

    @ViewBuilder
    private func channelLink(_ channel: ChatChannel, actionable: Bool = true) -> some View {
        NavigationLink {
            ChannelChatLoader(channel: channel)
                .navigationTransition(.zoom(sourceID: channel.id, in: zoom))
        } label: {
            ConversationRow(
                emoji: channel.committee.emoji ?? "💬",
                title: displayTitle(for: channel),
                subtitle: displaySubtitle(for: channel),
                summary: summaries[channel.id]
            )
            .matchedTransitionSource(id: channel.id, in: zoom)
        }
        .conversationActions(actionable && canWrite ? channelActions(channel) : nil)
    }

    private func displayTitle(for channel: ChatChannel) -> String {
        switch channel.area?.lowercased() {
        case "leads":
            return channel.committee.name  // section header says "Lead chats"
        case nil:
            return channel.committee.name  // section header says "Full helping crew"
        default:
            return channel.title           // area name (e.g. "Meals")
        }
    }

    private func displaySubtitle(for channel: ChatChannel) -> String? {
        switch channel.area?.lowercased() {
        case "leads", nil:
            return nil                     // committee name already in the title
        default:
            return channel.committee.name  // "Family Fest" under "Meals"
        }
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

    // MARK: Row actions (optimistic, with a read-back to roll a failed write back)

    private func setLocal(_ key: String, _ change: (inout ChannelSummary) -> Void) {
        withAnimation(motion) {
            var s = summaries[key] ?? ChannelSummary(lastText: nil, lastAt: nil, unread: 0)
            change(&s)
            summaries[key] = s
        }
    }

    private func channelActions(_ channel: ChatChannel) -> RowActions {
        let s = summaries[channel.id]
        let cid = channel.committee.id
        return RowActions(
            unread: s?.unread ?? 0,
            muted: s?.muted ?? false,
            toggleMute: {
                let new = !(s?.muted ?? false)
                Haptics.tap()
                setLocal(channel.id) { $0.muted = new }
                Task {
                    await env.committeeService.setAreaMute(committeeId: cid, area: channel.area, muted: new)
                    let actual = await env.committeeService.isAreaMuted(committeeId: cid, area: channel.area)
                    setLocal(channel.id) { $0.muted = actual }
                }
            },
            markRead: {
                Haptics.tap()
                setLocal(channel.id) { $0.unread = 0 }
                Task {
                    await env.committeeService.markAreaRead(committeeId: cid, area: channel.area)
                    if let uid = env.currentProfile?.id {
                        summaries[channel.id] = await env.committeeService.fetchChannelSummary(
                            committeeId: cid, area: channel.area, userId: uid)
                    }
                }
            })
    }

    private func houseActions(_ house: House) -> RowActions {
        let key = houseKey(house.id)
        let s = summaries[key]
        return RowActions(
            unread: s?.unread ?? 0,
            muted: s?.muted ?? false,
            toggleMute: {
                let new = !(s?.muted ?? false)
                Haptics.tap()
                setLocal(key) { $0.muted = new }
                Task {
                    await env.housesService.setHouseMute(houseId: house.id, muted: new)
                    let actual = await env.housesService.isHouseMuted(houseId: house.id)
                    setLocal(key) { $0.muted = actual }
                }
            },
            markRead: {
                Haptics.tap()
                setLocal(key) { $0.unread = 0 }
                Task {
                    await env.housesService.markRead(houseId: house.id)
                    if let uid = env.currentProfile?.id {
                        summaries[key] = await env.housesService.fetchChannelSummary(
                            houseId: house.id, userId: uid)
                    }
                }
            })
    }

    private func eventActions(_ chat: EventChatSummary) -> RowActions {
        RowActions(
            unread: chat.unread,
            muted: chat.isMuted,
            toggleMute: {
                Haptics.tap()
                // setMute reloads the list itself, so the bell flips when it lands.
                Task { await env.eventChatService.setMute(eventId: chat.eventId, muted: !chat.isMuted) }
            },
            markRead: {
                Haptics.tap()
                Task {
                    await env.eventChatService.markRead(eventId: chat.eventId)
                    await env.eventChatService.loadChats()
                }
            })
    }

    private func toggleFeedMute() {
        Haptics.tap()
        let new = !env.feedMuteService.isMuted
        Task { await env.feedMuteService.setMuted(new) }
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
                            .transition(.scale.combined(with: .opacity))
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
                            .monospacedDigit()
                            .numericTransition()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(summary?.muted == true ? Color.mlrTextSubtle : Color.mlrDanger)
                            .clipShape(Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .animation(MLRMotion.reduceMotion ? nil : MLRMotion.spring, value: summary)
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
    @State private var adminRemoveError: String? = nil
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
        .alert("Couldn't remove post", isPresented: Binding(
            get: { adminRemoveError != nil },
            set: { if !$0 { adminRemoveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(adminRemoveError ?? "")
        }
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
                } else {
                    feedMuteBell
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
            await env.feedMuteService.load()
        }
        .onChange(of: env.postsService.posts) { _, newPosts in
            Task { await fetchReactions(for: newPosts) }
        }
    }

    // MARK: - Feed mute (migration 0214)
    //
    // The Family Feed is the noisiest surface in the app and was the only one
    // with no bell of its own. Durations write ONLY `muted_until`, so the timer
    // expires by going stale — see FeedMuteService for why writing both columns
    // muted people permanently for months.

    private var feedMuteBell: some View {
        Menu {
            if env.feedMuteService.isMuted {
                if let label = env.feedMuteService.muteLabel {
                    Text(label)
                }
                Button("Unmute the feed") {
                    Task { await env.feedMuteService.setMuted(false) }
                }
            } else {
                Button("Mute for 1 hour") { mute(hours: 1) }
                Button("Mute for 8 hours") { mute(hours: 8) }
                Button("Mute for 1 day") { mute(hours: 24) }
                Button("Mute for a week") { mute(hours: 24 * 7) }
                Divider()
                Button("Mute until I turn it back on") {
                    Task { await env.feedMuteService.setMuted(true) }
                }
            }
        } label: {
            Image(systemName: env.feedMuteService.isMuted ? "bell.slash.fill" : "bell")
                .font(.mlrScaled(15))
                .foregroundStyle(env.feedMuteService.isMuted ? Color.mlrPrimary : Color.mlrTextMuted)
        }
        .accessibilityLabel(env.feedMuteService.isMuted ? "Feed muted" : "Mute the feed")
    }

    private func mute(hours: Int) {
        let until = Calendar.current.date(byAdding: .hour, value: hours, to: .now)
        Task { await env.feedMuteService.setMuted(true, until: until) }
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
        // Fade/scale/rise as each post crosses into view — the Feed was the one
        // major list with zero motion; matches the same treatment Events/Family
        // Fest already had. No-op under Reduce Motion.
        .scrollEntrance()
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
            let p_entity_type: String
            let p_entity_id: String
            let p_status: String
        }
        do {
            try await supabase
                .rpc("set_content_status", params: StatusParams(
                    p_entity_type: "post",
                    p_entity_id: post.id.uuidString,
                    p_status: "hidden"
                ))
                .execute()
        } catch {
            adminRemoveError = "The post wasn't removed. Please try again."
            return
        }
        await env.postsService.fetchPosts(userId: env.currentProfile?.id)
    }
}
