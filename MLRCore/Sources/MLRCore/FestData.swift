import Foundation

// MARK: - Watch Fest schedule read layer
//
// The Family Fest day-by-day schedule (fest_schedule_items). Lean DTO for a
// glanceable watch list, grouped by day. Year is pinned to the fest (keep in
// sync with the countdown dates in the watch ContentView / FamilyFestConfig).

public struct WatchFestItem: Identifiable, Sendable {
    public let id: UUID
    public let dayLabel: String    // "Monday"
    public let sortDay: String     // yyyy-MM-dd (grouping/order)
    public let time: String        // "6:00 PM" or "TBD"
    public let title: String       // emoji + title
    public let location: String?
}

extension WatchData {
    /// This year's Family Fest schedule, ordered by day then position.
    public static func festSchedule(year: Int = 2026) async -> [WatchFestItem] {
        struct Row: Decodable {
            let id: UUID
            let day: String
            let startTime: String?
            let title: String
            let emoji: String?
            let location: String?
            let isPrivate: Bool?
            enum CodingKeys: String, CodingKey {
                case id, day, title, emoji, location
                case startTime = "start_time"
                case isPrivate = "is_private"
            }
        }
        let rows: [Row] = (try? await supabase.from("fest_schedule_items")
            .select("id, day, start_time, title, emoji, location, is_private, position")
            .eq("fest_year", value: year)
            .order("day", ascending: true)
            .order("position", ascending: true)
            .execute().value) ?? []

        return rows.compactMap { r in
            if r.isPrivate == true { return nil }
            let titled = [r.emoji, r.title].compactMap { $0?.nilIfEmpty }.joined(separator: " ")
            return WatchFestItem(
                id: r.id,
                dayLabel: Self.weekday(fromISO: r.day) ?? r.day,
                sortDay: r.day,
                time: r.startTime?.nilIfEmpty ?? "TBD",
                title: titled.isEmpty ? r.title : titled,
                location: r.location?.nilIfEmpty
            )
        }
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func weekday(fromISO iso: String) -> String? {
        guard let date = isoDay.date(from: iso) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f.string(from: date)
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
