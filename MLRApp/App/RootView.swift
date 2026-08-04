import SwiftUI
import UIKit
import CoreSpotlight

// MARK: - Root View
// Houses the TabView and handles deep-link navigation.

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .home
    @State private var showSplash = true
    @State private var showAskForHelp = false
    @State private var showAddWorkItem = false
    @State private var pendingCommittee: Committee?
    @State private var pendingWorkItem: WorkItem?
    @State private var pendingHouseChat: PendingHouseChat?
    @State private var pendingHouseHub: House?
    @State private var pendingCommitteeChat: PendingCommitteeChat?
    @State private var pendingPost: Post?
    /// A specific comment to scroll to + flash within `pendingPost`'s thread
    /// (migration 0164) — set alongside pendingPost, read once by CommentsView.
    @State private var pendingCommentId: UUID?
    @State private var pendingScheduleItem: ScheduleItem?
    @State private var pendingPrivateActivity: PendingPrivateActivity?
    @State private var showHelpRequests = false
    @State private var showCabinBookings = false
    @State private var searchRequest: GlobalSearchRequest?

    // Siri / Shortcuts → in-app navigation bridge.
    private var router = IntentRouter.shared

    var body: some View {
        ZStack {
            MainTabView(selectedTab: $selectedTab)
                .opacity(showSplash ? 0 : 1)

            if showSplash {
                SplashView {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showSplash = false
                    }
                    // A tap that COLD-LAUNCHED the app is delivered before
                    // `.onReceive` below is subscribed, so it lands in the queue
                    // instead of the live listener — drain it now the splash is out
                    // of the way (see PendingNotificationTap).
                    if let tap = PendingNotificationTap.shared.drain() {
                        handleNotificationTap(tap)
                    }
                }
            }
        }
        // Admin "view as" preview — a floating banner over everything while active.
        .overlay(alignment: .bottom) {
            if !showSplash && env.isPreviewing {
                PreviewBanner()
                    .padding(.bottom, 58)   // float above the tab bar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: env.isPreviewing)
        .onReceive(NotificationCenter.default.publisher(for: .notificationTapped)) { note in
            handleNotificationTap(note.userInfo)
        }
        .sheet(isPresented: $showAskForHelp) {
            AskForHelpSheet()
        }
        // Quick-add from Siri/Shortcuts (form), the Home widget, or Control Center.
        .sheet(isPresented: $showAddWorkItem) {
            WorkItemComposer { Task { await env.workItemsService.fetchItems() } }
        }
        // Tapping a join-request notification (or its Decline action) opens the
        // committee's detail — which shows the pending-request approval section.
        .sheet(item: $pendingCommittee) { committee in
            NavigationStack { CommitteeDetailView(committee: committee) }
        }
        // Tapping a work-item comment/mention notification opens the item's detail.
        .sheet(item: $pendingWorkItem) { item in
            WorkItemDetailSheet(item: item) { Task { await env.workItemsService.fetchItems() } }
        }
        // Tapping a house-chat mention (or Siri "open house chat") opens the chat,
        // scrolled to the message the notification was about when there is one.
        .sheet(item: $pendingHouseChat) { pending in
            NavigationStack {
                HouseChatView(house: pending.house, assumeMember: true,
                              focusMessageId: pending.focusMessageId)
            }
        }
        .sheet(item: $pendingHouseHub) { house in
            NavigationStack { HouseHubView(house: house) }
        }
        // A committee-chat @mention notification, or Siri / Shortcuts "open
        // committee chat" — the area/title/message are set only by the former.
        .sheet(item: $pendingCommitteeChat) { pending in
            NavigationStack {
                CommitteeChatView(
                    committee: pending.committee,
                    members: pending.members,
                    area: pending.area,
                    channelTitle: pending.channelTitle,
                    assumeMember: true,
                    focusMessageId: pending.focusMessageId
                )
            }
        }
        // Tapping a post notification (new post, comment, reply, @mention, tag,
        // reaction) opens that one post's thread — the same sheet the comment
        // button on a PostCard opens, which leads with a recap of the post itself.
        .sheet(item: $pendingPost) { post in
            CommentsView(post: post, focusCommentId: pendingCommentId)
        }
        // A Family Fest sign-up reminder / tournament ping → that event's detail.
        .sheet(item: $pendingScheduleItem) { item in
            NavigationStack { FestScheduleDetailView(item: item) }
        }
        // An invite to a private activity / game (migration 0150).
        .sheet(item: $pendingPrivateActivity) { pending in
            PrivateActivitySheet(activityId: pending.activityId)
        }
        // An "Ask for Help" request, or a cabin-stay decision / guest note. Both
        // views carry their own NavigationStack.
        .sheet(isPresented: $showHelpRequests) {
            HelpRequestsView()
        }
        .sheet(isPresented: $showCabinBookings) {
            CabinBookingsView()
        }
        // `.system.searchInApp` Siri / Apple Intelligence search (or the Home
        // search button) — the destination the search schema navigates to.
        .sheet(item: $searchRequest) { req in
            NavigationStack { GlobalSearchView(initialTerm: req.term) }
        }
        .sheet(isPresented: Binding(
            get: { env.authService.showSignIn },
            set: { env.authService.showSignIn = $0 }
        )) {
            SignInView()
        }
        // Drive navigation when an App Intent opens the app.
        .onChange(of: router.pendingRoute) { _, _ in
            handlePendingRoute()
        }
        // Control Center controls can't reach the in-process router, so they stash a
        // route in the App Group and open the app — drain it when we become active.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            if let key = SharedStore.shared.pendingRoute {
                SharedStore.shared.pendingRoute = nil
                if let url = URL(string: "mlr://\(key)"), let route = IntentRouter.Route(url: url) {
                    router.requestRoute(route)
                }
            }
        }
        // Widget / Live Activity taps deep-link via mlr:// URLs.
        .onOpenURL { url in
            if let route = IntentRouter.Route(url: url) {
                router.requestRoute(route)
            }
        }
        // Spotlight / Siri semantic-index result taps: the tapped item's id is a
        // mlr:// deep link — route it to the right tab.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let url = URL(string: id),
                  let route = IntentRouter.Route(url: url) else { return }
            router.requestRoute(route)
        }
        .task {
            // Show/refresh the Family Fest Live Activity once the season is known.
            FestLiveActivityController.shared.refresh(
                season: FestSeason.current(),
                schedule: ScheduleItem.seed
            )
            // Stash the member's first name for personalized Siri responses.
            if let name = env.currentProfile?.name.split(separator: " ").first {
                SharedStore.shared.memberFirstName = String(name)
            }
            handlePendingRoute()
        }
    }

    // MARK: - Notification taps
    //
    // A push (or an in-app Activity row) resolves to a NotificationDeepLink, then
    // to a tab plus — where the notification is ABOUT one thing — the sheet that
    // already shows that thing in-app. Switching tabs alone isn't enough: the Feed
    // tab's root is the conversation list for anyone with a committee/house
    // channel, so `.feed` on its own lands a "shared a new post" tap on a chat
    // list, which is what the member has to hunt out of.

    private func handleNotificationTap(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        PendingNotificationTap.shared.clear()
        switch NotificationDeepLink(userInfo: info) {
        case .post(let id, let commentId):
            selectedTab = .feed
            resolvePost(id, commentId: commentId)
        case .feed:
            selectedTab = .feed
        case .committeeMessage(let id):
            selectedTab = .feed
            resolveCommitteeMessage(id)
        case .committeeJoinRequest(let requestId, let committeeId):
            resolveCommitteeForRequest(requestId: requestId, committeeId: committeeId)
        case .houseMessage(let id):
            selectedTab = .feed
            resolveHouseMessage(id)
        case .houseHub:
            // A new stay on the house calendar — open the House Hub. Resolve the
            // viewer's own house (mirrors the house-chat deep link).
            selectedTab = .home
            Task { @MainActor in
                if let hid = env.currentProfile?.houseId,
                   let house = await env.housesService.house(withId: hid) {
                    pendingHouseHub = house
                }
            }
        case .workItem(let id):
            selectedTab = .home
            resolveWorkItem(id)
        case .helpRequests:
            selectedTab = .home
            showHelpRequests = true
        case .cabinStays:
            selectedTab = .home
            showCabinBookings = true
        case .privateActivity(let id):
            selectedTab = .home
            pendingPrivateActivity = PendingPrivateActivity(activityId: id)
        case .festScheduleItem(let id):
            selectedTab = .fest
            resolveScheduleItem(id)
        case .familyFest:
            selectedTab = .fest
        case .notifications:
            selectedTab = .activity
        case .home:
            selectedTab = .home
        }
    }

    /// Resolve the post behind a post notification (new post, comment, reply,
    /// @mention, tag, reaction) and open its thread. Falls back to the Feed tab if
    /// the post is gone or held for review.
    private func resolvePost(_ id: UUID, commentId: UUID? = nil) {
        Task { @MainActor in
            pendingCommentId = commentId
            pendingPost = await env.postsService.fetchPost(id: id)
        }
    }

    /// Resolve a work item behind a comment/mention notification and open its
    /// detail sheet (comments + media).
    private func resolveWorkItem(_ id: UUID) {
        Task { @MainActor in
            let item: WorkItem? = try? await supabase
                .from("work_items")
                .select("*, work_item_media(*), work_item_comments(id)")
                .eq("id", value: id.uuidString)
                .single()
                .execute()
                .value
            if let item { pendingWorkItem = item }
        }
    }

    /// Resolve the house behind a house-chat mention (entity is the message id)
    /// and open that house's chat, scrolled to the message.
    private func resolveHouseMessage(_ id: UUID) {
        Task { @MainActor in
            struct Row: Decodable { let houseId: UUID
                enum CodingKeys: String, CodingKey { case houseId = "house_id" } }
            let row: Row? = try? await supabase
                .from("house_messages")
                .select("house_id")
                .eq("id", value: id.uuidString)
                .single()
                .execute()
                .value
            if let hid = row?.houseId, let house = await env.housesService.house(withId: hid) {
                pendingHouseChat = PendingHouseChat(house: house, focusMessageId: id)
            }
        }
    }

    /// Resolve the room behind a committee-chat @mention (entity is the message
    /// id) and open that channel, scrolled to the message. The committee AND the
    /// role channel come from the message row rather than the notification's web
    /// url, whose `&area=` is unescaped free text (migration 0063).
    private func resolveCommitteeMessage(_ id: UUID) {
        Task { @MainActor in
            struct Row: Decodable {
                let committeeId: UUID
                let area: String?
                enum CodingKeys: String, CodingKey { case committeeId = "committee_id"; case area }
            }
            let row: Row? = try? await supabase
                .from("committee_messages")
                .select("committee_id, area")
                .eq("id", value: id.uuidString)
                .single()
                .execute()
                .value
            guard let row,
                  let committee = await env.committeeService.fetchCommittee(byId: row.committeeId)
            else { return }
            let members = (try? await env.committeeService.fetchMembers(committeeId: committee.id)) ?? []
            pendingCommitteeChat = PendingCommitteeChat(
                committee: committee, members: members,
                area: row.area, channelTitle: row.area ?? committee.name,
                focusMessageId: id)
        }
    }

    /// Resolve a Family Fest event/activity behind a sign-up reminder or a
    /// tournament notification and open its detail.
    private func resolveScheduleItem(_ id: UUID) {
        Task { @MainActor in
            await env.festContentService.load()
            let key = id.uuidString
            pendingScheduleItem = env.festContentService.schedule.first {
                $0.id.caseInsensitiveCompare(key) == .orderedSame
            }
        }
    }

    /// Resolve the committee behind a join-request notification (by committee id
    /// if the push carried one, else via the request id) and present its detail.
    private func resolveCommitteeForRequest(requestId: UUID?, committeeId: UUID?) {
        Task { @MainActor in
            let svc = env.committeeService
            var committee: Committee?
            if let committeeId { committee = await svc.fetchCommittee(byId: committeeId) }
            if committee == nil, let requestId {
                committee = await svc.fetchCommittee(forRequestId: requestId)
            }
            if let committee { pendingCommittee = committee }
        }
    }

    private func handlePendingRoute() {
        guard let route = router.consume() else { return }
        switch route {
        case .askForHelp:
            // Land on Home, then present the Ask-for-Help compose sheet.
            selectedTab = .home
            showAskForHelp = true
        case .familyFest:
            selectedTab = .fest
        case .events:
            selectedTab = .home
        case .home:
            selectedTab = .home
        case .feed:
            selectedTab = .feed
        case .addWorkItem:
            selectedTab = .home
            showAddWorkItem = true
        case .committeeChat(let slug):
            selectedTab = .feed
            resolveCommitteeChat(slug: slug)
        case .houseChat:
            selectedTab = .feed
            Task { @MainActor in
                if let hid = env.currentProfile?.houseId,
                   let house = await env.housesService.house(withId: hid) {
                    pendingHouseChat = PendingHouseChat(house: house)
                }
            }
        case .search(let term):
            selectedTab = .home
            searchRequest = GlobalSearchRequest(term: term)
        }
    }

    /// Resolve a committee by slug + load its members, then present its chat.
    private func resolveCommitteeChat(slug: String) {
        Task { @MainActor in
            if env.committeeService.committees.isEmpty { await env.committeeService.fetchCommittees() }
            guard let committee = env.committeeService.committees.first(where: { $0.slug == slug }) else { return }
            let members = (try? await env.committeeService.fetchMembers(committeeId: committee.id)) ?? []
            pendingCommitteeChat = PendingCommitteeChat(committee: committee, members: members)
        }
    }
}

// MARK: - Tab enum

enum Tab: String, CaseIterable {
    case home, feed, fest, activity, profile
}

// MARK: - Pending sheets (notification taps / Siri / Shortcuts opens)

struct PendingCommitteeChat: Identifiable {
    let id = UUID()
    let committee: Committee
    let members: [CommitteeMember]
    /// The role channel; nil = the committee's General channel.
    var area: String? = nil
    var channelTitle: String? = nil
    /// The message a chat-mention notification was about, to scroll to on open.
    var focusMessageId: UUID? = nil
}

struct PendingHouseChat: Identifiable {
    let id = UUID()
    let house: House
    /// The message a chat-mention notification was about, to scroll to on open.
    var focusMessageId: UUID? = nil
}

struct PendingPrivateActivity: Identifiable {
    let id = UUID()
    let activityId: UUID
}

// MARK: - Main Tab View

struct MainTabView: View {
    @Binding var selectedTab: Tab
    @Environment(AppEnvironment.self) private var env

    private var unreadCount: Int {
        env.notificationsService.unreadCount
    }

    private var festSeason: FestSeason {
        FestSeason.current()
    }

    /// The Family Fest tab icon — the ⚔️ emoji rendered to a full-colour image.
    /// A tab item's icon has to be an `Image`; drawing the emoji ourselves and
    /// flagging it `.alwaysOriginal` keeps its colour (UITabBar would otherwise
    /// tint a template image to a flat silhouette).
    static let emojiTabIcon: UIImage = {
        let size: CGFloat = 27
        let font = UIFont.systemFont(ofSize: size)
        let string = "⚔️" as NSString
        let bounds = string.size(withAttributes: [.font: font])
        let renderer = UIGraphicsImageRenderer(size: bounds)
        return renderer.image { _ in
            string.draw(at: .zero, withAttributes: [.font: font])
        }.withRenderingMode(.alwaysOriginal)
    }()

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            PostsView()
                .tabItem { Label("Feed", systemImage: "rectangle.stack.fill") }
                .tag(Tab.feed)

            FestOverviewView()
                .tabItem {
                    Label {
                        Text("Family Fest")
                    } icon: {
                        // A tab-bar icon must be an Image; SwiftUI ignores a Text
                        // icon. Render the ⚔️ emoji to an image so it shows in full
                        // colour (matching the Fest's medieval theme).
                        Image(uiImage: Self.emojiTabIcon)
                            .renderingMode(.original)
                    }
                }
                .tag(Tab.fest)
                .badge(festSeason.isLive || festSeason.isWrap ? "●" : nil)

            NotificationsView()
                .tabItem { Label("Activity", systemImage: "bell.fill") }
                .tag(Tab.activity)
                .badge(unreadCount > 0 ? unreadCount : 0)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.fill") }
                .tag(Tab.profile)
        }
        .tint(Color.mlrPrimary)
        .task {
            if env.isSignedIn, let userId = env.currentProfile?.id {
                await env.notificationsService.fetchUnreadCount(userId: userId)
            }
        }
    }
}

// MARK: - Splash View

struct SplashView: View {
    let onComplete: () -> Void
    @State private var scale: CGFloat = 0.7
    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            Image("brand-logo-green")
                .resizable()
                .scaledToFit()
                .frame(width: 140)
                .scaleEffect(scale)
                .opacity(opacity)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                scale = 1
                opacity = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeIn(duration: 0.25)) {
                    opacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onComplete()
                }
            }
        }
        // Respect reduce motion — skip animation
        .accessibilityReduceMotion(true) {
            self.modifier(ImmediateSplashModifier(onComplete: onComplete))
        }
    }
}

private struct ImmediateSplashModifier: ViewModifier {
    let onComplete: () -> Void
    func body(content: Content) -> some View {
        Color.clear.onAppear { onComplete() }
    }
}

// MARK: - AccessibilityReduceMotion helper

private extension View {
    @ViewBuilder
    func accessibilityReduceMotion(_ enabled: Bool, @ViewBuilder replacement: () -> some View) -> some View {
        if UIAccessibility.isReduceMotionEnabled && enabled {
            replacement()
        } else {
            self
        }
    }
}
