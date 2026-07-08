import AppIntents
import Foundation

// MARK: - Resort life intents (Siri / Apple Intelligence)
//
// Practical day-to-day questions about being up north: the weather at the lake,
// which cabins are free, Family Fest dues + who to pay, how to pay a person, and
// whether anyone needs a hand. All read live and speak an answer.

private let resortTZ = TimeZone(identifier: "America/Chicago")!
private func isoDay(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = resortTZ
    return f.string(from: date)
}

// MARK: - Weather at the lake

struct WeatherUpNorthIntent: AppIntent {
    static var title: LocalizedStringResource = "Weather Up North"
    static var description = IntentDescription("The forecast at the resort (uses the lake's location).")

    @Parameter(title: "When", default: .thisWeekend)
    var period: EventPeriod

    static var parameterSummary: some ParameterSummary {
        Summary("What's the weather \(\.$period) up north")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let start: String
        let end: String
        if let r = period.range {
            start = isoDay(r.start)
            end = isoDay(r.end.addingTimeInterval(-1))
        } else {
            start = isoDay(Date())
            end = isoDay(Date().addingTimeInterval(5 * 86400))
        }
        let forecasts = await WeatherService.shared.forecasts(fromISO: start, toISO: end)
        guard !forecasts.isEmpty else {
            return .result(
                dialog: "I don't have the forecast for \(period.label) yet — WeatherKit only reaches about 10 days out.",
                view: SimpleInfoSnippet(symbol: "cloud.sun", title: "Weather up north", subtitle: "Not available for \(period.label) yet")
            )
        }
        let lines = forecasts.prefix(5).map { f in
            "\(f.weekdayLabel): \(f.condition), high \(f.highLabel()), \(f.precipPercent)% rain"
        }.joined(separator: "; ")
        let days = forecasts.prefix(5).map {
            WeatherSnippet.Day(weekday: $0.weekdayLabel, symbol: $0.symbolName, high: $0.highLabel(), precip: $0.precipPercent)
        }
        return .result(
            dialog: IntentDialog(stringLiteral: "Up north \(period.label): \(lines)."),
            view: WeatherSnippet(title: "Weather up north — \(period.label)", days: days)
        )
    }
}

// MARK: - Cabin availability

struct CabinAvailabilityIntent: AppIntent {
    static var title: LocalizedStringResource = "Cabin Availability"
    static var description = IntentDescription("See which cabins have open rooms over a stretch of days.")

    @Parameter(title: "When", default: .thisWeekend)
    var period: EventPeriod

    static var parameterSummary: some ParameterSummary {
        Summary("Which cabins are open \(\.$period)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let checkIn: String
        let checkOut: String
        if let r = period.range {
            checkIn = isoDay(r.start)
            checkOut = isoDay(r.end)
        } else {
            checkIn = isoDay(Date())
            checkOut = isoDay(Date().addingTimeInterval(2 * 86400))
        }
        let avail = await CabinService().fetchAvailability(checkIn: checkIn, checkOut: checkOut)
        let open = avail.filter { $0.available > 0 }
        guard !open.isEmpty else {
            return .result(dialog: "No cabins have open rooms \(period.label).")
        }
        let list = open.map { "\($0.name) (\($0.available) room\($0.available == 1 ? "" : "s"))" }.joined(separator: ", ")
        return .result(dialog: IntentDialog(stringLiteral: "Open \(period.label): \(list)."))
    }
}

// MARK: - Family Fest dues + who to pay

struct FestDuesIntent: AppIntent {
    static var title: LocalizedStringResource = "Family Fest Dues"
    static var description = IntentDescription("How much Family Fest dues are and who to pay.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let svc = FestContentService()
        await svc.load()
        let tiers = svc.dues.filter { $0.amount != nil }
        var sentence: String
        if tiers.isEmpty {
            sentence = "Family Fest dues aren't posted yet."
        } else {
            let parts = tiers.map { "\($0.label): $\($0.amount!)" }.joined(separator: ", ")
            sentence = "Family Fest dues — \(parts)."
        }
        if let payee = svc.payees.first {
            var pay = " Pay \(payee.name)"
            if let v = payee.venmo, !v.isEmpty { pay += " on Venmo (\(v))" }
            pay += "."
            sentence += pay
        }
        return .result(dialog: IntentDialog(stringLiteral: sentence))
    }
}

// MARK: - How to pay a person

struct HowToPayIntent: AppIntent {
    static var title: LocalizedStringResource = "How to Pay Someone"
    static var description = IntentDescription("Find a family member's payment handles (Venmo, Zelle, etc.).")

    @Parameter(title: "Member", requestValueDialog: "Who do you want to pay?")
    var member: MemberEntity

    static var parameterSummary: some ParameterSummary {
        Summary("How do I pay \(\.$member)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        struct Row: Decodable { let venmo: String?; let zelle: String?; let cashapp: String?; let paypal: String? }
        let rows: [Row] = (try? await supabase
            .from("profiles")
            .select("venmo, zelle, cashapp, paypal")
            .eq("id", value: member.id.uuidString)
            .limit(1)
            .execute().value) ?? []
        guard let r = rows.first else {
            return .result(dialog: "I couldn't find \(member.name)'s profile.")
        }
        var methods: [String] = []
        if let v = r.venmo, !v.isEmpty { methods.append("Venmo \(v)") }
        if let z = r.zelle, !z.isEmpty { methods.append("Zelle \(z)") }
        if let c = r.cashapp, !c.isEmpty { methods.append("Apple Cash / Cash App \(c)") }
        if let p = r.paypal, !p.isEmpty { methods.append("PayPal \(p)") }
        guard !methods.isEmpty else {
            return .result(dialog: "\(member.name) hasn't added a payment method yet.")
        }
        return .result(dialog: IntentDialog(stringLiteral: "Pay \(member.name) via \(methods.joined(separator: ", "))."))
    }
}

// MARK: - Anyone need help?

struct HelpNeededIntent: AppIntent {
    static var title: LocalizedStringResource = "Help Needed"
    static var description = IntentDescription("See if anyone at the resort needs a hand right now.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        struct Row: Decodable {
            let description: String?
            let profiles: A?
            struct A: Decodable { let displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
        }
        let rows: [Row] = (try? await supabase
            .from("help_requests")
            .select("description, profiles!user_id(display_name)")
            .eq("status", value: "open")
            .order("created_at", ascending: false)
            .limit(10)
            .execute().value) ?? []
        guard !rows.isEmpty else {
            return .result(dialog: "No one needs a hand up north right now. 👍")
        }
        let asks = rows.prefix(4).compactMap { r -> String? in
            guard let what = r.description?.trimmingCharacters(in: .whitespacesAndNewlines), !what.isEmpty else { return nil }
            let who = r.profiles?.displayName ?? "Someone"
            return "\(who): \(what)"
        }.joined(separator: "; ")
        let count = rows.count
        return .result(dialog: IntentDialog(stringLiteral: "\(count) help request\(count == 1 ? "" : "s") up north — \(asks)."))
    }
}
