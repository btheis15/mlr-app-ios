import Foundation

// MARK: - House Stay (migration 0071)
//
// One member's booking on their house's shared calendar — "I'm going up on these
// dates, with these people." The member who submits has an account; everyone they
// bring along (spouse, kids, the dog, a friend) is a free name in `guestNames`
// with no account needed. Head count = 1 (the member) + guestNames.
//
// Built in HousesService from a row + the profiles join (author name/avatar),
// mirroring how HouseChatMessage is assembled — not decoded directly, so the
// author fields can come from the embedded profiles relation.

struct HouseStay: Identifiable, Equatable {
    let id: UUID
    let houseId: UUID
    let createdBy: UUID
    var authorName: String
    var authorAvatarUrl: String?
    var title: String?
    var startDate: String   // yyyy-MM-dd (America/Chicago), inclusive
    var endDate: String     // yyyy-MM-dd, inclusive (single-night ⇒ == startDate)
    var guestNames: [String]
    var note: String?
    var createdAt: Date

    // MARK: Derived

    var startDateParsed: Date? { HouseStay.iso.date(from: startDate) }
    var endDateParsed: Date? { HouseStay.iso.date(from: endDate) }

    /// Everyone on this stay: the member (1) + everyone they added.
    var headCount: Int { 1 + guestNames.count }

    /// A friendly label when the member left the title blank.
    var label: String {
        if let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        let first = authorName.split(separator: " ").first.map(String.init) ?? authorName
        return "\(first)'s stay"
    }

    /// True while this stay covers `today` (someone's up there now). ISO strings
    /// sort correctly, so plain string comparison is safe.
    func isActive(on today: String) -> Bool { startDate <= today && today <= endDate }

    /// True once the stay has fully ended.
    func isPast(_ today: String) -> Bool { endDate < today }

    /// Whether the stay covers a given ISO day.
    func covers(_ day: String) -> Bool { startDate <= day && day <= endDate }

    /// Every ISO day this stay spans, inclusive (DST/TZ-safe via the shared
    /// America/Chicago formatter). Capped so a bad range can't loop forever.
    func days() -> [String] {
        guard var d = HouseStay.iso.date(from: startDate),
              let last = HouseStay.iso.date(from: endDate) else { return [startDate] }
        var out: [String] = []
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        var i = 0
        while d <= last && i < 366 {
            out.append(HouseStay.iso.string(from: d))
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
            i += 1
        }
        return out
    }

    // MARK: Shared formatter

    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f
    }()

    /// A compact human range: "Jul 18" or "Jul 18 – Jul 20".
    var dateRangeLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        fmt.timeZone = TimeZone(identifier: "America/Chicago")
        guard let s = startDateParsed else { return startDate }
        let start = fmt.string(from: s)
        if endDate == startDate { return start }
        guard let e = endDateParsed else { return start }
        return "\(start) – \(fmt.string(from: e))"
    }
}
