import SwiftUI

// MARK: - HomeView
// The main home screen. Mirrors the layout priority of app/page.tsx:
//   logo hero → announcement banner → fest spotlight →
//   upcoming event → get involved → ask for help / people →
//   around the resort → heritage footer

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env

    @Environment(\.colorScheme) private var colorScheme
    @State private var festSeason: FestSeason = .current()

    // Drive AttendanceControlStateless optimistically
    @State private var nearestEventStatus: AttendanceStatus? = nil

    // Manual entry to the global search screen (the same screen Siri's
    // `.system.searchInApp` intent opens).
    @State private var showSearch = false
    @State private var appImagesCanEdit = false

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

                        // ── 2. Weather: one slim card (self-hides until a source answers).
                        HomeWeatherCard(style: .compact)
                            .padding(.horizontal, 16)
                            .padding(.bottom, MLRSpacing.section)

                        // Admin preview banner — shown when viewing Home as a future date.
                        if let pd = previewDate {
                            previewBanner(date: pd)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 20)
                        }

                        // First-visit welcome (guests only; self-dismisses)
                        WelcomeCard()
                            .padding(.bottom, 4)

                        VStack(alignment: .leading, spacing: MLRSpacing.section) {

                            // Every card below gets `.scrollEntrance()` — a gentle
                            // fade/scale/rise as it crosses into view, so the whole
                            // feed feels alive while scrolling, not just on first
                            // load (Reduce Motion turns this into a no-op).

                            // ── 3. Announcement banner ────────────────────
                            AnnouncementBannerStack()
                                .scrollEntrance()

                            // ── 4. Callout cards + fest spotlight ─────────
                            // Admin-managed swipeable callout cards (home_callouts,
                            // migration 0083) stack above the permanent FamilyFestSpotlight
                            // base — same shape as the web's HomeSpotlight/CalloutStack.
                            HomeCalloutsStack(season: festSeason, previewDate: previewDateString)
                                .scrollEntrance()

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
                                .scrollEntrance()
                            }

                            // ── 5a. Family Fest card (countdown, committee link inside)
                            FamilyFestSpotlight(season: festSeason)
                                .scrollEntrance()

                            // ── 5. Your house — hub for calendar, chat & to-do ──
                            // Self-hides for guests and anyone not in a house.
                            // Promoted above checklist to match web layout (Jul 2026).
                            HouseHubHomeCard()
                                .scrollEntrance()

                            // ── 5b. Admin dashboard shortcut (admins only) ──
                            // Self-hides for non-admins and during "View as" preview.
                            HomeAdminDashboardCard()
                                .scrollEntrance()

                            // ── 6. Work Checklist (standalone collapsible card) ──
                            WorkChecklistCard()
                                .scrollEntrance()

                            // ── 6b. Polls — self-hides when no open poll ──────────
                            PollHomeCard()
                                .scrollEntrance()

                            // ── 7. Quick actions — every destination, always visible ──
                            // Replaces the two collapsed accordions (Communication /
                            // Around the Resort) — nothing buried behind a tap.
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader("Around the resort")
                                quickActionsGrid
                            }

                            // ── 8. Delight cards — birthdays, who's up north, memory ─
                            UpcomingBirthdaysCard()
                                .scrollEntrance()
                            WhosUpNorthCard()
                                .scrollEntrance()
                            OnThisDayCard()
                                .scrollEntrance()

                            // ── 9. App & Help ────────────────────────────
                            appHelpSection
                                .scrollEntrance()

                            // ── 8. Heritage footer ────────────────────────
                            heritageFooter
                                .padding(.bottom, 32)
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .mlrEditToggle(canEdit: (env.isAdmin || appImagesCanEdit) && !env.isPreviewing)
            .task(id: env.currentProfile?.id) {
                guard env.isSignedIn, !env.isAdmin else { return }
                appImagesCanEdit = await env.appImagesService.canEdit()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if env.isAdmin {
                        Button { showDatePicker = true } label: {
                            Image(systemName: previewDate == nil
                                  ? "calendar.badge.clock"
                                  : "calendar.badge.exclamationmark")
                                .foregroundStyle(previewDate == nil ? Color.mlrPrimary : .orange)
                        }
                        .accessibilityLabel("View Home as a date")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.mlrPrimary)
                    }
                    .accessibilityLabel("Search Up North")
                }
            }
        }
        .mlrBackdrop()
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
            // Independent loads run concurrently (they used to run one after another).
            async let images: Void = env.appImagesService.load()
            async let help: Void = env.loadHelpContact()
            async let events: Void = {
                await env.eventsService.fetchEvents(ifStale: true)
                if let userId = env.currentProfile?.id {
                    await env.eventsService.fetchAttendance(userId: userId)
                }
            }()
            await env.festContentService.load()
            // Live-update Home callouts (+ fest content) when an admin pushes one —
            // the subscription reloads on any home_callouts change (idempotent).
            env.festContentService.subscribeToRealtime()
            _ = await (images, help, events)
            publishNextEventToWidgets()
        }
        .refreshable {
            festSeason = FestSeason.current()
            await env.festContentService.reload()   // pick up newly-pushed callouts
            await env.eventsService.fetchEvents()
            if let userId = env.currentProfile?.id {
                await env.eventsService.fetchAttendance(userId: userId)
            }
            publishNextEventToWidgets()
        }
    }

    // MARK: - Subviews

    // 2-column grid of the primary destinations — always visible, no tap
    // to expand. Every tile is the same plain square HomeTile (Events used to
    // be promoted to a full-width hero card; flattened back to match the rest
    // per feedback). Row order matches web HomeQuickActions (Brian's
    // ordering): Events · Committees / People · Ask for Help / Local Places ·
    // Cabin Stay, plus Drop Box (migration 0171 — not yet on web's own
    // quick-actions grid either; web reaches it from a dedicated tile there).
    private func quickLink<D: View>(_ dest: D, _ icon: String, _ title: String,
                                  _ tint: Color, _ i: Int) -> some View {
        NavigationLink(destination: dest) {
            MLRCard(.tinted(tint), padding: 14) {
                HStack(spacing: MLRSpacing.stack) {
                    IconTile(symbol: icon, accent: tint, size: 34)
                    Text(title)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }
            }
        }
        .cardEntrance(index: i)
    }

    private var quickActionsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: MLRSpacing.stack), GridItem(.flexible(), spacing: MLRSpacing.stack)]
        return LazyVGrid(columns: cols, spacing: MLRSpacing.stack) {
            quickLink(EventsView(), "calendar", "Events", .mlrPrimary, 0)
            quickLink(CommitteesView(), "person.3.fill", "Committees", .mlrCampfire, 1)
            quickLink(PeopleDirectoryView(), "person.2.fill", "People", .mlrLake, 2)
            quickLink(HelpRequestsView(), "hand.raised.fill", "Ask for Help", .mlrPrimary, 3)
            quickLink(LocalPlacesView(), "mappin.and.ellipse", "Local Places", .mlrLake, 4)
            quickLink(CabinBookingsView(), "house.lodge.fill", "Cabin Stay", .mlrSun, 5)
            quickLink(DropBoxesView(), "photo.stack.fill", "Drop Box", .mlrDusk, 6)
        }
        .buttonStyle(.pressable)
    }

    private var greeting: String {
        let base: String
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  base = "Good morning"
        case 12..<17: base = "Good afternoon"
        case 17..<22: base = "Good evening"
        default:      base = "Good night"
        }
        guard env.isSignedIn, let full = env.currentProfile?.name,
              let first = full.split(separator: " ").first else { return base }
        return "\(base), \(first)"
    }

    @ViewBuilder
    private func logoHero(geometry: GeometryProxy) -> some View {
        VStack(spacing: 6) {
            SiteImage(key: SiteImageKey.homeLogo, fallback: "brand-logo-green")
                .scaledToFit()
                // The season's still scene (the splash's final frame), as on web.
                .overlay { SeasonalLogoFX(season: .current(), progress: 1).allowsHitTesting(false) }
                .frame(width: min(geometry.size.width * 0.28, 104))
                .background {
                    // Dark mode only: the dark-green mark nearly vanishes on the
                    // dark backdrop, so seat it on a soft light glow.
                    if colorScheme == .dark {
                        Circle()
                            .fill(RadialGradient(colors: [Color.white.opacity(0.78), Color.white.opacity(0.6), Color.white.opacity(0.22), Color.white.opacity(0)],
                                                 center: .center, startRadius: 40, endRadius: 100))
                            .frame(width: 200, height: 200)
                    }
                }
                .padding(.top, 0)
                .homeLogoEditPencil()
            Text(greeting)
                .font(.mlrScaled(24, weight: .semibold, design: .serif, relativeTo: .title1))
                .foregroundStyle(Color.mlrText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    @ViewBuilder
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
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.25), lineWidth: 1))
    }

    // "App & Help" — guided tour, share the app, help & how-to
    private var appHelpSection: some View {
        CollapsibleSection(
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
            .buttonStyle(.pressable)

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
                .background(
                    LinearGradient(colors: [tint.opacity(0.18), tint.opacity(0.07)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
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
