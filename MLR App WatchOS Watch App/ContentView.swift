//
//  ContentView.swift
//  MLR App WatchOS Watch App
//
//  The watch app's home screen: a glanceable Family Fest countdown.
//
//  Self-contained on purpose — the fest dates + countdown logic are duplicated
//  here (mirroring FestSeason.swift / FamilyFestConfig in the iOS app) so the
//  watch target builds without depending on iOS-only source files. When we wire
//  the watch to Supabase + the shared session (App Group), the live schedule /
//  next-event data can replace the static messaging below.
//

import SwiftUI

// MARK: - Fest dates (keep in sync with FamilyFestConfig in the iOS app)

private enum WatchFest {
    static let startISO = "2026-07-27"
    static let endISO   = "2026-07-31"

    static var range: String { "July 27 – 31" }

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Countdown state for `now`, mirroring the iOS FestSeason phases.
    static func state(now: Date = .now) -> WatchFestState {
        guard let start = iso.date(from: startISO), let end = iso.date(from: endISO) else {
            return WatchFestState(phase: .offSeason, daysUntilStart: 0, dayNumber: nil, totalDays: 0)
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let daysUntilStart = cal.dateComponents([.day], from: today, to: start).day ?? 0
        let daysSinceEnd   = cal.dateComponents([.day], from: end, to: today).day ?? 0
        let totalDays      = (cal.dateComponents([.day], from: start, to: end).day ?? 0) + 1

        if today >= start && today <= end {
            let day = (cal.dateComponents([.day], from: start, to: today).day ?? 0) + 1
            return WatchFestState(phase: .live, daysUntilStart: 0, dayNumber: day, totalDays: totalDays)
        }
        if daysSinceEnd > 0 && daysSinceEnd <= 14 {
            return WatchFestState(phase: .wrap, daysUntilStart: 0, dayNumber: nil, totalDays: totalDays)
        }
        return WatchFestState(phase: daysUntilStart > 0 ? .upcoming : .offSeason,
                              daysUntilStart: max(0, daysUntilStart), dayNumber: nil, totalDays: totalDays)
    }
}

private struct WatchFestState {
    enum Phase { case upcoming, live, wrap, offSeason }
    let phase: Phase
    let daysUntilStart: Int
    let dayNumber: Int?
    let totalDays: Int
}

// MARK: - Brand palette (Family Fest greens/gold)

private extension Color {
    static let festGreen = Color(red: 0.16, green: 0.42, blue: 0.26)
    static let festGold  = Color(red: 0.82, green: 0.66, blue: 0.32)
}

// MARK: - Home

struct ContentView: View {
    // TimelineView keeps the countdown honest without a manual timer.
    var body: some View {
        TimelineView(.everyMinute) { context in
            FestCountdownView(state: WatchFest.state(now: context.date))
        }
    }
}

private struct FestCountdownView: View {
    let state: WatchFestState

    var body: some View {
        VStack(spacing: 6) {
            Text("FAMILY FEST")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(Color.festGold)

            headline

            Text(WatchFest.range)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .containerBackground(
            LinearGradient(colors: [.festGreen.opacity(0.55), .black],
                           startPoint: .top, endPoint: .bottom),
            for: .navigation
        )
    }

    @ViewBuilder
    private var headline: some View {
        switch state.phase {
        case .upcoming:
            VStack(spacing: 0) {
                Text("\(state.daysUntilStart)")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(state.daysUntilStart == 1 ? "day to go" : "days to go")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
        case .live:
            VStack(spacing: 2) {
                Text("HAPPENING NOW")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                Text("Day \(state.dayNumber ?? 1) of \(state.totalDays)")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        case .wrap:
            Text("That's a wrap! 🎉")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        case .offSeason:
            Text("See you Up North")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    ContentView()
}
