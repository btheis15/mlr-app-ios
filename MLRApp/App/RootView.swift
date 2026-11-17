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
    /// Tracks whether the main content is opaque — decoupled from showSplash so
    /// the cross-fade can start while SplashView's logo is still mid-flight.
    @State private var mainVisible = false
    @State private var showAskForHelp = false
    @State private var showAddWorkItem = false
    @State private var pendingCommittee: Committee?
    @State private var pendingWorkItem: WorkItem?
    @State private var pendingHouseChat: PendingHouseChat?
    @State private var pendingHouseHub: House?
    @State private var pendingCommitteeChat: PendingCommitteeChat?
    @State private var pendingPost: Post?
    /// An event-chat push (`/posts?event=<id>`) → that event's room.
    @State private var pendingEventChat: EventChatSummary?
    /// A specific comment to scroll to + flash within `pendingPost`'s thread
    /// (migration 0164) — set alongside pendingPost, read once by CommentsView.
    @State private var pendingCommentId: UUID?
    @State private var pendingScheduleItem: ScheduleItem?
    @State private var pendingPrivateActivity: PendingPrivateActivity?
    @State private var showHelpRequests = false
    @State private var showCabinBookings = false
    @State private var searchRequest: GlobalSearchRequest?
    #if DEBUG
    @State private var debugScreen: String?
    #endif

    // Siri / Shortcuts → in-app navigation bridge.
    private var router = IntentRouter.shared

    var body: some View {
        ZStack {
            // A signed-in but unverified account gets the waiting screen instead
            // of the member layout. RLS returns fewer rows rather than an error,
            // so without this they'd see every list empty with no explanation —
            // and since 0213, every button would fail too.
            if env.isAwaitingVerification {
                AwaitingVerificationView()
                    .opacity(mainVisible ? 1 : 0)
            } else {
                MainTabView(selectedTab: $selectedTab)
                    .opacity(mainVisible ? 1 : 0)
            }

            if showSplash {
                SplashView(
                    onBeginExit: {
                        // Fade main content in as the splash fades out.
                        withAnimation(.easeOut(duration: 0.45)) { mainVisible = true }
                    },
                    onComplete: {
                        // Safety: ensure main is visible even if onBeginExit was skipped
                        // (e.g. the Reduce Motion path calls onComplete directly).
                        mainVisible = true
                        showSplash = false
                        // A tap that COLD-LAUNCHED the app is delivered before
                        // `.onReceive` below is subscribed, so it lands in the queue
                        // instead of the live listener — drain it now the splash is
                        // out of the way (see PendingNotificationTap).
                        if let tap = PendingNotificationTap.shared.drain() {
                            handleNotificationTap(tap)
                        }
                    }
                )
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
        // An event-chat message push → the room, as a sheet like every other chat
        // deep link here. Chats are admin-blind: an unknown id just stays on Feed.
        .sheet(item: $pendingEventChat) { chat in
            NavigationStack { EventChatView(chat: chat) }
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
        #if DEBUG
        .sheet(item: Binding(get: { debugScreen.map { DebugScreenID(id: $0) } },
                             set: { debugScreen = $0?.id })) { d in
            NavigationStack {
                switch d.id {
                case "events": EventsView()
                case "local-places": LocalPlacesView()
                case "main-feed": MainFeedView(title: "Main Feed")
                case "leaf-lab": LeafLabView()
                default: AdminView()
                }
            }
            .mlrBackdrop()
        }
        .task {
            // DEBUG screenshot hooks (no taps): -startRoute activity|profile|
            // events|local-places|admin|house-chat|feed ; -startEditMode.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-startEditMode") { MLREditModeStore.shared.isOn = true }
            guard let i = args.firstIndex(of: "-startRoute"), i + 1 < args.count else { return }
            let v = args[i + 1]
            try? await Task.sleep(for: .seconds(3))
            switch v {
            case "activity": selectedTab = .activity
            case "profile": selectedTab = .profile
            case "events", "local-places", "admin", "main-feed": debugScreen = v
            case "house-chat": router.requestRoute(.houseChat)
            case "fest": selectedTab = .fest
            case "feed": selectedTab = .feed
            case "leaf-lab": debugScreen = v
            default: break
            }
        }
        #endif
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
        // Event chats have no NotificationDeepLink case; route them first.
        if let eventId = NotificationDeepLink.eventChatId(userInfo: info) {
            selectedTab = .feed
            resolveEventChat(eventId.uuidString)
            return
        }
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

    /// Find the member's event chat by id (loading the list if it isn't there
    /// yet, e.g. a cold launch) and open it. Not in the list → stay on Feed.
    private func resolveEventChat(_ eventId: String) {
        Task { @MainActor in
            let service = env.eventChatService
            let matches: (EventChatSummary) -> Bool = { $0.eventId.caseInsensitiveCompare(eventId) == .orderedSame }
            if !service.chats.contains(where: matches) { await service.loadChats() }
            pendingEventChat = service.chats.first(where: matches)
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

extension Notification.Name {
    /// Posted (object: the `Tab`) when the already-selected tab is tapped again.
    static let tabReselected = Notification.Name("tabReselected")
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

private struct TabBarUnselectedTint: UIViewControllerRepresentable {
    let color: UIColor
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ vc: Probe, context: Context) { vc.color = color; vc.apply() }
    final class Probe: UIViewController {
        var color: UIColor = .secondaryLabel
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); apply() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }
        static func findTabBar() -> UITabBar? {
            func walk(_ v: UIView) -> UITabBar? {
                if let b = v as? UITabBar { return b }
                for c in v.subviews { if let b = walk(c) { return b } }
                return nil
            }
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                for w in ws.windows { if let b = walk(w) { return b } }
            }
            return nil
        }
        func apply() {
            guard let bar = Self.findTabBar() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.apply() }
                return
            }
            bar.unselectedItemTintColor = color
            let item = UITabBarItemAppearance()
            item.normal.iconColor = color
            item.normal.titleTextAttributes = [.foregroundColor: color]
            let a = UITabBarAppearance()
            a.configureWithDefaultBackground()
            a.stackedLayoutAppearance = item
            a.inlineLayoutAppearance = item
            a.compactInlineLayoutAppearance = item
            bar.standardAppearance = a
            bar.scrollEdgeAppearance = a
        }
    }
}

struct MainTabView: View {
    @Binding var selectedTab: Tab
    @Environment(AppEnvironment.self) private var env

    private var unreadCount: Int {
        env.notificationsService.unreadCount
    }

    private var festSeason: FestSeason {
        FestSeason.current()
    }

    /// Selection binding that also notices a tap on the already-selected tab, so
    /// lists can scroll back to top (`.tabReselected`).
    private var tabSelection: Binding<Tab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == selectedTab {
                    NotificationCenter.default.post(name: .tabReselected, object: newValue)
                }
                selectedTab = newValue
            }
        )
    }

    /// Unselected tab icons + labels take the muted text tone (selected uses the
    /// SwiftUI tint: pine, or the fest primary on the Fest tab).
    private static func applyTabBarColors() {
        let muted = UIColor(Color.mlrTextMuted)
        let item = UITabBarItemAppearance()
        item.normal.iconColor = muted
        item.normal.titleTextAttributes = [.foregroundColor: muted]
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().unselectedItemTintColor = muted
    }

    init(selectedTab: Binding<Tab>) {
        _selectedTab = selectedTab
        Self.applyTabBarColors()
    }

    var body: some View {
        TabView(selection: tabSelection) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            PostsView()
                .tabItem { Label("Feed", systemImage: "bubble.left.and.bubble.right.fill") }
                .tag(Tab.feed)

            FestOverviewView()
                .tabItem { Label("Family Fest", systemImage: "tent.fill") }
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
        // The live UITabBar ignores the global appearance proxy on the floating
        // bar, so also set the muted unselected tone on the real controller.
        .background(TabBarUnselectedTint(color: UIColor(Color.mlrTextMuted)).frame(width: 0, height: 0))
        // Pine tint; the Family Fest tab takes the active fest theme primary when selected.
        .tint(selectedTab == .fest ? Color.mlrFest : Color.mlrPrimary)
        .animation(MLRMotion.reduceMotion ? nil : MLRMotion.spring, value: unreadCount)
        // A light selection tick on every tab switch — the kind of small,
        // native-feeling touch that makes the bar feel considered rather than
        // stock. Skipped on the very first appearance (no real "switch" yet).
        .onChange(of: selectedTab) { oldValue, newValue in
            guard oldValue != newValue else { return }
            Haptics.select()
        }
        .task {
            if env.isSignedIn, let userId = env.currentProfile?.id {
                await env.notificationsService.fetchUnreadCount(userId: userId)
            }
        }
    }
}

// MARK: - Splash View
//
// A multi-stage launch moment rather than a bare scale+fade: a soft tinted
// glow blooms behind the mark, the logo springs in with a touch of overshoot,
// the script wordmark rises in a beat later, then the whole lockup lifts and
// fades away together. Deliberately self-contained (no cross-tab
// matchedGeometryEffect into HomeHero's async-loaded logo) so it can never
// visibly stutter waiting on a network image — every element here is a local
// asset/bundled font, so geometry is known on the very first frame.

struct SplashView: View {
    let onBeginExit: () -> Void
    let onComplete: () -> Void

    @State private var glowOpacity: Double = 0
    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var wordmarkOpacity: Double = 0
    @State private var wordmarkOffset: CGFloat = 8
    // Exit: clean fade + slight scale-down hand-off (no fly-to-header).
    @State private var exitOpacity: Double = 1
    @State private var exitScale: CGFloat = 1
    private let season = Season.current()

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            Circle()
                .fill(RadialGradient(colors: [Color.mlrPrimary.mlrTint(0.22), .clear],
                                      center: .center, startRadius: 0, endRadius: 160))
                .frame(width: 320, height: 320)
                .opacity(glowOpacity)

            VStack(spacing: 10) {
                Image("brand-logo-green")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140)
                    .shadow(.medium)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
                    // Seasonal effect layered exactly over the artwork; ends still.
                    .overlay {
                        SeasonalLogoAnimatedFX(season: season, onSettle: { Haptics.tap() })
                            .scaleEffect(logoScale)
                            .opacity(logoOpacity)
                    }

                Text("Muskellunge Lake Resort")
                    .font(.script(26))
                    .foregroundStyle(Color.mlrPineText)
                    .opacity(wordmarkOpacity)
                    .offset(y: wordmarkOffset)
            }
            .scaleEffect(exitScale)
            .opacity(exitOpacity)
        }
        .onAppear { animateIn() }
        // Respect reduce motion — skip animation entirely.
        .accessibilityReduceMotion(true) {
            self.modifier(ImmediateSplashModifier(onBeginExit: onBeginExit, onComplete: onComplete))
        }
    }

    private func animateIn() {
        withAnimation(.easeOut(duration: 0.4)) {
            glowOpacity = 1
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.62)) {
            logoScale = 1
            logoOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.35).delay(0.28)) {
            wordmarkOpacity = 1
            wordmarkOffset = 0
        }
        // Effect runs ~0.25s + 2.4s and settles (haptic fires there); hold a
        // beat on the still, then fade/scale out while main fades in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            onBeginExit()
            withAnimation(.easeOut(duration: 0.25)) {
                glowOpacity = 0
                wordmarkOpacity = 0
            }
            withAnimation(.easeInOut(duration: 0.4)) {
                exitOpacity = 0
                exitScale = 1.06
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                onComplete()
            }
        }
    }
}

private struct ImmediateSplashModifier: ViewModifier {
    let onBeginExit: () -> Void
    let onComplete: () -> Void
    func body(content: Content) -> some View {
        Color.clear.onAppear {
            onBeginExit()
            onComplete()
        }
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

#if DEBUG
private struct DebugScreenID: Identifiable { let id: String }
#endif

extension View {
    /// DEBUG screenshot hook: `-startScroll <points>` scrolls this ScrollView after load.
    @ViewBuilder func debugStartScroll() -> some View {
        #if DEBUG
        modifier(DebugStartScroll())
        #else
        self
        #endif
    }
}
#if DEBUG
private struct DebugStartScroll: ViewModifier {
    @State private var pos = ScrollPosition()
    func body(content: Content) -> some View {
        content.scrollPosition($pos).task {
            let a = ProcessInfo.processInfo.arguments
            guard let i = a.firstIndex(of: "-startScroll"), i + 1 < a.count, let y = Double(a[i + 1]) else { return }
            try? await Task.sleep(for: .seconds(6))
            pos.scrollTo(y: y)
        }
    }
}
#endif
