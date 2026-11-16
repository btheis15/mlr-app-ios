import SwiftUI
import Kingfisher

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
    @State private var canEdit = false
    @State private var showPlanner = false
    @State private var showLookEditor = false
    @State private var previewDate: Date? = nil      // admin "see as this day" preview
    @State private var showDatePicker = false

    private var content: FestContentService { env.festContentService }

    /// Same permission as the Planner button; hidden while an admin previews as someone else.
    private var showsEditPencils: Bool { canEdit && !env.isPreviewing }

    /// The fest season for the previewed day (or the real today) — drives the
    /// FestStatus phase + "Day N of N".
    private var festSeason: FestSeason { FestSeason.current(now: previewDate ?? .now) }

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

    static func weekday(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "America/Chicago")
        return fmt.string(from: date)
    }

    static var todayWeekday: String { weekday(for: .now) }

    var body: some View {
        NavigationStack {
            ZStack {
                FestThemedBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {

                        if previewDate != nil { previewBanner }

                        pillRow

                        FestStatus(season: festSeason, previewDate: previewDate)

                        // Identity: cover art + theme/dates/venue caption.
                        VStack(spacing: 10) {
                            FestYearCover(coverUrl: content.config?.coverUrl,
                                          accessibilityText: "Family Fest \(String(content.year)) cover")
                                .background { FestHeroGlow() }
                                .overlay(alignment: .topTrailing) {
                                    if showsEditPencils {
                                        EditPencil("cover and theme", tint: .mlrFest) { showLookEditor = true }
                                            .padding(6)
                                    }
                                }
                            FestCoverCaption()
                                .overlay(alignment: .topTrailing) {
                                    if showsEditPencils {
                                        // Opens the Planner, where "Fest details & dates" lives.
                                        EditPencil("fest title and dates", tint: .mlrFest) { showPlanner = true }
                                    }
                                }
                        }

                        if content.usingSeedFallback {
                            seedFallbackNote
                        }

                        // Once the fest is concluded the week itself moves to
                        // Past Years and the hub drops to Overview + Past Years.
                        // Leaving the accordion up would keep a finished week
                        // looking like a plan people can still act on.
                        if !festSeason.isConcluded {
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

                            if !dayGroups.isEmpty { GoldOrnamentDivider() }
                        }

                        // Secondary sections.
                        moreSection

                        Text("Leo & Dorothy Theis · Est. 1987 · Tomahawk, WI")
                            .font(.festSerif(11))
                            .foregroundStyle(Color.mlrFestInkReadable.opacity(0.65))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
                .debugStartScroll()
            }
            .mlrEditToggle(canEdit: showsEditToggle, tint: .mlrFestInkReadable)
            .navigationTitle("Family Fest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if env.isAdmin {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showDatePicker = true } label: {
                            Image(systemName: previewDate == nil ? "calendar.badge.clock" : "calendar.badge.exclamationmark")
                                .foregroundStyle(previewDate == nil ? Color.mlrFestInkReadable : .orange)
                        }
                        .accessibilityLabel("Preview Fest as a date")
                    }
                }
                if canEdit {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showPlanner = true } label: {
                            Label("Planner", systemImage: "slider.horizontal.3")
                        }
                        .tint(Color.mlrFestInkReadable)
                    }
                }
            }
            .sheet(isPresented: $showPlanner, onDismiss: { Task { await env.festContentService.reload() } }) {
                NavigationStack { FamilyFestPlannerView().sheetDoneButton() }
            }
            .sheet(isPresented: $showDatePicker) { datePreviewSheet }
            .sheet(isPresented: $showLookEditor) { FestYearLookSheet() }
        }
        .mlrBackdrop(.fest)
        .task {
            await env.appImagesService.load()
            await env.festContentService.load()
            canEdit = await env.festContentService.canEditFest()
            env.festContentService.subscribeToRealtime()
        }
        .onDisappear { env.festContentService.unsubscribeFromRealtime() }
        .festThemeScope()
    }

    // MARK: - Admin date preview ("see as Day N")

    static var festStart: Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f.date(from: FamilyFestConfig.startDate) ?? .now
    }

    private var previewBanner: some View {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
        return HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
            Text("Previewing as \(f.string(from: previewDate ?? .now))")
                .font(.mlrScaled(12, weight: .medium)).foregroundStyle(.orange)
            Spacer()
            Button { withAnimation { previewDate = nil } } label: {
                Image(systemName: "xmark").font(.mlrScaled(11, weight: .semibold)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var datePreviewSheet: some View {
        NavigationStack {
            VStack(spacing: 14) {
                DatePicker("Preview date",
                           selection: Binding(get: { previewDate ?? Self.festStart },
                                              set: { previewDate = $0 }),
                           displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Color.mlrFest)
                Text("See the Fest tab — its phase, “Day N of N”, and today's events/dinner — as it'll look on this day.")
                    .font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle("Preview a day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if previewDate != nil { Button("Clear") { previewDate = nil; showDatePicker = false } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showDatePicker = false }.fontWeight(.semibold) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Secondary sections

    /// Edit toggle for fest editors, or anyone who is chef/crew on a dinner (same rules as the pencils).
    private var showsEditToggle: Bool {
        guard !env.isPreviewing else { return false }
        return canEdit || content.dinners.contains { env.canEditFestDinner(chefUserId: $0.chefUserId, crewUserIds: $0.crewUserIds) }
    }

    /// Overview (selected) plus the existing sub-screens, which simply push.
    private var pillRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Overview")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(Color.mlrFest, in: Capsule())
                if !festSeason.isConcluded {
                    pill("Dinners") { FestDinnersView() }
                    pill("Pay") { FestPayView() }
                    pill("Who's coming") { FestCrewView() }
                }
                pill("Past Years") { FestPastYearsView() }
            }
            .padding(.trailing, 40)
        }
        // Fade the trailing edge so a clipped pill clearly reads as scrollable.
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 28)
            }
        }
    }

    private func pill<D: View>(_ title: String, @ViewBuilder _ dest: @escaping () -> D) -> some View {
        NavigationLink {
            dest().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } label: {
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Color.mlrFestInkReadable)
                .padding(.horizontal, 16).frame(height: 36)
                .background(Color.mlrFestCard, in: Capsule())
                .overlay(Capsule().stroke(Color.mlrFestBorder, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    private var moreSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Day chips + entry to the RSVP flow (Who's coming owns the RSVP sheet).
            if !festSeason.isConcluded {
                NavigationLink {
                    FestCrewView()
                        .navigationTitle("Who's coming")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Are you coming?")
                            .font(.festDisplay(19))
                            .foregroundStyle(Color.mlrFestInkReadable)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(dayGroups, id: \.day) { g in
                                    VStack(spacing: 0) {
                                        Text(String(g.day.prefix(3)).uppercased())
                                            .font(.system(size: 12, weight: .semibold)).tracking(1.0)
                                        if let d = g.isoDate?.suffix(2) {
                                            Text(String(Int(d) ?? 0)).font(.system(.headline, design: .rounded))
                                        }
                                    }
                                    .foregroundStyle(Color.mlrFestReadable)
                                    .frame(minWidth: 52).padding(.vertical, 8)
                                    .background(Color.mlrFest.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }
                        Text("Tap to RSVP your days")
                            .font(.subheadline).foregroundStyle(Color.mlrFestInkReadable.opacity(0.75))
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .festCardStyle(cornerRadius: 22)
                }
                .buttonStyle(.pressable)
            }

            Text("More").festHeadingStyle(size: 17).padding(.top, 4)

            // A concluded fest drops to Overview + Past Years.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: MLRSpacing.stack), GridItem(.flexible(), spacing: MLRSpacing.stack)], spacing: MLRSpacing.stack) {
                if !festSeason.isConcluded {
                    FestUtilityLink(label: "Who's coming", icon: "person.3.fill") { FestCrewView() }
                    FestUtilityLink(label: "Weekly dinner menu", icon: "fork.knife") { FestDinnersView() }
                    FestUtilityLink(label: "Dues & payments", icon: "dollarsign.circle.fill") { FestPayView() }
                }
                FestUtilityLink(label: "Past years", icon: "clock.arrow.circlepath") { FestPastYearsView() }
            }
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

    // Unified row type so dinner slots into its correct time position.
    private enum DayRow: Identifiable {
        case event(ScheduleItem)
        case dinner(FestDinner)
        var id: String {
            switch self { case .event(let e): return "e-\(e.id)"; case .dinner(let d): return "d-\(d.id)" }
        }
        var sortKey: String {
            switch self { case .event(let e): return normalizeTime(e.time); case .dinner(let d): return normalizeTime(d.time) }
        }
    }

    private var rows: [DayRow] {
        var r = items.map { DayRow.event($0) }
        if let dinner { r.append(.dinner(dinner)) }
        return r.sorted { $0.sortKey < $1.sortKey }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(day.uppercased())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mlrFestInkReadable.opacity(0.8))
                    .tracking(1.2)
                Spacer()
                // Self-hides when WeatherKit has no forecast for the date.
                if let isoDate {
                    EventWeatherBadge(isoDate: isoDate)
                }
            }
            .padding(.horizontal, 6)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().background(Color.mlrFest.opacity(0.1))
                    }
                    switch row {
                    case .event(let item):  ExpandableScheduleRow(item: item)
                    case .dinner(let din):  ExpandableDinnerRow(dinner: din)
                    }
                }
            }
            .festCardStyle(cornerRadius: 12)
        }
    }
}

/// Convert any time string to zero-padded 24h "HH:mm" for lexical comparison.
/// Handles: "HH:mm" 24h, "h:mm AM/PM" 12h, plain hour integers, and "TBD" (→ last).
private func normalizeTime(_ raw: String) -> String {
    let t = raw.trimmingCharacters(in: .whitespaces)
    if t.isEmpty || t.uppercased() == "TBD" { return "23:59" }
    // Already zero-padded 24h (e.g. "14:30" or "09:00")
    let parts = t.split(separator: ":").map(String.init)
    if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1].prefix(2)), !t.lowercased().contains("m") {
        return String(format: "%02d:%02d", h, m)
    }
    // 12h format: "6:30 PM", "9 AM", etc.
    let fmt = DateFormatter()
    for f in ["h:mm a", "h a", "h:mm", "h"] {
        fmt.dateFormat = f
        fmt.locale = Locale(identifier: "en_US_POSIX")
        if let d = fmt.date(from: t) {
            let cal = Calendar.current
            let h = cal.component(.hour, from: d)
            let m = cal.component(.minute, from: d)
            return String(format: "%02d:%02d", h, m)
        }
    }
    return t  // fallback: unchanged (sorts by raw string)
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
            VStack(alignment: .leading, spacing: 10) {
                IconTile(symbol: icon, accent: .mlrFest, size: 34)
                Text(label)
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(Color.mlrFestInkReadable)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .festCardStyle(cornerRadius: 22)
        }
        .buttonStyle(.pressable)
    }
}

// MARK: - Edit pencil

// MARK: - Cover Caption

/// Title block under the cover: the year's theme line (from config, in the
/// display font), one divider, the dates, then countdown tiles. No hardcoded
/// heraldic strings: a missing theme falls back to the fest name.
private struct FestCoverCaption: View {
    @Environment(AppEnvironment.self) private var env
    private var config: FestConfig? { env.festContentService.config }
    private var title: String {
        let t = config?.theme?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? (config?.name ?? "Family Fest") : t
    }
    private var dates: String {
        "\(config?.dateRangeLabel ?? FamilyFestConfig.dateRangeLabel), \(String(config?.year ?? FamilyFestConfig.year))"
    }
    private var startISO: String { config?.startDate ?? FamilyFestConfig.startDate }

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.festDisplay(21))
                .foregroundStyle(Color.mlrFestInkReadable)
            GoldOrnamentDivider()
            Text(dates)
                .font(.mlrScaled(16, weight: .semibold, relativeTo: .title3))
                .foregroundStyle(Color.mlrFestReadable)
            Text("Muskellunge Lake Resort \u{00B7} Tomahawk, WI")
                .font(.system(.footnote))
                .foregroundStyle(Color.mlrFestInkReadable.opacity(0.7))
            FestCountdownTiles(startISO: startISO)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

/// Days / hrs / min until the fest starts; hidden once it has begun.
private struct FestCountdownTiles: View {
    let startISO: String
    private var start: Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f.date(from: startISO)
    }
    var body: some View {
        if let start {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let secs = Int(start.timeIntervalSince(ctx.date))
                if secs > 0 {
                    HStack(spacing: 10) {
                        tile(secs / 86_400, "days")
                        tile((secs % 86_400) / 3_600, "hrs")
                        tile((secs % 3_600) / 60, "min")
                    }
                    .padding(.top, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(secs / 86_400) days until Family Fest")
                }
            }
        }
    }
    private func tile(_ n: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.festDisplay(22)).foregroundStyle(Color.mlrFestReadable).monospacedDigit()
            Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2)
                .foregroundStyle(Color.mlrFestInkReadable.opacity(0.7))
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .festCardStyle(cornerRadius: 20)
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
                .font(.festDisplay(22))
                .foregroundStyle(Color.mlrFestInkReadable)
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
    private var items: [ScheduleItem] { env.festContentService.schedule.filter { $0.day == "Anytime" } }

    var body: some View {
        if !items.isEmpty {
            // Phase 3.3: anytime items expand/collapse EXACTLY like the weekday
            // cards — same ExpandableScheduleRow + festCardStyle structure as
            // FestDaySection. (Anytime items are regular anytime schedule events
            // since migration 0141, so ExpandableScheduleRow's edit routing —
            // FestScheduleEditSheet — is already correct for them.)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ALL WEEK — ANYTIME")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mlrFestInkReadable.opacity(0.8))
                        .tracking(1.2)
                    Spacer()
                }
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        ExpandableScheduleRow(item: item)
                        if idx < items.count - 1 {
                            Divider().background(Color.mlrFest.opacity(0.15))
                        }
                    }
                }
                .festCardStyle(cornerRadius: 12)
            }
        }
    }
}
