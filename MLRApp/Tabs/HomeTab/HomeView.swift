import SwiftUI

// MARK: - HomeView
// The main home screen. Mirrors the layout priority of app/page.tsx:
//   logo hero → announcement banner → fest spotlight →
//   upcoming event → get involved → ask for help / people →
//   around the resort → heritage footer

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var festSeason: FestSeason = .current()

    // Drive AttendanceControlStateless optimistically
    @State private var nearestEventStatus: AttendanceStatus? = nil

    // Manual entry to the global search screen (the same screen Siri's
    // `.system.searchInApp` intent opens).
    @State private var showSearch = false

    // Admin date-preview: simulate what Home looks like on a given day.
    @State private var previewDate: Date? = nil
    @State private var showDatePicker = false

    private var previewDateString: String? {
        guard let d = previewDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")!
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

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

                        // Admin preview banner — shown when viewing Home as a future date.
                        if let pd = previewDate {
                            previewBanner(date: pd)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 4)
                        }

                        // First-visit welcome (guests only; self-dismisses)
                        WelcomeCard()
                            .padding(.bottom, 4)

                        VStack(alignment: .leading, spacing: 20) {

                            // ── 2. Weather — "what's it like Up North right now" ──
                            // Self-hides on load failure — never leaves an empty gap.
                            HomeWeatherCard()

                            // ── 3. Announcement banner ────────────────────
                            AnnouncementBannerStack()

                            // ── 4. Callout cards + fest spotlight ─────────
                            // Admin-managed swipeable callout cards (home_callouts,
                            // migration 0083) stack above the permanent FamilyFestSpotlight
                            // base — same shape as the web's HomeSpotlight/CalloutStack.
                            HomeCalloutsStack(season: festSeason, previewDate: previewDateString)

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

                            // ── 5. Your house — hub for calendar, chat & to-do ──
                            // Self-hides for guests and anyone not in a house.
                            // Promoted above checklist to match web layout (Jul 2026).
                            HouseHubHomeCard()

                            // ── 6. Work Checklist (standalone collapsible card) ──
                            WorkChecklistCard()

                            // ── 6b. Polls — self-hides when no open poll ──────────
                            PollHomeCard()

                            // ── 7. Quick actions — every destination, always visible ──
                            // Replaces the two collapsed accordions (Communication /
                            // Around the Resort) — nothing buried behind a tap.
                            quickActionsGrid

                            // ── 8. Delight cards — birthdays & who's up north ─────
                            UpcomingBirthdaysCard()
                            WhosUpNorthCard()

                            // ── 9. App & Help ────────────────────────────
                            appHelpSection

                            // ── 8. Heritage footer ────────────────────────
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
        .sheet(isPresented: $showSearch) {
            NavigationStack { GlobalSearchView(initialTerm: "") }
        }
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                Form {
                    Section {
                        DatePicker(
                            "Preview date",
                            selection: Binding(
                                get: { previewDate ?? Date() },
                                set: { previewDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .tint(Color.mlrPrimary)
                    }
                    if previewDate != nil {
                        Section {
                            Button("Clear preview — use today") {
                                previewDate = nil
                                showDatePicker = false
                            }
                            .foregroundStyle(Color.mlrDanger)
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
                .navigationTitle("View Home as…")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showDatePicker = false }
                    }
                }
            }
        }
        // When the spotlight switches events (e.g. after declining one), drop the
        // stale optimistic override so it can't leak onto the next event's card.
        .onChange(of: spotlightEvent?.id) { _, _ in nearestEventStatus = nil }
        .onChange(of: previewDate) { _, newDate in
            festSeason = FestSeason.current(now: newDate ?? Date())
        }
        .task {
            festSeason = FestSeason.current()
            await env.appImagesService.load()
            await env.festContentService.load()
            await env.loadHelpContact()
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

    // 2-column grid of the six primary destinations — always visible, no tap
    // to expand. Row order matches web HomeQuickActions (Brian's ordering):
    // Events · Committees / People · Ask for Help / Local Places · Cabin Stay.
    private var quickActionsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: cols, spacing: 12) {
            NavigationLink(destination: EventsView()) {
                HomeTile(icon: "calendar", title: "Events",
                         subtitle: "RSVP — gatherings & work weekends.", tint: Color.mlrPrimary)
            }
            NavigationLink(destination: CommitteesView()) {
                HomeTile(icon: "person.3.fill", title: "Committees",
                         subtitle: "Join a crew — there's a spot for you.", tint: Color.mlrAccent)
            }
            NavigationLink(destination: PeopleDirectoryView()) {
                HomeTile(icon: "person.2.fill", title: "People",
                         subtitle: "Find & contact everyone.", tint: Color.mlrInfo)
            }
            NavigationLink(destination: HelpRequestsView()) {
                HomeTile(icon: "hand.raised.fill", title: "Ask for Help",
                         subtitle: "Request a hand at the resort.", tint: Color.mlrPrimary)
            }
            NavigationLink(destination: LocalPlacesView()) {
                HomeTile(icon: "mappin.and.ellipse", title: "Local Places",
                         subtitle: "Tee times, food & favorites.", tint: Color.mlrInfo)
            }
            NavigationLink(destination: CabinBookingsView()) {
                HomeTile(icon: "house.lodge.fill", title: "Cabin Stay",
                         subtitle: "Reserve a room for any week.", tint: Color.mlrPrimary)
            }
        }
        .buttonStyle(.plain)
    }

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
        // Search everything up north — people, events, committees, work, chats.
        .overlay(alignment: .trailing) {
            Button { showSearch = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.mlrScaled(18, weight: .semibold))
                    .foregroundStyle(Color.mlrPrimary)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Search Up North")
            .padding(.trailing, 4)
        }
        // Admin-only: date preview button (leading).
        .overlay(alignment: .leading) {
            if env.isAdmin {
                Button { showDatePicker = true } label: {
                    Image(systemName: previewDate == nil
                          ? "calendar.badge.clock"
                          : "calendar.badge.exclamationmark")
                        .font(.mlrScaled(18, weight: .semibold))
                        .foregroundStyle(previewDate == nil ? Color.mlrPrimary : .orange)
                        .padding(10)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("View Home as a date")
                .padding(.leading, 4)
            }
        }
    }

    private func previewBanner(date: Date) -> some View {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
                .font(.mlrScaled(14))
            Text("Previewing Home as \(f.string(from: date))")
                .font(.mlrScaled(12, weight: .medium))
                .foregroundStyle(.orange)
            Spacer()
            Button { previewDate = nil } label: {
                Image(systemName: "xmark")
                    .font(.mlrScaled(11, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.8))
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.25), lineWidth: 1))
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
// A reusable card tile used on the Home grid. Icon sits inside a tinted
// rounded square (matching web HomeQuickActions icon-box style).

struct HomeTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    var fullWidth: Bool = false
    var minHeight: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.mlrScaled(22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(title)
                .font(.mlrScaled(14, weight: .semibold))
                .foregroundStyle(Color.mlrText)

            Text(subtitle)
                .font(.mlrScaled(11))
                .foregroundStyle(Color.mlrTextMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: minHeight ?? 88, maxHeight: .infinity, alignment: .leading)
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
                    Text(emoji).font(.mlrScaled(20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.mlrScaled(16, weight: .semibold))
                            .foregroundStyle(Color.mlrText)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.mlrTextMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.mlrScaled(14, weight: .semibold))
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
