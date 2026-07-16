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
    @State private var pendingHouse: House?
    @State private var pendingHouseHub: House?
    @State private var pendingCommitteeChat: PendingCommitteeChat?
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
        // Tapping a house-chat mention (or Siri "open house chat") opens the chat.
        .sheet(item: $pendingHouse) { house in
            NavigationStack { HouseChatView(house: house, assumeMember: true) }
        }
        .sheet(item: $pendingHouseHub) { house in
            NavigationStack { HouseHubView(house: house) }
        }
        // Siri / Shortcuts "open committee chat".
        .sheet(item: $pendingCommitteeChat) { pending in
            NavigationStack {
                CommitteeChatView(committee: pending.committee, members: pending.members, assumeMember: true)
            }
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

    private func handleNotificationTap(_ info: [AnyHashable: Any]?) {
        guard let type = info?["target_type"] as? String else { return }
        switch type {
        case "post":            selectedTab = .feed
        case "event":           selectedTab = .home
        case "notification":    selectedTab = .activity
        case "committee_chat":  selectedTab = .home
        case "committee_join_request":
            resolveCommitteeForRequest(info)
        case "work_item":
            resolveWorkItem(info)
        case "house_message":
            resolveHouse(info)
        case "house_stay":
            // A new stay on the house calendar — open the House Hub. Resolve the
            // viewer's own house (mirrors the house-chat deep link).
            selectedTab = .home
            Task { @MainActor in
                if let hid = env.currentProfile?.houseId,
                   let house = await env.housesService.house(withId: hid) {
                    pendingHouseHub = house
                }
            }
        default:                selectedTab = .home
        }
    }

    /// Resolve a work item behind a comment/mention notification and open its
    /// detail sheet (comments + media).
    private func resolveWorkItem(_ info: [AnyHashable: Any]?) {
        guard let idStr = info?["target_id"] as? String, let id = UUID(uuidString: idStr) else {
            selectedTab = .home; return
        }
        Task { @MainActor in
            let item: WorkItem? = try? await supabase
                .from("work_items")
                .select("*, work_item_media(*), work_item_comments(id)")
                .eq("id", value: id.uuidString)
                .single()
                .execute()
                .value
            if let item { pendingWorkItem = item } else { selectedTab = .home }
        }
    }

    /// Resolve the house behind a house-chat mention (entity is the message id)
    /// and open that house's chat.
    private func resolveHouse(_ info: [AnyHashable: Any]?) {
        guard let idStr = info?["target_id"] as? String, let id = UUID(uuidString: idStr) else {
            selectedTab = .feed; return
        }
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
                pendingHouse = house
            } else {
                selectedTab = .feed
            }
        }
    }

    /// Resolve the committee behind a join-request notification (by committee id
    /// if the push carried one, else via the request id) and present its detail.
    private func resolveCommitteeForRequest(_ info: [AnyHashable: Any]?) {
        Task { @MainActor in
            let svc = env.committeeService
            var committee: Committee?
            if let cidStr = info?["committee_id"] as? String, let cid = UUID(uuidString: cidStr) {
                committee = await svc.fetchCommittee(byId: cid)
            }
            if committee == nil, let ridStr = info?["target_id"] as? String, let rid = UUID(uuidString: ridStr) {
                committee = await svc.fetchCommittee(forRequestId: rid)
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
                    pendingHouse = house
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

// MARK: - Pending committee chat (Siri / Shortcuts open)

struct PendingCommitteeChat: Identifiable {
    let id = UUID()
    let committee: Committee
    let members: [CommitteeMember]
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
