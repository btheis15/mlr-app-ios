import SwiftUI

// MARK: - FestOverviewView
//
// One consumable, scrollable view of the whole Fest week: a phase-aware status
// header, the identity cover, then a day-by-day agenda where each day's
// activities AND that night's dinner expand IN PLACE (glance first, tap for
// detail). The utility sections (Crew / Dinners depth / Pay / Shirts / Photos)
// are reachable but secondary, under "More". Content is live from
// FestContentService (DB-backed), with a visible note when it falls back to the
// offline seed.

struct FestOverviewView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var festSeason: FestSeason = .current()
    @State private var canEdit = false
    @State private var showPlanner = false

    private var content: FestContentService { env.festContentService }

    /// Timed items grouped by day, ordered by real date (falls back to weekday
    /// order when a day has no ISO date, e.g. the offline seed). All days shown
    /// including today during the live week — FamilyFestSpotlight shows today
    /// prominently above, but the full week list is always complete.
    private var dayGroups: [(day: String, isoDate: String?, items: [ScheduleItem])] {
        let timed = content.schedule.filter { $0.day != "Anytime" }
        return Dictionary(grouping: timed, by: \.day)
            .map { (day: $0.key, isoDate: $0.value.compactMap(\.isoDate).first, items: $0.value) }
            .sorted { a, b in
                switch (a.isoDate, b.isoDate) {
                case let (l?, r?): return l < r
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return Self.weekdayIndex(a.day) < Self.weekdayIndex(b.day)
                }
            }
    }

    private func dinner(for day: String) -> FestDinner? {
        content.dinners.first { $0.day == day }
    }

    static func weekdayIndex(_ day: String) -> Int {
        ["Sunday": 0, "Monday": 1, "Tuesday": 2, "Wednesday": 3,
         "Thursday": 4, "Friday": 5, "Saturday": 6][day] ?? 99
    }

    static var todayWeekday: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "America/Chicago")
        return fmt.string(from: .now)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.mlrFestParchment.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {

                        FestStatus(season: festSeason)

                        // Identity: cover art + theme/dates/venue caption.
                        VStack(spacing: 10) {
                            FestCoverImage()
                            FestCoverCaption()
                        }

                        if content.usingSeedFallback {
                            seedFallbackNote
                        }

                        GoldOrnamentDivider()

                        // The week, day by day — activities + that night's dinner.
                        ForEach(dayGroups, id: \.day) { group in
                            FestDaySection(
                                day: group.day,
                                isoDate: group.isoDate,
                                items: group.items,
                                dinner: dinner(for: group.day)
                            )
                            .scrollTransition { content, phase in
                                content
                                    .opacity(phase.isIdentity ? 1 : 0.3)
                                    .scaleEffect(phase.isIdentity ? 1 : 0.96)
                            }
                        }

                        // All-week, no-set-time activities (scavenger hunt, etc.)
                        FestAnytimeCard()

                        GoldOrnamentDivider()

                        // Secondary sections.
                        moreSection

                        Text("Leo & Dorothy Theis · Est. 1987 · Tomahawk, WI")
                            .font(.festSerif(11))
                            .foregroundStyle(Color.mlrFestInk.opacity(0.65))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Family Fest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.mlrFestParchment, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                if canEdit {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showPlanner = true } label: {
                            Label("Planner", systemImage: "slider.horizontal.3")
                                .foregroundStyle(Color.mlrFest)
                        }
                    }
                }
            }
            .sheet(isPresented: $showPlanner, onDismiss: { Task { await env.festContentService.reload() } }) {
                NavigationStack { FamilyFestPlannerView() }
            }
        }
        .onAppear {
            festSeason = .current()
        }
        .task {
            await env.appImagesService.load()
            await env.festContentService.load()
            canEdit = await env.festContentService.canEditFest()
            env.festContentService.subscribeToRealtime()
        }
        .onDisappear { env.festContentService.unsubscribeFromRealtime() }
    }

    // MARK: - Secondary sections

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("More")
                .festHeadingStyle(size: 15)
                .padding(.horizontal, 4)
                .padding(.top, 4)

            FestUtilityLink(label: "Who's coming", icon: "person.3.fill") { FestCrewView() }
            FestUtilityLink(label: "Dinner details", icon: "fork.knife") { FestDinnersView() }
            FestUtilityLink(label: "Dues & payments", icon: "dollarsign.circle.fill") { FestPayView() }
            // Photos live on the Main Feed now — no separate Fest photo gallery.
        }
    }

    private var seedFallbackNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.mlrScaled(11))
            Text("Showing offline defaults — the schedule may be out of date.")
                .font(.mlrScaled(12))
        }
        .foregroundStyle(Color.mlrFestInk.opacity(0.7))
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - Day section (activities + that night's dinner)

private struct FestDaySection: View {
    let day: String
    let isoDate: String?
    let items: [ScheduleItem]
    let dinner: FestDinner?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(day.uppercased())
                    .font(.mlrScaled(11, weight: .semibold))
                    .foregroundStyle(Color.mlrFest.opacity(0.65))
                    .tracking(1.2)
                Spacer()
                // Self-hides when WeatherKit has no forecast for the date.
                if let isoDate {
                    EventWeatherBadge(isoDate: isoDate)
                }
            }
            .padding(.horizontal, 6)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().background(Color.mlrFest.opacity(0.1))
                    }
                    ExpandableScheduleRow(item: item)
                }
                if let dinner {
                    Divider().background(Color.mlrFest.opacity(0.15))
                    ExpandableDinnerRow(dinner: dinner)
                }
            }
            .festCardStyle(cornerRadius: 12)
        }
    }
}

// MARK: - Utility link (secondary sections)

private struct FestUtilityLink<Destination: View>: View {
    let label: String
    let icon: String
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
                .navigationTitle(label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.mlrFestParchment, for: .navigationBar)
                .toolbarColorScheme(.light, for: .navigationBar)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.mlrScaled(14, weight: .semibold))
                    .frame(width: 22)
                Text(label)
                    .font(.festSerif(15, weight: .bold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.mlrScaled(12, weight: .semibold))
                    .foregroundStyle(Color.mlrFest.opacity(0.35))
            }
            .foregroundStyle(Color.mlrFest)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .festCardStyle(cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cover Art

/// The Family Fest 2026 "Renaissance / Fantasy" cover, bundled in the asset
/// catalog so it shows offline. Mirrors the web fest page's FestCover header.
private struct FestCoverImage: View {
    var body: some View {
        SiteImage(key: SiteImageKey.festCover, fallback: "family-fest-cover")
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(LinearGradient.festHeraldic, lineWidth: 1.5)
            )
            .background { FestHeroGlow() }
            .shadow(color: .mlrFest.opacity(0.18), radius: 16, x: 0, y: 8)
            .accessibilityLabel("Family Fest 2026 — Ye Olde Family Feste")
    }
}

// MARK: - Cover Caption

/// The festive title block under the cover art — the ⚜ "Ye Olde Family Feste"
/// theme line, then the dates and venue.
private struct FestCoverCaption: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("⚜ Ye Olde Family Feste ⚜")
                .font(.festSerif(14, weight: .bold))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(Color.mlrFest)

            Text("\(FamilyFestConfig.dateRangeLabel), \(String(FamilyFestConfig.year))")
                .font(.festSerif(15, weight: .bold))
                .foregroundStyle(Color.mlrFest)

            Text("Muskellunge Lake Resort · Tomahawk, WI")
                .font(.mlrScaled(12))
                .foregroundStyle(Color.mlrFestInk.opacity(0.7))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Summary card

/// A parchment section card with a serif title, used across the overview.
private struct FestInfoCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.festSerif(15, weight: .bold))
                .foregroundStyle(Color.mlrFest)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .festCardStyle(cornerRadius: 12)
    }
}

/// All-week, no-set-time activities (the scavenger hunt).
private struct FestAnytimeCard: View {
    @Environment(AppEnvironment.self) private var env
    @State private var editing: ScheduleItem?
    private var items: [ScheduleItem] { env.festContentService.schedule.filter { $0.day == "Anytime" } }

    /// Admin / committee runner, or this activity's own lead or crew (migration 0110).
    private func canEdit(_ item: ScheduleItem) -> Bool {
        guard env.isSignedIn, let me = env.currentProfile?.id else { return false }
        return env.isAdmin
            || env.festContentService.userCanEditFest
            || item.leadUserId == me
            || item.crewUserIds.contains(me)
    }

    var body: some View {
        if !items.isEmpty {
            FestInfoCard(title: "All week — anytime") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.festSerif(14, weight: .bold))
                                    .foregroundStyle(Color.mlrFest)
                                if let desc = item.description {
                                    Text(desc)
                                        .font(.mlrScaled(12))
                                        .foregroundStyle(Color.mlrFestInk.opacity(0.75))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                            if canEdit(item) {
                                Button { editing = item } label: {
                                    Image(systemName: "pencil")
                                        .font(.mlrScaled(13, weight: .semibold))
                                        .foregroundStyle(Color.mlrFest)
                                        .padding(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .sheet(item: $editing) { item in
                if let uuid = UUID(uuidString: item.id) {
                    FestActivityEditSheet(activityId: uuid, title: item.title) {
                        await env.festContentService.reload()
                    }
                }
            }
        }
    }
}
