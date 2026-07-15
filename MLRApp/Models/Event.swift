import Foundation

// MARK: - Resort Event

struct ResortEvent: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var description: String?
    var emoji: String? = nil
    var kind: EventKind
    var startDate: String
    var endDate: String?
    /// Optional "HH:MM" in resort local time (America/Chicago). When set, reminder
    /// offsets can be hour-based ("2 hours before"); otherwise only day-based.
    var startTime: String?
    var location: String?
    var dayRsvp: Bool
    var source: EventSource

    enum CodingKeys: String, CodingKey {
        case id, title, description, emoji, kind
        case startDate = "start_date"
        case endDate = "end_date"
        case startTime = "start_time"
        case location
        case dayRsvp = "day_rsvp"
        case source
    }

    var startDateParsed: Date? {
        DateComponents.isoDateFormatter.date(from: startDate)
    }

    var endDateParsed: Date? {
        guard let end = endDate else { return nil }
        return DateComponents.isoDateFormatter.date(from: end)
    }

    var isMultiDay: Bool {
        endDate != nil && endDate != startDate
    }

    var isFamilyFest: Bool { kind == .familyFest }
}

enum EventKind: String, Codable {
    case familyFest = "family_fest"
    case workWeekend = "work_weekend"
    case holiday
    case custom
}

enum EventSource: String, Codable {
    case seed   // synthesized in-app (Family Fest, 4th of July)
    case admin  // created in the app by an admin (DB `source = 'admin'`)
    case gcal   // imported from Google Calendar

    // The DB `source` column is 'admin' | 'gcal'; decode leniently so an
    // unknown value never throws (and admin events actually load).
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EventSource(rawValue: raw) ?? .admin
    }
}

// MARK: - Event Attendance

struct EventAttendance: Codable, Identifiable, Equatable {
    let eventId: String
    let userId: UUID
    var status: AttendanceStatus
    var days: [String: AttendanceStatus]?
    var updatedAt: Date?

    // event_attendance has a composite PK (event_id, user_id) — no id column.
    var id: String { "\(eventId)-\(userId.uuidString)" }

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case userId = "user_id"
        case status
        case days
        case updatedAt = "updated_at"
    }

    func effectiveStatus() -> AttendanceStatus {
        guard let days, !days.isEmpty else { return status }
        if days.values.contains(.going) { return .going }
        if days.values.contains(.maybe) { return .maybe }
        return .notGoing
    }
}

enum AttendanceStatus: String, Codable {
    case going
    case maybe
    case notGoing = "not_going"

    var label: String {
        switch self {
        case .going: return "Going"
        case .maybe: return "Maybe"
        case .notGoing: return "Can't make it"
        }
    }

    var emoji: String {
        switch self {
        case .going: return "✅"
        case .maybe: return "🤔"
        case .notGoing: return "❌"
        }
    }
}

// MARK: - Attendance Summary

struct AttendanceSummary {
    var going: Int
    var maybe: Int
    var notGoing: Int

    var total: Int { going + maybe + notGoing }
}

// MARK: - Helpers

private extension DateComponents {
    static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f
    }()
}
