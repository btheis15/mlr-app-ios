import WidgetKit
import SwiftUI

// MARK: - Next Event Widget
//
// Shows the nearest upcoming resort event. The app writes the next event into the
// shared App Group UserDefaults (`SharedStore`) whenever events refresh; the widget
// reads that snapshot so it works offline and without a Supabase call in the
// extension. If nothing has been written yet it falls back to the seed events.

struct NextEventWidget: Widget {
    let kind = "NextEventWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextEventProvider()) { entry in
            NextEventEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next at the Resort")
        .description("The next upcoming gathering at Muskellunge Lake Resort.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct NextEventEntry: TimelineEntry {
    let date: Date
    let title: String
    let dateLabel: String
    let kindEmoji: String
    let hasEvent: Bool
}

struct NextEventProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextEventEntry {
        .init(date: .now, title: "Family Fest 2026", dateLabel: "Aug 2", kindEmoji: "🌲", hasEvent: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextEventEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEventEntry>) -> Void) {
        let entry = currentEntry()
        let cal = Calendar.current
        let nextMidnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: .now)) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextMidnight)))
    }

    private func currentEntry() -> NextEventEntry {
        // The app publishes the next event into the App Group whenever events
        // refresh; the widget reads that snapshot, so it needs no network call
        // and no app-model dependencies.
        guard let snapshot = SharedStore.shared.nextEvent else {
            return .init(date: .now, title: "Nothing scheduled yet",
                         dateLabel: "", kindEmoji: "🌲", hasEvent: false)
        }
        return .init(date: .now,
                     title: snapshot.title,
                     dateLabel: Self.shortDate(fromISO: snapshot.startDate),
                     kindEmoji: snapshot.emoji,
                     hasEvent: true)
    }

    /// ISO `yyyy-MM-dd` → "Aug 3". Self-contained so the widget shares no code
    /// with the app's `Formatters`.
    private static func shortDate(fromISO iso: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        return out.string(from: date)
    }
}

struct NextEventEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextEventEntry

    var body: some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 2) {
                Text("Next at MLR").font(.headline)
                Text("\(entry.kindEmoji) \(entry.title)").font(.caption).lineLimit(1)
                Text(entry.dateLabel).font(.caption2).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Next at the resort")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.mlrPrimary)
                Spacer()
                Text(entry.kindEmoji)
                    .font(.system(size: family == .systemMedium ? 40 : 32))
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(entry.dateLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(URL(string: "mlr://events"))
        }
    }
}

// MARK: - Things To Do Widget
//
// Shows open items from the resort Work Checklist. The app publishes a snapshot
// to the App Group (`SharedStore.todo`) whenever work items refresh, so the
// widget renders without a network call.

struct ThingsToDoWidget: Widget {
    let kind = "ThingsToDoWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ThingsToDoProvider()) { entry in
            ThingsToDoEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Things to Do")
        .description("Open items on the resort work checklist.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct ThingsToDoEntry: TimelineEntry {
    let date: Date
    let openCount: Int
    let titles: [String]
}

struct ThingsToDoProvider: TimelineProvider {
    func placeholder(in context: Context) -> ThingsToDoEntry {
        .init(date: .now, openCount: 3, titles: ["Rake the beach", "Fix the dock ladder", "Stack firewood"])
    }

    func getSnapshot(in context: Context, completion: @escaping (ThingsToDoEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ThingsToDoEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .atEnd))
    }

    private func currentEntry() -> ThingsToDoEntry {
        let todo = SharedStore.shared.todo
        return .init(date: .now, openCount: todo?.openCount ?? 0, titles: todo?.titles ?? [])
    }
}

struct ThingsToDoEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ThingsToDoEntry

    var body: some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 2) {
                Text("🔧 To do (\(entry.openCount))").font(.headline)
                if let first = entry.titles.first {
                    Text(first).font(.caption).lineLimit(1)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("🔧 Things to do")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.mlrPrimary)
                    Spacer()
                    Text("\(entry.openCount)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    // Quick-add: opens the app straight to the add-work-item form.
                    Link(destination: URL(string: "mlr://add-work-item")!) {
                        Image(systemName: "plus.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.mlrPrimary)
                    }
                }
                if entry.titles.isEmpty {
                    Spacer()
                    Text("All caught up ✅")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ForEach(entry.titles.prefix(family == .systemMedium ? 3 : 2), id: \.self) { title in
                        HStack(spacing: 6) {
                            Image(systemName: "circle")
                                .font(.caption2)
                                .foregroundStyle(Color.mlrPrimary)
                            Text(title).font(.subheadline).lineLimit(1)
                        }
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(URL(string: "mlr://home"))
        }
    }
}

// MARK: - Next Visit Up North Widget
//
// Shows the next upcoming stay from the house calendars. The app publishes a
// snapshot to the App Group (`SharedStore.nextVisit`) on launch, so the widget
// renders without a network call.

struct NextVisitWidget: Widget {
    let kind = "NextVisitWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextVisitProvider()) { entry in
            NextVisitEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next Visit Up North")
        .description("The next time someone's heading up to the resort.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct NextVisitEntry: TimelineEntry {
    let date: Date
    let visit: VisitSnapshot?
}

struct NextVisitProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextVisitEntry {
        .init(date: .now, visit: VisitSnapshot(who: "The Theis family", dateLabel: "Jul 18 – 20", house: "MJT House"))
    }
    func getSnapshot(in context: Context, completion: @escaping (NextVisitEntry) -> Void) {
        completion(.init(date: .now, visit: SharedStore.shared.nextVisit))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextVisitEntry>) -> Void) {
        completion(Timeline(entries: [.init(date: .now, visit: SharedStore.shared.nextVisit)], policy: .atEnd))
    }
}

struct NextVisitEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextVisitEntry

    var body: some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 2) {
                Text("🏡 Next up north").font(.headline)
                if let v = entry.visit {
                    Text("\(v.who) · \(v.dateLabel)").font(.caption).lineLimit(1)
                } else {
                    Text("Nothing booked").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("🏡 Next up north")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.mlrPrimary)
                if let v = entry.visit {
                    Text(v.who).font(.headline).lineLimit(2)
                    Text(v.dateLabel).font(.subheadline).foregroundStyle(.secondary)
                    if let h = v.house, family == .systemMedium {
                        Text(h).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Spacer()
                    Text("No visits booked yet")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(URL(string: "mlr://houses"))
        }
    }
}
