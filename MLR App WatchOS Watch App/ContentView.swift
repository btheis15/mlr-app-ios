//
//  ContentView.swift
//  MLR App WatchOS Watch App
//
//  Watch home: a Family Fest countdown hero + navigation into the stripped-down
//  companion features (Work Items now; Chats + Fest schedule next). Live data
//  needs the session the paired iPhone pushes (see WatchSessionReceiver).
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

private extension Color {
    static let festGold = Color(red: 0.82, green: 0.66, blue: 0.32)
}

// MARK: - Home

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TimelineView(.everyMinute) { context in
                        FestCountdownCard(state: WatchFest.state(now: context.date))
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Family") {
                    NavigationLink { WatchWorkItemsView() } label: {
                        Label("Work Items", systemImage: "checklist")
                    }
                    // Chats + Family Fest schedule land here next.
                }
            }
            .navigationTitle("MLR")
        }
    }
}

private struct FestCountdownCard: View {
    let state: WatchFestState

    var body: some View {
        VStack(spacing: 4) {
            Text("FAMILY FEST")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(Color.festGold)
            headline
            Text(WatchFest.range)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var headline: some View {
        switch state.phase {
        case .upcoming:
            VStack(spacing: 0) {
                Text("\(state.daysUntilStart)")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(state.daysUntilStart == 1 ? "day to go" : "days to go")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
        case .live:
            VStack(spacing: 1) {
                Text("HAPPENING NOW")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
                Text("Day \(state.dayNumber ?? 1) of \(state.totalDays)")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
            }
        case .wrap:
            Text("That's a wrap! 🎉")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        case .offSeason:
            Text("See you Up North")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    ContentView()
        .environment(WatchSessionReceiver.shared)
}
