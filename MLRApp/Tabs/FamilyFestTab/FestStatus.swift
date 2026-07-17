import SwiftUI

// MARK: - FestStatus
// Phase-aware status card shown at the top of FestOverviewView.
// Mirrors the FestStatus component from the web app.
//
// Design: headings in Cinzel wine (`mlrFest`); running body text in a readable
// system font colored `mlrFestInk` (sepia/cream) so it stops reading as low-
// contrast tinted grey. The live card carries a heraldic wine→gold accent bar
// and a pulsing live glyph for the "it's happening now" moment.

struct FestStatus: View {
    @Environment(AppEnvironment.self) private var env
    let season: FestSeason
    /// Admin "see as this day" preview — drives which day the live card treats as
    /// "today" (nil = the real today).
    var previewDate: Date? = nil

    var body: some View {
        switch season.phase {
        case .offSeason:
            OffSeasonCard()
        case .planning:
            PlanningCard(season: season)
        case .live:
            LiveCard(season: season, previewDate: previewDate)
        case .wrap:
            WrapCard(season: season)
        }
    }
}

// MARK: - Shared heraldic card chrome

private extension View {
    /// The Fest status-card surface: parchment card, a faint wine wash, and a
    /// gilded hairline. `accent` draws a heraldic wine→gold bar across the top.
    func festStatusCard(accent: Bool = false) -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.mlrFestCard)
                    .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.mlrFest.opacity(0.06)))
                    .overlay(alignment: .top) {
                        if accent {
                            LinearGradient.festHeraldic
                                .frame(height: 4)
                                .clipShape(UnevenRoundedRectangle(
                                    topLeadingRadius: 14, topTrailingRadius: 14))
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.mlrFestGold.opacity(0.4), lineWidth: 1.25))
            )
            .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}

// MARK: - Off-Season

private struct OffSeasonCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.mlrScaled(18))
                .foregroundStyle(Color.mlrFestGold)

            VStack(alignment: .leading, spacing: 2) {
                Text("Family Fest 2026")
                    .festHeadingStyle(size: 15)
                Text("\(FamilyFestConfig.dateRangeLabel) · Tomahawk, WI")
                    .font(.mlrScaled(12))
                    .foregroundStyle(Color.mlrFestInk.opacity(0.7))
            }
            Spacer()
        }
        .festStatusCard()
    }
}

// MARK: - Planning

private struct PlanningCard: View {
    let season: FestSeason

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .font(.mlrScaled(18, weight: .semibold))
                    .foregroundStyle(Color.mlrFest)
                Text("\(season.daysUntilStart) days until the Fest")
                    .font(.festSerif(16, weight: .bold))
                    .foregroundStyle(Color.mlrFest)
                    .contentTransition(.numericText())
                Spacer()
            }

            Text("Planning is underway — check the schedule below for what's taking shape.")
                .font(.mlrScaled(13))
                .foregroundStyle(Color.mlrFestInk.opacity(0.8))
        }
        .festStatusCard(accent: true)
    }
}

// MARK: - Live

private struct LiveCard: View {
    @Environment(AppEnvironment.self) private var env
    let season: FestSeason
    var previewDate: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                // Live pulsing glyph — SF Symbol effect, respects Reduce Motion.
                Image(systemName: "circle.fill")
                    .font(.mlrScaled(11))
                    .foregroundStyle(Color.mlrSuccess)
                    .symbolEffect(.pulse.wholeSymbol, options: .repeating)
                    .accessibilityHidden(true)

                if let day = season.dayNumber {
                    Text("Day \(day) of \(season.totalDays)")
                        .font(.festSerif(20, weight: .bold))
                        .foregroundStyle(Color.mlrFest)
                        .contentTransition(.numericText())
                }

                Spacer()

                // Live badge
                Text("LIVE")
                    .font(.mlrScaled(10, weight: .black))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.mlrSuccess)
                    .clipShape(Capsule())
            }

            // Today's schedule items and tonight's dinner — everything you
            // need for today, right in the status card so nobody has to scroll.
            let todayName = FestOverviewView.weekday(for: previewDate ?? .now)
            let todayItems = env.festContentService.schedule.filter { $0.day == todayName && $0.day != "Anytime" }
            let dinner = env.festContentService.dinners.first { $0.day == todayName }

            if !todayItems.isEmpty || dinner != nil {
                GoldOrnamentDivider()
                    .padding(.vertical, 2)

                // The whole schedule for the day — the same rich, tappable rows as
                // the day-by-day sections (time, location, about, leads; dinner
                // menu + crew, each self-editable), so "today"/the previewed day
                // shows everything inline, matching the web.
                VStack(spacing: 0) {
                    ForEach(Array(todayItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().background(Color.mlrFest.opacity(0.1)) }
                        ExpandableScheduleRow(item: item)
                    }
                    if let d = dinner {
                        Divider().background(Color.mlrFest.opacity(0.15))
                        ExpandableDinnerRow(dinner: d)
                    }
                }
                .festCardStyle(cornerRadius: 12)
            } else {
                Text("Check the schedule below for today's activities.")
                    .font(.mlrScaled(13))
                    .foregroundStyle(Color.mlrFestInk.opacity(0.8))
            }
        }
        .festStatusCard(accent: true)
    }
}

// MARK: - Wrap

private struct WrapCard: View {
    let season: FestSeason

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("📸")
                    .font(.mlrScaled(22))
                Text("Thanks for a great Fest!")
                    .font(.festSerif(16, weight: .bold))
                    .foregroundStyle(Color.mlrFest)
                Spacer()
            }

            Text("\(season.wrapDaysLeft) day\(season.wrapDaysLeft == 1 ? "" : "s") left to post photos")
                .font(.mlrScaled(13))
                .foregroundStyle(Color.mlrFestInk.opacity(0.8))
                .contentTransition(.numericText())
        }
        .festStatusCard(accent: true)
    }
}
