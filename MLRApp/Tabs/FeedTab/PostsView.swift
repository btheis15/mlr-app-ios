import SwiftUI
import Kingfisher

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
        .mlrBackdrop()
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
    func conversationActions(_ actions: RowActions?) -> some View {
        conversationActionsInner(actions)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }

    @ViewBuilder
    private func conversationActionsInner(_ actions: RowActions?) -> some View {
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
            CardLink {
                MainFeedView(title: "Main Feed")
                    .navigationTransition(.zoom(sourceID: "feed", in: zoom))
            } label: {
                ConversationRow(
                    emoji: "📰",
                    accent: .mlrPrimary,
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
                Section(header: SectionHeader("Your house").textCase(nil)) {
                    CardLink {
                        HouseChatView(house: house, assumeMember: true)
                            .navigationTransition(.zoom(sourceID: houseKey(house.id), in: zoom))
                    } label: {
                        ConversationRow(
                            emoji: house.emoji,
                            accent: .mlrLake,
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
                Section(header: SectionHeader("Events you're going to").textCase(nil)) {
                    ForEach(eventChats) { chat in
                        CardLink {
                            EventChatView(chat: chat)
                                .navigationTransition(.zoom(sourceID: "event-\(chat.eventId)", in: zoom))
                        } label: {
                            ConversationRow(
                                emoji: chat.emoji ?? "📅",
                                accent: .mlrCampfire,
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
                Section(header: SectionHeader("Lead chats").textCase(nil)) {
                    ForEach(leadChats) { channelLink($0) }
                }
            }
            if !generalChats.isEmpty {
                Section(header: SectionHeader("Full helping crew").textCase(nil)) {
                    ForEach(generalChats) { channelLink($0) }
                }
            }
            if !roleChats.isEmpty {
                Section(header: SectionHeader("Roles & subcommittees").textCase(nil)) {
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
                            CardLink {
                                EventChatView(chat: chat)
                                    .navigationTransition(.zoom(sourceID: "event-\(chat.eventId)", in: zoom))
                            } label: {
                                ConversationRow(
                                    emoji: chat.emoji ?? "📅",
                                accent: .mlrCampfire,
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listRowSpacing(8)
        .mlrBackdrop()
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
        CardLink {
            ChannelChatLoader(channel: channel)
                .navigationTransition(.zoom(sourceID: channel.id, in: zoom))
        } label: {
            ConversationRow(
                emoji: channel.committee.emoji ?? "💬",
                accent: .mlrPrimary,
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
    var accent: Color = .mlrPrimary
    let title: String
    let subtitle: String?
    let summary: ChannelSummary?

    var body: some View {
        let unread = summary?.unread ?? 0
        let hasUnread = unread > 0
        MLRCard(.plain, padding: 14) {
            HStack(spacing: 14) {
                IconTile(emoji: emoji, accent: accent, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 15, weight: hasUnread ? .bold : .semibold))
                            .foregroundStyle(Color.mlrText)
                            .lineLimit(1)
                        if summary?.muted == true {
                            Image(systemName: "bell.slash.fill")
                                .font(.mlrScaled(12))
                                .foregroundStyle(Color.mlrTextSubtle)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Spacer(minLength: 4)
                        if let at = summary?.lastAt {
                            Text(Self.relative(at))
                                .font(.mlrCaption13)
                                .foregroundStyle(hasUnread ? Color.mlrPrimary : Color.mlrTextMuted)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(summary?.lastText ?? subtitle ?? "")
                            .font(.mlrSecondary)
                            .foregroundStyle(hasUnread ? Color.mlrText : Color.mlrTextMuted)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if hasUnread {
                            Text(unread > 99 ? "99+" : "\(unread)")
                                .font(.mlrScaled(13, weight: .bold))
                                .monospacedDigit()
                                .numericTransition()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(summary?.muted == true ? Color.mlrTextSubtle : Color.mlrPrimary)
                                .clipShape(Capsule())
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mlrTextSubtle)
                    .accessibilityHidden(true)
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

/// Last-known page one (posts + their reactions) for instant paint on open.
private struct FeedSnapshot: Codable, Sendable {
    var posts: [Post]
    var reactions: [PostReaction]
}

struct MainFeedView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    var title: String = "Main Feed"

    @State private var showComposer = false
    @State private var showSignIn = false
    @State private var showTaggedOnly = false
    @State private var adminRemoveError: String? = nil
    @State private var reactionMap: [UUID: [PostReaction]] = [:]
    /// Posts whose reaction toggle is in flight (a batch refresh must not clobber the optimistic state).
    @State private var togglingPosts: Set<UUID> = []
    @State private var isAtTop = true
    @State private var prefetchedPostIds: Set<UUID> = []

    private static let staleAfter: TimeInterval = 60
    private var feedAnimation: Animation? { MLRMotion.reduceMotion ? nil : MLRMotion.spring }
    private var snapshotKey: String { DiskCache.key("main-feed", user: env.effectiveUserId) }

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
        .mlrBackdrop()
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
            // Fetch on first load only; later appearances (e.g. back from a
            // post) keep the list and its scroll position untouched. Foreground,
            // pull-to-refresh and realtime cover freshness.
            Task { await env.feedMuteService.load() }
            env.postsService.subscribeToRealtime()
            if env.postsService.lastRefreshAt == nil { await initialLoad() }
        }
        // After every completed fetch/page: batch-load reactions for what is
        // loaded (one query), then snapshot page one for the next cold start.
        .task(id: env.postsService.dataVersion) {
            await refreshReactions()
            saveSnapshot()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let last = env.postsService.lastRefreshAt,
                  Date.now.timeIntervalSince(last) > Self.staleAfter else { return }
            Task { await env.postsService.fetchPosts(userId: env.currentProfile?.id, holdNew: env.postsService.holdNewPosts) }
        }
    }

    // MARK: - Loading

    /// Paint the cached snapshot (no spinner), then refresh quietly.
    private func initialLoad() async {
        if env.postsService.posts.isEmpty,
           let snap = DiskCache.load(FeedSnapshot.self, key: snapshotKey) {
            env.postsService.seed(from: snap.posts)
            reactionMap = Dictionary(grouping: snap.reactions, by: \.postId)
        }
        await env.postsService.fetchPosts(userId: env.currentProfile?.id)
    }

    /// Never write a snapshot while an admin is previewing as someone else, or
    /// before the first real refresh (a seeded list is not fresher than its cache).
    private func saveSnapshot() {
        guard !env.isPreviewing, env.postsService.lastRefreshAt != nil else { return }
        let page = Array(env.postsService.posts.prefix(PostsService.pageSize))
        guard !page.isEmpty else { return }
        let reactions = page.flatMap { reactionMap[$0.id] ?? [] }
        DiskCache.save(FeedSnapshot(posts: page, reactions: reactions), key: snapshotKey)
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
        if env.postsService.posts.isEmpty
            && (env.postsService.isLoading || env.postsService.lastRefreshAt == nil) {
            loadingState
        } else if env.postsService.posts.isEmpty {
            emptyState
        } else {
            feedList
        }
    }

    private var feedList: some View {
        let posts = displayedPosts
        let nearEnd = Set(posts.suffix(5).map(\.id))
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                Color.clear.frame(height: 0).id(Self.topAnchor)
                LazyVStack(spacing: 0) {
                    ForEach(posts) { post in
                        if isFirstOfDay(post, in: posts) { dayChip(post.timelineDate) }
                        postRow(for: post)
                            .onAppear {
                                if nearEnd.contains(post.id) { Task { await env.postsService.loadMore() } }
                                prefetchMedia(after: post)
                            }
                    }
                    if env.postsService.hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            // Re-runs as pages land, so a short (filtered) list still pages on.
                            .task(id: env.postsService.posts.count) {
                                await env.postsService.loadMore()
                            }
                    }
                }
                .padding(.top, 8)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top <= 40
            } action: { _, atTop in
                isAtTop = atTop
                env.postsService.holdNewPosts = !atTop
                if atTop, !env.postsService.pendingNewPosts.isEmpty {
                    withAnimation(feedAnimation) { env.postsService.revealPending() }
                }
            }
            .overlay(alignment: .top) {
                if !env.postsService.pendingNewPosts.isEmpty && !isAtTop {
                    newPostsPill(proxy: proxy)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(feedAnimation, value: env.postsService.pendingNewPosts.isEmpty)
            .refreshable {
                await env.postsService.fetchPosts(userId: env.currentProfile?.id)
            }
        }
    }

    private func isFirstOfDay(_ post: Post, in posts: [Post]) -> Bool {
        guard let i = posts.firstIndex(where: { $0.id == post.id }) else { return false }
        if i == 0 { return true }
        return !Calendar.current.isDate(posts[i - 1].timelineDate, inSameDayAs: post.timelineDate)
    }

    private func dayChip(_ date: Date) -> some View {
        let cal = Calendar.current
        let label = cal.isDateInToday(date) ? "Today"
            : cal.isDateInYesterday(date) ? "Yesterday"
            : date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return Eyebrow(label, color: .mlrTextMuted)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color.mlrCard, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.mlrBorder, lineWidth: 1))
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
    }

    private static let topAnchor = "main-feed-top"

    private func newPostsPill(proxy: ScrollViewProxy) -> some View {
        Button {
            Haptics.tap()
            withAnimation(feedAnimation) {
                env.postsService.revealPending()
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
        } label: {
            Label("New posts", systemImage: "arrow.up")
                .font(.mlrScaled(14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.mlrPrimary))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Show new posts")
    }

    /// Warm Kingfisher's cache for the next few posts' photos, with the same
    /// signed URL and downsampler PostMediaTile uses so the cache key hits.
    private func prefetchMedia(after post: Post) {
        let list = displayedPosts
        guard let i = list.firstIndex(where: { $0.id == post.id }) else { return }
        var urls: [URL] = []
        for next in list.dropFirst(i + 1).prefix(3) where !prefetchedPostIds.contains(next.id) {
            prefetchedPostIds.insert(next.id)
            for (idx, raw) in next.mediaUrls.enumerated().prefix(4) where !next.isVideo(at: idx) {
                if let u = env.mediaTokenService.url(raw) { urls.append(u) }
            }
        }
        guard !urls.isEmpty else { return }
        ImagePrefetcher(urls: urls, options: [
            .processor(DownsamplingImageProcessor(size: CGSize(width: 1200, height: 1200))),
            .scaleFactor(UIScreen.main.scale)
        ]).start()
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
            .mlrCard(.plain, padding: 0)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
                        .padding(16)
                        .mlrCard(.plain, padding: 0)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
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
                .buttonStyle(.mlrPrimary)
                .padding(.horizontal, 40)
            }
            Spacer()
        }
    }

    private var composeButton: some View {
        Button {
            showComposer = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").font(.system(size: 18, weight: .semibold))
                if isAtTop { Text("New post").font(.system(size: 16, weight: .semibold)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18).frame(height: 52)
            .background(Capsule().fill(Color.mlrPrimary))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        }
        .buttonStyle(.pressable)
        .animation(MLRMotion.reduceMotion ? nil : MLRMotion.spring, value: isAtTop)
        .accessibilityLabel("New post")
        .padding(.trailing, 20)
        .padding(.bottom, 24)
    }

    // MARK: - Reactions

    /// One batched query for every loaded post; only touches entries that changed.
    @MainActor
    private func refreshReactions() async {
        let ids = env.postsService.posts.map(\.id)
        guard !ids.isEmpty,
              let fresh = try? await env.postsService.fetchReactions(postIds: ids) else { return }
        for (id, rows) in fresh where !togglingPosts.contains(id) {
            let sorted = rows.sorted { $0.id < $1.id }
            if (reactionMap[id] ?? []).sorted(by: { $0.id < $1.id }) != sorted { reactionMap[id] = rows }
        }
    }

    private func toggleReaction(post: Post, emoji: String) async {
        guard let userId = env.currentProfile?.id else { return }
        togglingPosts.insert(post.id)
        defer { togglingPosts.remove(post.id) }
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
