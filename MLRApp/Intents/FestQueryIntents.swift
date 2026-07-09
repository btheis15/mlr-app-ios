import AppIntents
import Foundation

// MARK: - Family Fest query intents (Siri / Apple Intelligence)
//
// Natural, parameterized questions about Family Fest that read live content via
// FestContentService (runs in the app's process, uses the persisted session).
// These answer things like "Who's responsible for dinner on Monday?" and
// "What's the plan for Friday at Family Fest?" — spoken back, no navigation.

// MARK: - Day filter (Shortcuts picker + Apple Intelligence)

/// A day the user can ask about. Fest content stores `day` as a weekday name
/// ("Monday"…), so relative choices resolve to the resort-local weekday.
enum FestDayFilter: String, AppEnum {
    case today, tomorrow
    case monday, tuesday, wednesday, thursday, friday, saturday, sunday

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Day" }
    static var caseDisplayRepresentations: [FestDayFilter: DisplayRepresentation] {
        [
            .today: "Today", .tomorrow: "Tomorrow",
            .monday: "Monday", .tuesday: "Tuesday", .wednesday: "Wednesday",
            .thursday: "Thursday", .friday: "Friday", .saturday: "Saturday", .sunday: "Sunday",
        ]
    }

    /// The resort-local weekday name ("Monday"…) this filter resolves to.
    var weekdayName: String {
        let tz = TimeZone(identifier: "America/Chicago")!
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = tz
        switch self {
        case .today:
            return fmt.string(from: Date())
        case .tomorrow:
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            return fmt.string(from: cal.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        case .monday:    return "Monday"
        case .tuesday:   return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday:  return "Thursday"
        case .friday:    return "Friday"
        case .saturday:  return "Saturday"
        case .sunday:    return "Sunday"
        }
    }
}

// MARK: - Who's making dinner

struct DinnerForDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Who's Making Dinner"
    static var description = IntentDescription(
        "Find out who's responsible for dinner at Family Fest on a given day, plus the menu and time."
    )

    @Parameter(title: "Day", default: .today)
    var day: FestDayFilter

    static var parameterSummary: some ParameterSummary {
        Summary("Who's making dinner on \(\.$day)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let svc = FestContentService()
        await svc.load()
        let target = day.weekdayName
        guard let dinner = svc.dinners.first(where: {
            $0.day.caseInsensitiveCompare(target) == .orderedSame
        }) else {
            return .result(
                dialog: "I don't see a Family Fest dinner scheduled for \(target) yet.",
                view: SimpleInfoSnippet(symbol: "fork.knife", title: "\(target) dinner", subtitle: "Not scheduled yet")
            )
        }

        var parts: [String] = ["\(target)'s dinner is \(dinner.title)"]
        if dinner.chef != "TBD" { parts.append("made by \(dinner.chef)") }
        if dinner.time != "TBD" { parts.append("served at \(MLRFormat.time(dinner.time))") }
        if let loc = dinner.location, !loc.isEmpty { parts.append("at \(loc)") }
        return .result(
            dialog: IntentDialog(stringLiteral: parts.joined(separator: ", ") + "."),
            view: DinnerSnippet(day: target, title: dinner.title, chef: dinner.chef, time: MLRFormat.time(dinner.time), menu: dinner.menuLines)
        )
    }
}

// MARK: - What's the plan for a day

struct FestScheduleForDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Family Fest Plan for a Day"
    static var description = IntentDescription(
        "See what's on the Family Fest schedule for a given day."
    )

    @Parameter(title: "Day", default: .today)
    var day: FestDayFilter

    static var parameterSummary: some ParameterSummary {
        Summary("What's the Family Fest plan on \(\.$day)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = FestContentService()
        await svc.load()
        let target = day.weekdayName
        let items = svc.schedule.filter {
            $0.day.caseInsensitiveCompare(target) == .orderedSame && !$0.isPrivate
        }
        guard !items.isEmpty else {
            return .result(dialog: "There's nothing on the Family Fest schedule for \(target) yet.")
        }
        let list = items.prefix(6).map { item -> String in
            let t = item.time == "TBD" ? "" : "\(MLRFormat.time(item.time)): "
            return "\(t)\(item.title)"
        }.joined(separator: "; ")
        let more = items.count > 6 ? ", and more" : ""
        return .result(dialog: IntentDialog(stringLiteral: "\(target) at Family Fest: \(list)\(more)."))
    }
}
