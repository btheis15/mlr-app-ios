import Foundation
import Supabase

// MARK: - Fest content models (DB-backed)

struct FestConfig: Equatable {
    var name: String
    var tagline: String?
    var startDate: String   // yyyy-MM-dd
    var endDate: String     // yyyy-MM-dd
}

/// A dues tier (Adult / Kid / per-day / without-food / …). `amount` nil = TBD.
struct FestDuesTier: Identifiable, Equatable {
    let id: UUID
    var label: String
    var amount: Int?
    var note: String?
}

struct Payee: Identifiable, Equatable {
    let id: UUID
    var name: String
    var role: String?
    var venmo: String?
    var zelle: String?
    var appleCash: String?
    var paypal: String?
    var amount: Int?
    var note: String?
}

// MARK: - FestContentService
//
// Loads the editable Family Fest content (migration 0053) — schedule, dinners,
// payees, anytime activities, and config — from the shared DB so it stays in
// sync with the web app. Maps rows onto the existing ScheduleItem / FestDinner
// structs the views already use. Falls back to the in-code SeedData when the
// tables are empty or unreachable (offline / migration not applied yet), so the
// app never shows nothing.

@Observable
@MainActor
final class FestContentService {
    var config: FestConfig?
    var schedule: [ScheduleItem] = ScheduleItem.seed   // timed items + anytime
    var dinners: [FestDinner] = FestDinner.seed
    var payees: [Payee] = FestContentService.seedPayees
    var dues: [FestDuesTier] = FestContentService.seedDues
    var loaded = false

    // Offline / pre-migration fallbacks so the Pay tab is never blank.
    static let seedDues: [FestDuesTier] = [
        FestDuesTier(id: UUID(), label: "Adult (high school & up)", amount: nil, note: nil),
        FestDuesTier(id: UUID(), label: "Kid (K–8th grade)", amount: nil, note: nil),
        FestDuesTier(id: UUID(), label: "Per day", amount: nil, note: "per person"),
        FestDuesTier(id: UUID(), label: "Without food", amount: nil, note: "per person"),
    ]
    static let seedPayees: [Payee] = [
        Payee(id: UUID(), name: "Cathy Hofer", role: "Family Fest dues — collects for the week",
              venmo: "Cathy-Hofer-1", zelle: nil, appleCash: nil, paypal: nil, amount: nil, note: nil)
    ]

    private let year = FamilyFestConfig.year

    func load(force: Bool = false) async {
        if loaded && !force { return }
        do {
            async let cfg = fetchConfig()
            async let sched = fetchSchedule()
            async let dins = fetchDinners()
            async let pays = fetchPayees()
            async let acts = fetchActivities()
            async let duesTiers = fetchDues()

            let (c, s, d, p, a, du) = try await (cfg, sched, dins, pays, acts, duesTiers)

            if let c { config = c }
            if !du.isEmpty { dues = du }
            // Timed schedule items + anytime activities, both as ScheduleItem so
            // the existing views (which group by weekday / filter "Anytime") work.
            let combined = s + a
            if !combined.isEmpty { schedule = combined }
            if !d.isEmpty { dinners = d }
            if !p.isEmpty { payees = p }
            loaded = true
        } catch {
            print("[FestContentService] load error (using seed fallback): \(error)")
        }
    }

    // MARK: - Fetches

    private func fetchConfig() async throws -> FestConfig? {
        let rows: [ConfigRow] = try await supabase
            .from("fest_config").select("*").eq("fest_year", value: year)
            .execute().value
        return rows.first.map {
            FestConfig(name: $0.name, tagline: $0.tagline, startDate: $0.startDate, endDate: $0.endDate)
        }
    }

    private func fetchDues() async throws -> [FestDuesTier] {
        let rows: [DuesRow] = try await supabase
            .from("fest_dues").select("*").eq("fest_year", value: year)
            .order("position", ascending: true)
            .execute().value
        return rows.map { FestDuesTier(id: $0.id, label: $0.label, amount: $0.amount, note: $0.note) }
    }

    private func fetchSchedule() async throws -> [ScheduleItem] {
        let rows: [ScheduleRow] = try await supabase
            .from("fest_schedule_items").select("*").eq("fest_year", value: year)
            .order("day", ascending: true).order("position", ascending: true)
            .execute().value
        return rows.map { r in
            ScheduleItem(
                id: r.id.uuidString,
                day: Self.weekday(from: r.day) ?? r.day,
                time: r.startTime?.nilIfBlank ?? "TBD",
                title: Self.titled(emoji: r.emoji, title: r.title),
                location: r.location?.nilIfBlank ?? "TBD",
                description: r.description,
                isPrivate: r.isPrivate,
                leads: [r.leadName].compactMap { $0?.nilIfBlank }
            )
        }
    }

    private func fetchActivities() async throws -> [ScheduleItem] {
        let rows: [ActivityRow] = try await supabase
            .from("fest_activities").select("*").eq("fest_year", value: year)
            .order("position", ascending: true)
            .execute().value
        return rows.map { r in
            // Anytime activities render via the existing "Anytime" schedule slot.
            let detail = [r.blurb, r.details].compactMap { $0?.nilIfBlank }.joined(separator: " ")
            return ScheduleItem(
                id: r.id.uuidString,
                day: "Anytime",
                time: "Any time",
                title: Self.titled(emoji: r.emoji, title: r.title),
                location: r.location,
                description: detail.isEmpty ? nil : detail,
                isPrivate: false,
                leads: []
            )
        }
    }

    private func fetchDinners() async throws -> [FestDinner] {
        let rows: [DinnerRow] = try await supabase
            .from("fest_dinners").select("*").eq("fest_year", value: year)
            .order("day", ascending: true).order("position", ascending: true)
            .execute().value
        return rows.map { r in
            FestDinner(
                id: r.id.uuidString,
                day: Self.weekday(from: r.day) ?? r.day,
                title: r.title,
                chef: r.chefName?.nilIfBlank ?? "TBD",
                menu: r.menu?.nilIfBlank ?? "TBD",
                location: r.servedLocation?.nilIfBlank,
                time: r.servedTime?.nilIfBlank ?? "TBD",
                crew: r.houses ?? []
            )
        }
    }

    private func fetchPayees() async throws -> [Payee] {
        let rows: [PayeeRow] = try await supabase
            .from("fest_payees").select("*").eq("fest_year", value: year)
            .order("position", ascending: true)
            .execute().value
        return rows.map {
            Payee(id: $0.id, name: $0.name, role: $0.role, venmo: $0.venmo, zelle: $0.zelle,
                  appleCash: $0.applecash, paypal: $0.paypal, amount: $0.amount, note: $0.note)
        }
    }

    // MARK: - Helpers

    /// Prefix the emoji onto the title (the views render a single title string).
    private static func titled(emoji: String?, title: String) -> String {
        guard let e = emoji?.nilIfBlank else { return title }
        return "\(e) \(title)"
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f
    }()

    /// "Monday" for a yyyy-MM-dd date string.
    private static func weekday(from day: String) -> String? {
        guard let date = isoDay.date(from: day) else { return nil }
        let out = DateFormatter()
        out.dateFormat = "EEEE"
        out.locale = Locale(identifier: "en_US_POSIX")
        return out.string(from: date)
    }
}

// MARK: - Row decoders

private struct ConfigRow: Decodable {
    let name: String
    let tagline: String?
    let startDate: String
    let endDate: String
    enum CodingKeys: String, CodingKey {
        case name, tagline
        case startDate = "start_date"
        case endDate = "end_date"
    }
}

private struct DuesRow: Decodable {
    let id: UUID
    let label: String
    let amount: Int?
    let note: String?
}

private struct ScheduleRow: Decodable {
    let id: UUID
    let day: String
    let startTime: String?
    let title: String
    let emoji: String?
    let location: String?
    let description: String?
    let isPrivate: Bool
    let leadName: String?
    enum CodingKeys: String, CodingKey {
        case id, day, title, emoji, location, description
        case startTime = "start_time"
        case isPrivate = "is_private"
        case leadName = "lead_name"
    }
}

private struct ActivityRow: Decodable {
    let id: UUID
    let title: String
    let emoji: String?
    let blurb: String?
    let details: String?
    let location: String?
}

private struct DinnerRow: Decodable {
    let id: UUID
    let day: String
    let title: String
    let chefName: String?
    let menu: String?
    let servedTime: String?
    let servedLocation: String?
    let houses: [String]?
    enum CodingKeys: String, CodingKey {
        case id, day, title, menu, houses
        case chefName = "chef_name"
        case servedTime = "served_time"
        case servedLocation = "served_location"
    }
}

private struct PayeeRow: Decodable {
    let id: UUID
    let name: String
    let role: String?
    let venmo: String?
    let zelle: String?
    let applecash: String?
    let paypal: String?
    let amount: Int?
    let note: String?
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
