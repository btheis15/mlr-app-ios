import SwiftUI
import Kingfisher

// MARK: - FestScheduleView

struct FestScheduleView: View {
    @Environment(AppEnvironment.self) private var env

    private let festDays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private var itemsByDay: [(day: String, items: [ScheduleItem])] {
        festDays.compactMap { day in
            let items = env.festContentService.schedule.filter { $0.day == day }
            guard !items.isEmpty else { return nil }
            return (day: day, items: items)
        }
    }

    private var thingsToDo: [ScheduleItem] {
        env.festContentService.schedule.filter { $0.day == "Anytime" }
    }

    /// ISO date (yyyy-MM-dd) for a fest day name, derived from the fest start
    /// date + the day's offset in `festDays`. Returns nil for "Anytime" / unknowns.
    private func isoDate(forDay day: String) -> String? {
        guard let dayIdx = festDays.firstIndex(of: day),
              let start = WeatherService.isoFormatter.date(from: FamilyFestConfig.startDate)
        else { return nil }
        // Offset the day name from the fest's START weekday (it begins Monday, not
        // Sunday) so each weekday maps to its real date instead of being a day off.
        let startIdx = Calendar.current.component(.weekday, from: start) - 1  // 0=Sun…6=Sat
        guard let date = Calendar.current.date(byAdding: .day, value: dayIdx - startIdx, to: start)
        else { return nil }
        return WeatherService.isoFormatter.string(from: date)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {

                // Scheduled events by day
                ForEach(itemsByDay, id: \.day) { group in
                    Section {
                        VStack(spacing: 1) {
                            ForEach(group.items) { item in
                                ScheduleListRow(item: item)
                            }
                        }
                        .background(Color.mlrFestParchment)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.mlrFest.opacity(0.15), lineWidth: 1)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    } header: {
                        DayHeader(day: group.day, isoDate: isoDate(forDay: group.day))
                    }
                }

                // Things To Do (anytime)
                if !thingsToDo.isEmpty {
                    Section {
                        VStack(spacing: 1) {
                            ForEach(thingsToDo) { item in
                                ScheduleListRow(item: item)
                            }
                        }
                        .background(Color.mlrFestParchment)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.mlrFest.opacity(0.15), lineWidth: 1)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    } header: {
                        DayHeader(day: "Things To Do")
                    }
                }
            }
            .padding(.top, 8)
        }
        .background(Color.mlrFestParchment)
        .task { if env.isSignedIn && !env.isPreviewing { _ = await env.festContentService.canEditFest() } }
    }
}

// MARK: - Row + pencil
// The pencil sits beside the link (not inside it) so tapping it never navigates.
// Shown to exactly the people web shows an Edit button to: a full editor, or
// this event's lead/crew. This list is always the current year; Past Years has
// its own read-only rows.

private struct ScheduleListRow: View {
    let item: ScheduleItem
    @Environment(AppEnvironment.self) private var env
    @State private var showEdit = false

    var body: some View {
        HStack(spacing: 0) {
            NavigationLink(destination: FestScheduleDetailView(item: item)) {
                ScheduleRow(item: item, isSignedIn: env.isSignedIn)
            }
            .buttonStyle(.pressable)
            if env.canEditFestEvent(item) {
                FestEditPencil(label: "event") { showEdit = true }
                    .padding(.trailing, 4)
                    .background(Color.mlrFestParchment)
            }
        }
        .sheet(isPresented: $showEdit) {
            FestScheduleEditSheet(item: item) { await env.festContentService.reload() }
        }
    }
}

// MARK: - Day Header

private struct DayHeader: View {
    let day: String
    var isoDate: String? = nil

    var body: some View {
        HStack {
            Text(day.uppercased())
                .font(.mlrScaled(13, weight: .bold))
                .foregroundStyle(Color.mlrFest.opacity(0.65))
                .tracking(1.2)
            Spacer()
            // Self-hides when WeatherKit has no forecast for the date (e.g. far out).
            if let isoDate {
                EventWeatherBadge(isoDate: isoDate)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mlrFestParchment)
    }
}

// MARK: - Schedule Row

private struct ScheduleRow: View {
    let item: ScheduleItem
    let isSignedIn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Time column
            Text(MLRFormat.time(item.time))
                .font(.mlrScaled(13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.mlrFestInk.opacity(0.6))
                .frame(width: 68, alignment: .leading)
                .padding(.top, 2)

            // Content column
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.festSerif(18, weight: .bold))
                    .foregroundStyle(Color.mlrFest)
                    .multilineTextAlignment(.leading)

                if let location = item.location {
                    if isSignedIn {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.mlrScaled(14))
                            .foregroundStyle(Color.mlrFestInk.opacity(0.7))
                    } else {
                        Label("Sign in to see location", systemImage: "lock.fill")
                            .font(.mlrScaled(14))
                            .foregroundStyle(Color.mlrFest.opacity(0.4))
                    }
                }
            }

            Spacer()

            // Event photo thumbnail (the full photo, with zoom, is on the detail screen).
            if let url = item.imageUrl.flatMap(URL.init(string:)) {
                KFImage(url)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }

            Image(systemName: "chevron.right")
                .font(.mlrScaled(13, weight: .semibold))
                .foregroundStyle(Color.mlrFest.opacity(0.3))
                .padding(.top, 3)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(Color.mlrFestParchment)
    }
}
