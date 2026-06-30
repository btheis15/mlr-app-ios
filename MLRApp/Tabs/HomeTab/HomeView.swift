import SwiftUI

// MARK: - HomeView
// The main home screen. Mirrors the layout priority of app/page.tsx:
//   logo hero → announcement banner → fest spotlight → tshirt callout →
//   upcoming event → get involved → ask for help / people →
//   around the resort → heritage footer

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var festSeason: FestSeason = .current()
    @State private var tshirtDismissed = false

    // Drive AttendanceControlStateless optimistically
    @State private var nearestEventStatus: AttendanceStatus? = nil

    /// The next upcoming event to spotlight on Home: the nearest non–Family-Fest
    /// event the member hasn't declined. Declined ("not going") events drop off
    /// Home but stay findable in the Events list — matches the web.
    private var spotlightEvent: ResortEvent? {
        env.eventsService.upcomingEvents.first { event in
            guard !event.isFamilyFest else { return false }
            return env.eventsService.attendances[event.id]?.effectiveStatus() != .notGoing
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {

                        // ── 1. MLR logo hero ──────────────────────────────
                        logoHero(geometry: geometry)

                        // First-visit welcome (guests only; self-dismisses)
                        WelcomeCard()
                            .padding(.bottom, 4)

                        VStack(alignment: .leading, spacing: 20) {

                            // ── 2. Announcement banner ────────────────────
                            // AnnouncementBannerStack manages its own fetch + dismiss via env
                            AnnouncementBannerStack()

                            // ── 3 & 4. Fest spotlight + T-shirt callout overlay ──
                            // TshirtCallout sits on top (like the web app's CalloutStack):
                            // swipe/✕ dismisses it and reveals the base spotlight below.
                            ZStack(alignment: .top) {
                                FamilyFestSpotlight(season: festSeason)
                                if festSeason.isPlanning && !tshirtDismissed {
                                    TshirtCallout(onDismiss: { tshirtDismissed = true })
                                }
                            }

                            // ── 5. Upcoming event ─────────────────────────
                            if let event = spotlightEvent {
                                UpcomingEventCard(
                                    event: event,
                                    attendance: env.eventsService.attendances[event.id],
                                    currentStatusOverride: nearestEventStatus,
                                    onAttendanceChange: { status in
                                        await updateAttendance(event: event, status: status)
                                    }
                                )
                            }

                            // ── 6. Communication ──────────────────────────
                            communicationSection

                            // ── 7. Around the Resort ─────────────────────
                            aroundResortSection

                            // ── 8. App & Help ────────────────────────────
                            appHelpSection

                            // ── 9. Heritage footer ────────────────────────
                            heritageFooter
                                .padding(.bottom, 32)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                    }
                }
            }
            .navigationBarHidden(true)
            .background(Color.mlrSurface)
        }
        // When the spotlight switches events (e.g. after declining one), drop the
        // stale optimistic override so it can't leak onto the next event's card.
        .onChange(of: spotlightEvent?.id) { _, _ in nearestEventStatus = nil }
        .task {
            festSeason = FestSeason.current()
            await env.appImagesService.load()
            await env.festContentService.load()
            await env.eventsService.fetchEvents()
            if let userId = env.currentProfile?.id {
                await env.eventsService.fetchAttendance(userId: userId)
            }
            publishNextEventToWidgets()
        }
        .refreshable {
            festSeason = FestSeason.current()
            await env.eventsService.fetchEvents()
            if let userId = env.currentProfile?.id {
                await env.eventsService.fetchAttendance(userId: userId)
            }
            publishNextEventToWidgets()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func logoHero(geometry: GeometryProxy) -> some View {
        let logoWidth = min(geometry.size.width * 0.46, 180.0)
        HStack {
            Spacer()
            SiteImage(key: SiteImageKey.homeLogo, fallback: "brand-logo-green")
                .scaledToFit()
                .frame(maxWidth: logoWidth)
                .padding(.top, 10)
                .padding(.bottom, 4)
            Spacer()
        }
    }

    // "Communication" — People · Committees · Ask for Help · Work Checklist
    private var communicationSection: some View {
        CollapsibleHomeSection(
            title: "Communication",
            emoji: "💬",
            subtitle: "People · Committees · Ask for Help · Work Checklist"
        ) {
            HStack(spacing: 12) {
                NavigationLink(destination: PeopleDirectoryView()) {
                    HomeTile(
                        icon: "person.2.fill",
                        title: "People",
                        subtitle: "Find & contact everyone at the resort.",
                        tint: Color.mlrInfo
                    )
                }
                .frame(maxWidth: .infinity)

                NavigationLink(destination: CommitteesView()) {
                    HomeTile(
                        icon: "person.3.fill",
                        title: "Committees",
                        subtitle: "Join a crew and pitch in — there's a spot for everyone.",
                        tint: Color.mlrPrimary
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)

            NavigationLink(destination: HelpRequestsView()) {
                HomeTile(
                    icon: "hand.raised.fill",
                    title: "Ask for Help",
                    subtitle: "Need a hand at the resort? Ask — or help out.",
                    tint: Color.mlrPrimary,
                    fullWidth: true
                )
            }

            // The interactive work checklist card.
            WorkChecklistCard()
        }
    }

    // "Around the Resort" — Events & Work Weekends · Cabin Stay · Local Places
    private var aroundResortSection: some View {
        CollapsibleHomeSection(
            title: "Around the Resort",
            emoji: "🧭",
            subtitle: "Events · Cabin Stay · Local Places"
        ) {
            NavigationLink(destination: EventsView()) {
                HomeTile(
                    icon: "calendar",
                    title: "Events & Work Weekends",
                    subtitle: "See what's coming up — RSVP to gatherings and grab a spot on a work weekend.",
                    tint: Color.mlrPrimary,
                    fullWidth: true
                )
            }
            HStack(spacing: 12) {
                NavigationLink(destination: CabinBookingsView()) {
                    HomeTile(
                        icon: "house.lodge.fill",
                        title: "Cabin Stay",
                        subtitle: "Reserve a room for any week.",
                        tint: Color.mlrPrimary
                    )
                }
                .frame(maxWidth: .infinity)

                NavigationLink(destination: LocalPlacesView()) {
                    HomeTile(
                        icon: "mappin.and.ellipse",
                        title: "Local Places",
                        subtitle: "Tee times, food & favorites nearby.",
                        tint: Color.mlrAccent
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // "App & Help" — guided tour, share the app, help & how-to
    private var appHelpSection: some View {
        CollapsibleHomeSection(
            title: "App & Help",
            emoji: "📲",
            subtitle: "Take the tour · Share · Help"
        ) {
            NavigationLink(destination: GuideView()) {
                HomeTile(
                    icon: "map.fill",
                    title: "Take a quick tour",
                    subtitle: "See the app screen by screen.",
                    tint: Color.mlrPrimary,
                    fullWidth: true
                )
            }

            ShareLink(item: MLRLinks.appURL) {
                HomeTile(
                    icon: "square.and.arrow.up",
                    title: "Share this app",
                    subtitle: "Send the link so anyone can join.",
                    tint: Color.mlrInfo,
                    fullWidth: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink(destination: HelpView()) {
                HomeTile(
                    icon: "questionmark.circle.fill",
                    title: "Help & how-to",
                    subtitle: "FAQs, sign-in help, and contact.",
                    tint: Color.mlrPrimary,
                    fullWidth: true
                )
            }
        }
    }

    private var heritageFooter: some View {
        HStack {
            Spacer()
            Text("Est. 1987 · Leo & Dorothy Theis · Tomahawk, WI")
                .font(.caption2)
                .foregroundStyle(Color.mlrTextSubtle)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Actions

    private func updateAttendance(event: ResortEvent, status: AttendanceStatus) async {
        // Optimistic UI update
        nearestEventStatus = status
        do {
            try await env.eventsService.upsertAttendance(eventId: event.id, status: status)
        } catch {
            // Roll back on failure
            nearestEventStatus = env.eventsService.attendances[event.id]?.effectiveStatus()
        }
    }

    /// Write the next upcoming event to the App Group store so the NextEvent
    /// widget + Siri intents can read it, then nudge the widget timelines.
    private func publishNextEventToWidgets() {
        guard let next = env.eventsService.upcomingEvents.first else {
            SharedStore.shared.nextEvent = nil
            SharedStore.shared.reloadWidgets()
            return
        }
        SharedStore.shared.nextEvent = EventSnapshot(
            title: next.title,
            startDate: next.startDate,
            emoji: emoji(forKind: next.kind),
            location: next.location
        )
        SharedStore.shared.reloadWidgets()
    }

    private func emoji(forKind kind: EventKind) -> String {
        switch kind {
        case .familyFest:  return "🎉"
        case .workWeekend: return "🔨"
        case .holiday:     return "🎄"
        case .custom:      return "📅"
        }
    }

}

// MARK: - HomeTile
// A reusable card tile used on the Home grid.

struct HomeTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    var fullWidth: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.mlrText)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(Color.mlrTextMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - CollapsibleHomeSection
// A tappable header card (emoji + title + subtitle + rotating chevron) that
// reveals its content when open. Mirrors the web app's CollapsibleSection —
// both Home groups start collapsed.

private struct CollapsibleHomeSection<Content: View>: View {
    let title: String
    let emoji: String
    let subtitle: String
    let content: Content

    @State private var isOpen = false

    init(title: String, emoji: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.emoji = emoji
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isOpen.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text(emoji).font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.mlrText)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.mlrTextMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mlrTextSubtle)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(14)
                .frame(maxWidth: .infinity)
                .cardStyle()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                content
            }
        }
    }
}

// MARK: - Navigate environment key
// Tabs can inject a closure to drive tab selection from deep within the hierarchy.

struct NavigateKey: EnvironmentKey {
    static let defaultValue: (Tab) -> Void = { _ in }
}

extension EnvironmentValues {
    var navigate: (Tab) -> Void {
        get { self[NavigateKey.self] }
        set { self[NavigateKey.self] = newValue }
    }
}
