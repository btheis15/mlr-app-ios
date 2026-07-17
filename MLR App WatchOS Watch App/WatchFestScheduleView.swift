import SwiftUI
import MLRCore

// MARK: - Family Fest schedule (watch)
// Read-only day-by-day list, grouped by weekday.

struct WatchFestScheduleView: View {
    @Environment(WatchSessionReceiver.self) private var session

    @State private var items: [WatchFestItem] = []
    @State private var loaded = false

    // Preserve fetch order (already day → position) while grouping by day.
    private var days: [String] {
        var seen = Set<String>(), order: [String] = []
        for it in items where !seen.contains(it.sortDay) { seen.insert(it.sortDay); order.append(it.sortDay) }
        return order
    }

    var body: some View {
        List {
            if !session.isAuthed {
                Text("Open the MLR app on your iPhone to sync.")
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary)
            } else if items.isEmpty {
                Text(loaded ? "No schedule posted yet." : "Loading…")
                    .font(.system(size: 14, design: .rounded)).foregroundStyle(.secondary)
            } else {
                ForEach(days, id: \.self) { day in
                    Section(items.first { $0.sortDay == day }?.dayLabel ?? day) {
                        ForEach(items.filter { $0.sortDay == day }) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                                HStack(spacing: 6) {
                                    Text(item.time)
                                    if let loc = item.location { Text("· \(loc)").lineLimit(1) }
                                }
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                }
            }
        }
        .navigationTitle("Schedule")
        .task(id: session.isAuthed) {
            guard session.isAuthed else { return }
            items = await WatchData.festSchedule()
            loaded = true
        }
    }
}
