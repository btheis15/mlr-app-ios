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

// MARK: - Editable drafts (raw rows for the Planner)
// The display arrays (ScheduleItem/FestDinner) flatten fields; the editor works
// on these raw drafts (id nil = new row).

struct FestScheduleDraft: Identifiable, Equatable {
    var id: UUID?
    var day: String           // yyyy-MM-dd
    var startTime: String?
    var endTime: String?
    var title: String
    var emoji: String?
    var location: String?
    var description: String?
    var bring: String?
    var isPrivate: Bool
    var leadUserId: UUID?
    var leadName: String?
    var leadPhone: String?
    var position: Int
}

struct FestDinnerDraft: Identifiable, Equatable {
    var id: UUID?
    var day: String
    var title: String
    var emoji: String?
    var chefUserId: UUID?
    var chefName: String?
    var chefPhone: String?
    var houses: [String]
    var menu: String?
    var servedTime: String?
    var servedLocation: String?
    var prepTime: String?
    var prepLocation: String?
    var position: Int
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
    /// True when the DB fetch was empty/unreachable and we're showing the in-code
    /// "TBD" seed instead of live content — surfaced as a subtle overview caption.
    var usingSeedFallback = false

    private var realtimeChannel: RealtimeChannelV2? = nil

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
            // If the schedule came back empty, we're still on the TBD seed.
            usingSeedFallback = combined.isEmpty
            loaded = true
        } catch {
            usingSeedFallback = true
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

    // MARK: - Editing (admin / fest committee; RLS enforces can_edit_fest)

    /// True if the signed-in user may edit fest content (server-authoritative).
    func canEditFest() async -> Bool {
        (try? await supabase.rpc("can_edit_fest").execute().value) ?? false
    }

    /// Re-fetch everything after an edit so the display arrays update.
    func reload() async { await load(force: true) }

    // MARK: - Realtime

    /// Live-update Family Fest content (schedule, dinners, payees, dues, config,
    /// activities) when an admin edits it — matching the web `fest-content-live` channel.
    func subscribeToRealtime() {
        guard realtimeChannel == nil else { return }
        let channel = supabase.channel("fest-content-live")
        realtimeChannel = channel

        Task {
            for table in ["fest_config", "fest_dues", "fest_schedule_items",
                          "fest_dinners", "fest_payees", "fest_activities"] {
                channel.onPostgresChange(AnyAction.self, schema: "public", table: table) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in await self.reload() }
                }
            }
            await channel.subscribe()
        }
    }

    func unsubscribeFromRealtime() {
        Task {
            if let channel = realtimeChannel {
                await supabase.removeChannel(channel)
                realtimeChannel = nil
            }
        }
    }

    private func currentUid() async -> String? {
        (try? await supabase.auth.session.user.id)?.uuidString
    }

    private func j(_ s: String?) -> AnyJSON { s?.nilIfBlank.map(AnyJSON.string) ?? .null }
    private func j(_ i: Int?) -> AnyJSON { i.map { AnyJSON.integer($0) } ?? .null }

    // ── Raw fetches for the editor ────────────────────────────────────────────
    func editableSchedule() async -> [FestScheduleDraft] {
        let rows: [ScheduleRowFull] = (try? await supabase.from("fest_schedule_items").select("*")
            .eq("fest_year", value: year).order("day").order("position").execute().value) ?? []
        return rows.map { $0.draft }
    }
    func editableDinners() async -> [FestDinnerDraft] {
        let rows: [DinnerRowFull] = (try? await supabase.from("fest_dinners").select("*")
            .eq("fest_year", value: year).order("day").order("position").execute().value) ?? []
        return rows.map { $0.draft }
    }

    // ── Upserts + deletes ─────────────────────────────────────────────────────
    func saveSchedule(_ d: FestScheduleDraft) async throws {
        var p: [String: AnyJSON] = [
            "fest_year": .integer(year), "day": .string(d.day), "title": .string(d.title),
            "start_time": j(d.startTime), "end_time": j(d.endTime), "emoji": j(d.emoji),
            "location": j(d.location), "description": j(d.description), "bring": j(d.bring),
            "is_private": .bool(d.isPrivate), "lead_name": j(d.leadName), "lead_phone": j(d.leadPhone),
            "lead_user_id": d.leadUserId.map { AnyJSON.string($0.uuidString) } ?? .null,
            "position": .integer(d.position),
        ]
        if let uid = await currentUid() { p["updated_by"] = .string(uid) }
        try await upsert("fest_schedule_items", id: d.id, payload: p)
    }
    func saveDinner(_ d: FestDinnerDraft) async throws {
        var p: [String: AnyJSON] = [
            "fest_year": .integer(year), "day": .string(d.day), "title": .string(d.title),
            "emoji": j(d.emoji), "chef_name": j(d.chefName), "chef_phone": j(d.chefPhone),
            "chef_user_id": d.chefUserId.map { AnyJSON.string($0.uuidString) } ?? .null,
            "houses": .array(d.houses.map(AnyJSON.string)),
            "menu": j(d.menu), "served_time": j(d.servedTime), "served_location": j(d.servedLocation),
            "prep_time": j(d.prepTime), "prep_location": j(d.prepLocation), "position": .integer(d.position),
        ]
        if let uid = await currentUid() { p["updated_by"] = .string(uid) }
        try await upsert("fest_dinners", id: d.id, payload: p)
    }
    func saveDues(_ t: FestDuesTier, position: Int, isNew: Bool) async throws {
        var p: [String: AnyJSON] = [
            "fest_year": .integer(year), "label": .string(t.label),
            "amount": j(t.amount), "note": j(t.note), "position": .integer(position),
        ]
        if let uid = await currentUid() { p["updated_by"] = .string(uid) }
        try await upsert("fest_dues", id: isNew ? nil : t.id, payload: p)
    }
    func savePayee(_ p0: Payee, position: Int, isNew: Bool) async throws {
        var p: [String: AnyJSON] = [
            "fest_year": .integer(year), "name": .string(p0.name), "role": j(p0.role),
            "venmo": j(p0.venmo), "zelle": j(p0.zelle), "applecash": j(p0.appleCash),
            "paypal": j(p0.paypal), "amount": j(p0.amount), "note": j(p0.note), "position": .integer(position),
        ]
        if let uid = await currentUid() { p["updated_by"] = .string(uid) }
        try await upsert("fest_payees", id: isNew ? nil : p0.id, payload: p)
    }
    func saveConfig(name: String, tagline: String?, startDate: String, endDate: String) async throws {
        var p: [String: AnyJSON] = [
            "fest_year": .integer(year), "name": .string(name), "tagline": j(tagline),
            "start_date": .string(startDate), "end_date": .string(endDate),
        ]
        if let uid = await currentUid() { p["updated_by"] = .string(uid) }
        try await supabase.from("fest_config").upsert(p, onConflict: "fest_year").execute()
    }

    func deleteSchedule(id: UUID) async throws { try await delete("fest_schedule_items", id: id) }
    func deleteDinner(id: UUID) async throws { try await delete("fest_dinners", id: id) }
    func deleteDues(id: UUID) async throws { try await delete("fest_dues", id: id) }
    func deletePayee(id: UUID) async throws { try await delete("fest_payees", id: id) }

    private func upsert(_ table: String, id: UUID?, payload: [String: AnyJSON]) async throws {
        var p = payload
        if let id { p["id"] = .string(id.uuidString) }
        try await supabase.from(table).upsert(p, onConflict: "id").execute()
    }
    private func delete(_ table: String, id: UUID) async throws {
        try await supabase.from(table).delete().eq("id", value: id.uuidString).execute()
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
                isoDate: r.day,
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
                isoDate: nil,
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

// Full rows for the editor (all editable columns).
private struct ScheduleRowFull: Decodable {
    let id: UUID
    let day: String
    let start_time: String?
    let end_time: String?
    let title: String
    let emoji: String?
    let location: String?
    let description: String?
    let bring: String?
    let is_private: Bool
    let lead_user_id: UUID?
    let lead_name: String?
    let lead_phone: String?
    let position: Int
    var draft: FestScheduleDraft {
        FestScheduleDraft(id: id, day: day, startTime: start_time, endTime: end_time, title: title,
                          emoji: emoji, location: location, description: description, bring: bring,
                          isPrivate: is_private, leadUserId: lead_user_id, leadName: lead_name,
                          leadPhone: lead_phone, position: position)
    }
}

private struct DinnerRowFull: Decodable {
    let id: UUID
    let day: String
    let title: String
    let emoji: String?
    let chef_user_id: UUID?
    let chef_name: String?
    let chef_phone: String?
    let houses: [String]?
    let menu: String?
    let served_time: String?
    let served_location: String?
    let prep_time: String?
    let prep_location: String?
    let position: Int
    var draft: FestDinnerDraft {
        FestDinnerDraft(id: id, day: day, title: title, emoji: emoji, chefUserId: chef_user_id,
                        chefName: chef_name, chefPhone: chef_phone, houses: houses ?? [], menu: menu,
                        servedTime: served_time, servedLocation: served_location, prepTime: prep_time,
                        prepLocation: prep_location, position: position)
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
