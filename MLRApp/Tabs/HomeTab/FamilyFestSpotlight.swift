import SwiftUI

// MARK: - FamilyFestSpotlight
// A compact, phase-aware Family Fest summary at the top of Home (kept small —
// roughly a glance, not the whole hub). Tapping the summary opens the full
// Family Fest tab. A single smart shortcut below it links to the Family Fest
// committee CHAT if you're a member, or the JOIN request (with role picking) if
// you're not.

struct FamilyFestSpotlight: View {
    @Environment(AppEnvironment.self) private var env
    let season: FestSeason

    @State private var showJoinSheet = false

    private var familyFest: Committee? {
        env.committeeService.committees.first { $0.slug == "family-fest" }
    }

    private var isMember: Bool {
        guard let ff = familyFest else { return false }
        return env.committeeService.myMemberships.contains { $0.committeeId == ff.id }
    }

    private var dateRange: String {
        MLRFormat.dateRange(start: FamilyFestConfig.startDate, end: FamilyFestConfig.endDate)
    }

    private var iconName: String {
        switch season.phase {
        case .offSeason: return "star.fill"
        case .planning:  return "calendar.badge.clock"
        case .live:      return "star.fill"
        case .wrap:      return "photo.fill"
        }
    }

    private var statusLine: String {
        switch season.phase {
        case .offSeason:
            return dateRange
        case .planning:
            return season.isSoon
                ? "Almost here · \(dateRange)"
                : "\(season.daysUntilStart) days to go · \(dateRange)"
        case .live:
            if let day = season.dayNumber { return "Live now · Day \(day) of \(season.totalDays)" }
            return "Live now"
        case .wrap:
            return "That's a wrap · \(season.wrapDaysLeft) day\(season.wrapDaysLeft == 1 ? "" : "s") to post photos"
        }
    }

    // Today as yyyy-MM-dd in Chicago time (for event isoDate matching).
    private var todayISO: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Chicago")!
        return f.string(from: Date())
    }

    // Today's weekday name ("Monday"…) for dinner matching.
    private var todayWeekday: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Chicago")!
        return f.string(from: Date())
    }

    // Timed schedule items for today (live phase only).
    private var todayEvents: [ScheduleItem] {
        env.festContentService.schedule.filter { $0.isoDate == todayISO }
    }

    // Tonight's dinner (live phase only).
    private var todayDinner: FestDinner? {
        env.festContentService.dinners.first { $0.day == todayWeekday }
    }

    var body: some View {
        VStack(spacing: 0) {
            if season.phase == .live {
                liveDayCard
            } else {
                compactCard
            }

            // Only non-members get a shortcut (to join). Members don't need a
            // redirect — the Feed/Chats tab is where their chats live now.
            if familyFest != nil && !isMember {
                Divider().background(Color.mlrFest.opacity(0.15))
                joinCTA
            }
        }
        .background(Color.mlrFestParchment)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.mlrFest.opacity(0.2), lineWidth: 1)
        )
        .task {
            // Make sure committee membership is known so the shortcut points the
            // right way. Cheap + guarded so it doesn't refetch on every appearance.
            if env.committeeService.committees.isEmpty {
                await env.committeeService.fetchCommittees()
            }
            if env.isSignedIn,
               env.committeeService.myMemberships.isEmpty,
               let uid = await env.authService.userId {
                await env.committeeService.fetchMyMemberships(userId: uid)
            }
        }
        .sheet(isPresented: $showJoinSheet) {
            if let ff = familyFest {
                CommitteeJoinSheet(committee: ff, onRequested: {})
            }
        }
    }

    // MARK: - Live day card (shows today's full schedule inline)

    private var liveDayCard: some View {
        NavigationLink(destination: FestOverviewView()) {
            VStack(alignment: .leading, spacing: 10) {
                // Header row
                HStack(spacing: 8) {
                    PulsingDot(color: Color.mlrFest)
                    Text("FAMILY FEST · HAPPENING NOW")
                        .font(.mlrScaled(10, weight: .bold))
                        .foregroundStyle(Color.mlrFest)
                        .tracking(0.8)
                    Spacer()
                }

                if let day = season.dayNumber {
                    Text("Day \(day) of \(season.totalDays) Up North 🎆")
                        .font(.festSerif(17, weight: .bold))
                        .foregroundStyle(Color.mlrFest)
                }

                // Today's events
                if !todayEvents.isEmpty || todayDinner != nil {
                    VStack(spacing: 6) {
                        ForEach(todayEvents) { event in
                            liveEventRow(event)
                        }
                        if let dinner = todayDinner {
                            liveDinnerRow(dinner)
                        }
                    }
                } else {
                    Text("See everything planned for this week →")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrFest.opacity(0.7))
                }

                Text("Open Family Fest for more →")
                    .font(.mlrScaled(11, weight: .semibold))
                    .foregroundStyle(Color.mlrFest.opacity(0.7))
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func liveEventRow(_ event: ScheduleItem) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.mlrScaled(13, weight: .medium))
                    .foregroundStyle(Color.mlrFest)
                    .lineLimit(1)
                if let loc = event.location, env.isSignedIn {
                    Text("📍 \(loc)")
                        .font(.mlrScaled(11))
                        .foregroundStyle(Color.mlrFest.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(event.time)
                .font(.mlrScaled(11, weight: .medium))
                .foregroundStyle(Color.mlrFest.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.mlrFest.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func liveDinnerRow(_ dinner: FestDinner) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("🍽️ Dinner · \(dinner.title)")
                    .font(.mlrScaled(13, weight: .medium))
                    .foregroundStyle(Color.mlrFest)
                    .lineLimit(1)
                if dinner.menu != "TBD" {
                    Text(dinner.menu)
                        .font(.mlrScaled(11))
                        .foregroundStyle(Color.mlrFest.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer()
            if dinner.time != "TBD" {
                Text(dinner.time)
                    .font(.mlrScaled(11, weight: .medium))
                    .foregroundStyle(Color.mlrFest.opacity(0.7))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.mlrFest.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Compact card (off-season / planning / wrap)

    private var compactCard: some View {
        NavigationLink(destination: FestOverviewView()) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.mlrFest.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Image(systemName: iconName)
                        .font(.mlrScaled(20))
                        .foregroundStyle(Color.mlrFest)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Family Fest 2026")
                        .font(.festSerif(16, weight: .bold))
                        .foregroundStyle(Color.mlrFest)
                    Text(statusLine)
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrFest.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.mlrScaled(13, weight: .semibold))
                    .foregroundStyle(Color.mlrFest.opacity(0.4))
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Smart shortcut

    private var joinCTA: some View {
        Button {
            guard env.isSignedIn else { env.authService.promptSignIn(); return }
            showJoinSheet = true
        } label: {
            ctaLabel(icon: "hand.raised.fill", text: "Join the Family Fest committee")
        }
        .buttonStyle(.plain)
    }

    private func ctaLabel(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.mlrScaled(13, weight: .semibold))
            Text(text)
                .font(.mlrScaled(14, weight: .semibold))
            Spacer()
            Image(systemName: "chevron.right")
                .font(.mlrScaled(12, weight: .semibold))
                .foregroundStyle(Color.mlrFest.opacity(0.4))
        }
        .foregroundStyle(Color.mlrFest)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - PulsingDot
// Animated live indicator dot used in the live phase.

struct PulsingDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: 14, height: 14)
                .scaleEffect(pulsing ? 1.5 : 1.0)
                .opacity(pulsing ? 0 : 1)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}
