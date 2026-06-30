import SwiftUI

// MARK: - FamilyFestSpotlight
// Phase-aware spotlight card shown at the top of the Home screen (below the logo).
// Mirrors components/FamilyFestSpotlight.tsx.
//
// Phases:
//   .offSeason — quiet small banner
//   .planning  — countdown card with volunteer CTA
//   .live      — full hero card with day counter + today's highlights
//   .wrap      — photo upload nudge

struct FamilyFestSpotlight: View {
    let season: FestSeason

    /// One headline activity per day (the timed schedule, excluding the
    /// "anytime" items) — previewed on the planning card.
    private var scheduleHeadlines: [ScheduleItem] {
        ScheduleItem.seed.filter { $0.day != "Anytime" }
    }

    private static let festDayOrder = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// "Mon, Jul 27" for a fest weekday name, derived from the fest start date.
    private func dayDateLabel(_ day: String) -> String? {
        guard let dayIdx = Self.festDayOrder.firstIndex(of: day),
              let start = WeatherService.isoFormatter.date(from: FamilyFestConfig.startDate)
        else { return nil }
        let startIdx = Calendar.current.component(.weekday, from: start) - 1  // 0=Sun…6=Sat
        guard let date = Calendar.current.date(byAdding: .day, value: dayIdx - startIdx, to: start)
        else { return nil }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var body: some View {
        switch season.phase {
        case .offSeason:
            offSeasonBanner
        case .planning:
            planningCard
        case .live:
            liveHeroCard
        case .wrap:
            wrapCard
        }
    }

    // MARK: - Off-season: quiet text link

    private var offSeasonBanner: some View {
        NavigationLink(destination: FestOverviewView()) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(Color.mlrFest)
                Text("Family Fest 2026 · \(MLRFormat.dateRange(start: FamilyFestConfig.startDate, end: FamilyFestConfig.endDate))")
                    .font(.subheadline)
                    .foregroundStyle(Color.mlrFest)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Color.mlrTextMuted)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Planning: countdown + volunteer CTA

    private var planningCard: some View {
        NavigationLink(destination: FestOverviewView()) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Family Fest 2026")
                            .font(.festSerif(16, weight: .bold))
                            .foregroundStyle(Color.mlrFest)
                        Text(MLRFormat.dateRange(
                            start: FamilyFestConfig.startDate,
                            end: FamilyFestConfig.endDate
                        ))
                        .font(.caption)
                        .foregroundStyle(Color.mlrFest.opacity(0.8))
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text("\(season.daysUntilStart)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.mlrFest)
                        Text("days to go")
                            .font(.caption2)
                            .foregroundStyle(Color.mlrFest.opacity(0.7))
                    }
                }

                // Headline — matches the web's "taking shape" framing.
                Text(season.isSoon
                     ? "Almost here — final plans coming together"
                     : "\(season.daysUntilStart) days out — here's what's taking shape")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mlrFest)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()
                    .background(Color.mlrFest.opacity(0.2))

                // What's planned so far — one headline activity per day.
                if !scheduleHeadlines.isEmpty {
                    VStack(spacing: 9) {
                        ForEach(scheduleHeadlines) { item in
                            HStack(spacing: 8) {
                                Text(item.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.mlrFest)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if let label = dayDateLabel(item.day) {
                                    Text(label)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.mlrFest.opacity(0.55))
                                }
                            }
                        }
                    }
                    Divider()
                        .background(Color.mlrFest.opacity(0.2))
                }

                HStack(spacing: 6) {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(Color.mlrFest)
                    Text("Volunteers welcome — see the plans & pitch in")
                        .font(.subheadline)
                        .foregroundStyle(Color.mlrFest.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("View Family Fest →")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.mlrFest)
                    .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.mlrFestParchment)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.mlrFest.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Live: hero card with day counter + today's highlight

    private var liveHeroCard: some View {
        NavigationLink(destination: FestOverviewView()) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            // Pulsing live indicator
                            PulsingDot(color: Color.mlrFest)
                            Text("Live Now")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.mlrFest)
                        }
                        if let day = season.dayNumber {
                            Text("Day \(day) of \(season.totalDays)")
                                .font(.festSerif(22, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        Text("Family Fest 2026")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Image(systemName: "star.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Text("Tap to see today's schedule →")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.2))
                    .clipShape(Capsule())
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.mlrFest, Color.mlrFest.opacity(0.75)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Wrap: photo nudge card

    private var wrapCard: some View {
        NavigationLink(destination: FestPhotosView()) {
            HStack(spacing: 14) {
                Text("📸")
                    .font(.system(size: 32))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Post your photos!")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.mlrFest)
                    Text("\(season.wrapDaysLeft) day\(season.wrapDaysLeft == 1 ? "" : "s") left to share memories")
                        .font(.subheadline)
                        .foregroundStyle(Color.mlrFest.opacity(0.8))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Color.mlrFest.opacity(0.6))
            }
            .padding(16)
            .background(Color.mlrFestParchment)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.mlrFest.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PulsingDot
// Animated live indicator dot used in the live phase card.

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
