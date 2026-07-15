import SwiftUI

// MARK: - FestStatus
// Phase-aware status card shown at the top of FestOverviewView.
// Mirrors the FestStatus component from the web app.

struct FestStatus: View {
    @Environment(AppEnvironment.self) private var env
    let season: FestSeason

    var body: some View {
        switch season.phase {
        case .offSeason:
            OffSeasonCard()
        case .planning:
            PlanningCard(season: season)
        case .live:
            LiveCard(season: season)
        case .wrap:
            WrapCard(season: season)
        }
    }
}

// MARK: - Off-Season

private struct OffSeasonCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .font(.mlrScaled(18))
                .foregroundStyle(Color.mlrFest.opacity(0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text("Family Fest 2026")
                    .font(.festSerif(15, weight: .bold))
                    .foregroundStyle(Color.mlrFest)
                Text("\(FamilyFestConfig.dateRangeLabel) · Tomahawk, WI")
                    .font(.festSerif(12))
                    .foregroundStyle(Color.mlrFest.opacity(0.65))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.mlrFestCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.mlrFest.opacity(0.2), lineWidth: 1)
                )
        )
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
                Spacer()
            }

            Text("Planning is underway — check the schedule below for what's taking shape.")
                .font(.festSerif(13))
                .foregroundStyle(Color.mlrFest.opacity(0.75))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.mlrFestCard)
                .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.mlrFest.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.mlrFest.opacity(0.25), lineWidth: 1.5))
        )
    }
}

// MARK: - Live

private struct LiveCard: View {
    @Environment(AppEnvironment.self) private var env
    let season: FestSeason
    @State private var dotPulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                // Live pulsing dot
                ZStack {
                    Circle()
                        .fill(Color.mlrSuccess.opacity(0.3))
                        .frame(width: 20, height: 20)
                        .scaleEffect(dotPulse ? 1.5 : 1)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: dotPulse)
                    Circle()
                        .fill(Color.mlrSuccess)
                        .frame(width: 10, height: 10)
                }

                if let day = season.dayNumber {
                    Text("Day \(day) of \(season.totalDays)")
                        .font(.festSerif(20, weight: .bold))
                        .foregroundStyle(Color.mlrFest)
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
            let todayName = FestOverviewView.todayWeekday
            let todayItems = env.festContentService.schedule.filter { $0.day == todayName && $0.day != "Anytime" }
            let dinner = env.festContentService.dinners.first { $0.day == todayName }

            if !todayItems.isEmpty || dinner != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(todayItems) { item in
                        HStack(spacing: 6) {
                            Text(MLRFormat.time(item.time))
                                .font(.mlrScaled(12, weight: .medium))
                                .foregroundStyle(Color.mlrFest.opacity(0.6))
                                .frame(width: 60, alignment: .leading)
                            Text(item.title)
                                .font(.mlrScaled(13, weight: .medium))
                                .foregroundStyle(Color.mlrFest)
                                .lineLimit(1)
                        }
                    }
                    if let d = dinner {
                        // Tonight's dinner — plain card, no tint (matches web PR #291).
                        HStack(spacing: 6) {
                            Text(d.time == "TBD" ? "Dinner" : MLRFormat.time(d.time))
                                .font(.mlrScaled(12, weight: .medium))
                                .foregroundStyle(Color.mlrFest.opacity(0.6))
                                .frame(width: 60, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("🍽️ Dinner · \(d.title)")
                                    .font(.mlrScaled(13, weight: .medium))
                                    .foregroundStyle(Color.mlrFest)
                                    .lineLimit(1)
                                if d.menu != "TBD" {
                                    Text(d.menu)
                                        .font(.mlrScaled(11))
                                        .foregroundStyle(Color.mlrFest.opacity(0.6))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } else {
                Text("Check the schedule below for today's activities.")
                    .font(.festSerif(13))
                    .foregroundStyle(Color.mlrFest.opacity(0.75))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.mlrFestCard)
                .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.mlrFest.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.mlrFest.opacity(0.3), lineWidth: 1.5))
        )
        .onAppear { dotPulse = true }
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
                .font(.festSerif(13))
                .foregroundStyle(Color.mlrFest.opacity(0.75))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.mlrFestCard)
                .overlay(RoundedRectangle(cornerRadius: 14).fill(Color.mlrFest.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.mlrFest.opacity(0.25), lineWidth: 1.5))
        )
    }
}
