import AppIntents
import Foundation

// MARK: - Resort-wide query intents (Siri / Apple Intelligence)
//
// Natural questions about the resort ("Up North") that read live data and speak
// an answer back — events over a period, the next time anyone's heading up (from
// the house calendars), and the running work-checklist ("things to get done").
// All read paths run in the app's process using the persisted Supabase session.

// MARK: - Period filter

enum EventPeriod: String, AppEnum {
    case today, thisWeekend, thisWeek, thisMonth, upcoming

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Time Period" }
    static var caseDisplayRepresentations: [EventPeriod: DisplayRepresentation] {
        [
            .today: "Today",
            .thisWeekend: "This Weekend",
            .thisWeek: "This Week",
            .thisMonth: "This Month",
            .upcoming: "Upcoming",
        ]
    }

    /// Inclusive [start, end] resort-local date bounds, or nil for "everything upcoming".
    var range: (start: Date, end: Date)? {
        let tz = TimeZone(identifier: "America/Chicago")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        func end(_ days: Int) -> Date { cal.date(byAdding: .day, value: days, to: startOfToday) ?? now }
        switch self {
        case .today:
            return (startOfToday, end(1))
        case .thisWeek:
            return (startOfToday, end(7))
        case .thisMonth:
            return (startOfToday, end(31))
        case .thisWeekend:
            // Next Saturday 00:00 through Monday 00:00 (or this weekend if already in it).
            let weekday = cal.component(.weekday, from: startOfToday) // 1=Sun…7=Sat
            let daysUntilSat = (7 - weekday) % 7 // Sat=7 → 0; Sun=1 → 6
            let sat = cal.date(byAdding: .day, value: daysUntilSat, to: startOfToday) ?? startOfToday
            let mon = cal.date(byAdding: .day, value: 2, to: sat) ?? sat
            return (sat, mon)
        case .upcoming:
            return nil
        }
    }
}

// MARK: - Events over a period

struct EventsForPeriodIntent: AppIntent {
    static var title: LocalizedStringResource = "Events at the Resort"
    static var description = IntentDescription("See what's happening at the resort over a period of time.")

    @Parameter(title: "When", default: .thisWeek)
    var period: EventPeriod

    static var parameterSummary: some ParameterSummary {
        Summary("What events are happening \(\.$period)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = EventsService()
        await svc.fetchEvents()
        var events = svc.upcomingEvents
        if let range = period.range {
            events = events.filter { ev in
                guard let d = ev.startDateParsed else { return false }
                return d >= range.start && d < range.end
            }
        }
        guard !events.isEmpty else {
            return .result(dialog: "I don't see any events \(period.label).")
        }
        let list = events.prefix(6).map { ev -> String in
            let when = ev.startDateParsed.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? ""
            return when.isEmpty ? ev.title : "\(ev.title) (\(when))"
        }.joined(separator: "; ")
        let more = events.count > 6 ? ", and more" : ""
        return .result(dialog: IntentDialog(stringLiteral: "\(period.label.capitalizedFirst): \(list)\(more)."))
    }
}

extension EventPeriod {
    var label: String {
        switch self {
        case .today: return "today"
        case .thisWeekend: return "this weekend"
        case .thisWeek: return "this week"
        case .thisMonth: return "this month"
        case .upcoming: return "coming up"
        }
    }
}

private extension String {
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
}

// MARK: - Next time someone's Up North (house calendars)

struct NextVisitUpNorthIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Visit Up North"
    static var description = IntentDescription("Find the next time someone is heading up to the resort, from the house calendars.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let tz = TimeZone(identifier: "America/Chicago")!
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.timeZone = tz
        let today = iso.string(from: Date())

        struct StayLite: Decodable {
            let start_date: String
            let end_date: String
            let title: String?
        }
        let rows: [StayLite] = (try? await supabase
            .from("house_stays")
            .select("start_date,end_date,title")
            .gte("end_date", value: today)
            .order("start_date", ascending: true)
            .limit(1)
            .execute()
            .value) ?? []

        guard let next = rows.first else {
            return .result(dialog: "There's nothing on the house calendars right now.")
        }

        let out = DateFormatter()
        out.dateFormat = "EEEE, MMMM d"
        out.locale = Locale(identifier: "en_US_POSIX")
        out.timeZone = tz
        let range: String = {
            guard let s = iso.date(from: next.start_date) else { return next.start_date }
            let start = out.string(from: s)
            if next.end_date == next.start_date { return start }
            if let e = iso.date(from: next.end_date) {
                return "\(start) through \(out.string(from: e))"
            }
            return start
        }()
        let titlePart = (next.title?.trimmingCharacters(in: .whitespaces).isEmpty == false) ? " — \(next.title!)" : ""
        return .result(dialog: IntentDialog(stringLiteral: "The next time someone's up north is \(range)\(titlePart)."))
    }
}

// MARK: - Things to get done Up North (work checklist)

struct ThingsToDoUpNorthIntent: AppIntent {
    static var title: LocalizedStringResource = "Things To Do Up North"
    static var description = IntentDescription("List some open items from the resort work checklist.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[WorkItemEntity]> & ProvidesDialog {
        let items = try await WorkItemEntityQuery.open()
        guard !items.isEmpty else {
            return .result(value: [], dialog: "The work checklist is all caught up. ✅")
        }
        let titles = items.prefix(6).map(\.title).joined(separator: "; ")
        let more = items.count > 6 ? ", and more" : ""
        let dialog = "Things to get done up north: \(titles)\(more)."
        return .result(value: items, dialog: IntentDialog(stringLiteral: dialog))
    }
}
