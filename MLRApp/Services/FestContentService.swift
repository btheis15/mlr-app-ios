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
/// `perDay` tiers are billed × a shared day count in the Pay calculator (#249,
/// migration 0078); flat tiers are a one-time/full-week amount.
struct FestDuesTier: Identifiable, Equatable {
    let id: UUID
    var label: String
    var amount: Int?
    var note: String?
    var perDay: Bool = false
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
    var crewUserIds: [UUID]
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

// MARK: - HomeCallout
// An admin-managed Home call-out card (migration 0083, `home_callouts` table).
// Swipeable cards stacked above FamilyFestSpotlight on the Home screen.
// Mirrors web HomeCallout interface in lib/festContent.ts.
//
// Migration 0093: link_href / link_label columns dropped; replaced by `links`
// JSONB array so a single callout can carry multiple independent action buttons.

struct CalloutLink: Equatable {
    var href: String    // tel:… / mailto:… / https:…
    var label: String?
}

struct HomeCallout: Identifiable, Equatable {
    let id: String
    var title: String?
    var body: String?
    var imageUrl: String?
    var links: [CalloutLink]    // migration 0093 — replaces single linkHref/linkLabel
    var startsOn: String?   // yyyy-MM-dd, nil = show immediately
    var endsOn: String?     // yyyy-MM-dd inclusive, nil = open-ended
    /// Optional due-by timestamp (ISO 8601). Distinct from startsOn/endsOn which
    /// only gate visibility — this is the actual deadline reminders count down to.
    var deadlineAt: String?
    var dismissId: String
    var position: Int
    var isActive: Bool

    /// Whether this callout should be shown today (yyyy-MM-dd string).
    func isLive(today: String) -> Bool {
        guard isActive else { return false }
        if let s = startsOn, today < s { return false }
        if let e = endsOn,   today > e { return false }
        return true
    }
}

/// Seed callout — the t-shirt flyer, identical to the 0083 DB seed row.
/// Used only when the `home_callouts` table doesn't exist yet (pre-migration /
/// no backend). An empty table means "no callouts", not "show the seed".
private let seedCallout = HomeCallout(
    id: "tshirt-order-jul15-2026",
    title: nil,
    body: nil,
    imageUrl: nil,
    links: [CalloutLink(href: "tel:7153653195", label: "📞 Call Tricia at Metro to order")],
    startsOn: nil,
    endsOn: "2026-07-15",
    deadlineAt: nil,
    dismissId: "tshirt-order-jul15-2026",
    position: 0,
    isActive: true
)

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
    /// Admin-managed Home callout cards (migration 0083). Empty until loaded.
    var callouts: [HomeCallout] = []
    /// Callout IDs the signed-in user has permanently marked "done" (migration 0098).
    var completedCalloutIds: Set<String> = []
    var loaded = false
    /// Cached result of `canEditFest()` — readable by expandable rows without an async call.
    var userCanEditFest: Bool = false
    /// True when the DB fetch was empty/unreachable and we're showing the in-code
    /// "TBD" seed instead of live content — surfaced as a subtle overview caption.
    var usingSeedFallback = false

    private var realtimeChannel: RealtimeChannelV2? = nil

    // Offline / pre-migration fallbacks so the Pay tab is never blank.
    static let seedDues: [FestDuesTier] = [
        FestDuesTier(id: UUID(), label: "Adult (high school & up)", amount: nil, note: nil),
        FestDuesTier(id: UUID(), label: "Kid (K–8th grade)", amount: nil, note: nil),
        FestDuesTier(id: UUID(), label: "Per day", amount: nil, note: "per person", perDay: true),
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
            async let co = fetchCallouts()

            let (c, s, d, p, a, du, calloutRows) = try await (cfg, sched, dins, pays, acts, duesTiers, co)

            if let c { config = c }
            if !du.isEmpty { dues = du }
            let combined = s + a
            if !combined.isEmpty { schedule = combined }
            if !d.isEmpty { dinners = d }
            if !p.isEmpty { payees = p }
            // calloutRows nil means the table doesn't exist yet → show seed fallback.
            // Empty array means "no callouts" — don't show the seed.
            callouts = calloutRows ?? [seedCallout]
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
        return rows.map { FestDuesTier(id: $0.id, label: $0.label, amount: $0.amount, note: $0.note, perDay: $0.perDay ?? false) }
    }

    /// Returns nil when the `home_callouts` table doesn't exist yet (pre-migration),
    /// so the caller can fall back to the seed. Returns [] when the table exists but
    /// has no active rows — that means "no callouts", not "show the seed".
    private func fetchCallouts() async throws -> [HomeCallout]? {
        do {
            let rows: [CalloutRow] = try await supabase
                .from("home_callouts")
                .select("*")
                .eq("is_active", value: true)
                .order("position", ascending: true)
                .execute().value
            return rows.map { row in
                HomeCallout(
                    id: row.id.uuidString,
                    title: row.title,
                    body: row.body,
                    imageUrl: row.imageUrl,
                    links: (row.links ?? []).map { CalloutLink(href: $0.href, label: $0.label) },
                    startsOn: row.startsOn,
                    endsOn: row.endsOn,
                    deadlineAt: row.deadlineAt,
                    dismissId: row.dismissId ?? row.id.uuidString,
                    position: row.position ?? 0,
                    isActive: row.isActive ?? true
                )
            }
        } catch {
            // Table doesn't exist yet (pre-migration 0083) → return nil so caller shows seed.
            return nil
        }
    }

    // MARK: - Callout completions (migration 0098)

    /// Fetches the callout IDs the signed-in user has permanently marked "done".
    /// Merges UserDefaults local cache with the DB so completions survive even when
    /// the `home_callout_completions` table isn't deployed or the fetch races sign-in.
    func fetchMyCalloutCompletions(userId: UUID) async {
        struct CompletionRow: Decodable {
            let calloutId: String
            enum CodingKeys: String, CodingKey { case calloutId = "callout_id" }
        }
        let local = Self.localCompletions()
        if !local.isEmpty { completedCalloutIds = local }
        do {
            let rows: [CompletionRow] = try await supabase
                .from("home_callout_completions")
                .select("callout_id")
                .eq("user_id", value: userId.uuidString)
                .execute().value
            completedCalloutIds = local.union(rows.map(\.calloutId))
        } catch {
            // Table may not exist yet — local cache is already applied.
            print("[FestContentService] fetchMyCalloutCompletions error: \(error)")
        }
    }

    /// Permanently marks a callout done for the signed-in user (upserted so double-tap is safe).
    /// Also writes to UserDefaults so the completion survives if the DB write fails.
    func markCalloutDone(calloutId: String, userId: UUID) async {
        var local = Self.localCompletions()
        local.insert(calloutId)
        UserDefaults.standard.set(Array(local), forKey: Self.completionsKey)

        struct Payload: Encodable { let callout_id: String; let user_id: String }
        do {
            try await supabase
                .from("home_callout_completions")
                .upsert(Payload(callout_id: calloutId, user_id: userId.uuidString),
                        onConflict: "callout_id,user_id")
                .execute()
        } catch {
            print("[FestContentService] markCalloutDone error: \(error)")
        }
    }

    private static let completionsKey = "mlr_completed_callout_ids"
    private static func localCompletions() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: completionsKey) ?? [])
    }

    // MARK: - Dinner crew self-edit (migration 0099)

    /// Lets a dinner's chef or an assigned crew member update the operational details
    /// (menu, served time/location, prep time/location). RLS authorises it on the server.
    func updateDinnerDetails(
        dinnerId: String,
        menu: String?,
        servedTime: String?,
        servedLocation: String?,
        prepTime: String?,
        prepLocation: String?
    ) async throws {
        struct Payload: Encodable {
            let menu: String?
            let served_time: String?
            let served_location: String?
            let prep_time: String?
            let prep_location: String?
        }
        try await supabase
            .from("fest_dinners")
            .update(Payload(menu: menu, served_time: servedTime,
                            served_location: servedLocation,
                            prep_time: prepTime, prep_location: prepLocation))
            .eq("id", value: dinnerId)
            .execute()
    }

    // MARK: - Editing (admin / fest committee; RLS enforces can_edit_fest)

    /// True if the signed-in user may edit fest content (server-authoritative).
    /// Result is cached in `userCanEditFest` so expandable rows can read it synchronously.
    func canEditFest() async -> Bool {
        let result: Bool = (try? await supabase.rpc("can_edit_fest").execute().value) ?? false
        userCanEditFest = result
        return result
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
                          "fest_dinners", "fest_payees", "fest_activities", "home_callouts"] {
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
            "crew_user_ids": .array(d.crewUserIds.map { AnyJSON.string($0.uuidString) }),
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
            "per_day": .bool(t.perDay),
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

    /// Updates a schedule item's location, description, and lead assignment inline
    /// (used by FestScheduleEditSheet; admin / canEditFest / assigned lead only).
    func updateScheduleItem(
        itemId: UUID,
        location: String?,
        description: String?,
        leadName: String?,
        leadUserId: UUID?,
        leadPhone: String?
    ) async throws {
        var payload: [String: AnyJSON] = [
            "location":     j(location),
            "description":  j(description),
            "lead_name":    j(leadName),
            "lead_phone":   j(leadPhone),
            "lead_user_id": leadUserId.map { AnyJSON.string($0.uuidString) } ?? .null,
        ]
        if let uid = await currentUid() { payload["updated_by"] = .string(uid) }
        try await supabase.from("fest_schedule_items").update(payload).eq("id", value: itemId.uuidString).execute()
    }

    /// Updates only the crew_user_ids on a dinner (admin / canEditFest / chef only).
    func updateDinnerCrew(dinnerId: UUID, crewUserIds: [UUID]) async throws {
        let payload: [String: AnyJSON] = [
            "crew_user_ids": .array(crewUserIds.map { AnyJSON.string($0.uuidString) })
        ]
        try await supabase.from("fest_dinners").update(payload).eq("id", value: dinnerId.uuidString).execute()
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
                leads: [r.leadName].compactMap { $0?.nilIfBlank },
                leadUserId: r.leadUserId
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
                chefUserId: r.chefUserId,
                crewUserIds: r.crewUserIds ?? [],
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
    let perDay: Bool?
    enum CodingKeys: String, CodingKey {
        case id, label, amount, note
        case perDay = "per_day"
    }
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
    let leadUserId: UUID?
    enum CodingKeys: String, CodingKey {
        case id, day, title, emoji, location, description
        case startTime  = "start_time"
        case isPrivate  = "is_private"
        case leadName   = "lead_name"
        case leadUserId = "lead_user_id"
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
    let chefUserId: UUID?
    let chefName: String?
    let menu: String?
    let servedTime: String?
    let servedLocation: String?
    let crewUserIds: [UUID]?   // migration 0099
    let houses: [String]?
    enum CodingKeys: String, CodingKey {
        case id, day, title, menu, houses
        case chefUserId = "chef_user_id"
        case chefName = "chef_name"
        case servedTime = "served_time"
        case servedLocation = "served_location"
        case crewUserIds = "crew_user_ids"
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

private struct CalloutRow: Decodable {
    let id: UUID
    let title: String?
    let body: String?
    let imageUrl: String?
    let links: [CalloutLinkRow]?   // migration 0093 — jsonb array [{href, label}]
    let startsOn: String?
    let endsOn: String?
    let deadlineAt: String?
    let dismissId: String?
    let position: Int?
    let isActive: Bool?

    struct CalloutLinkRow: Decodable {
        let href: String
        let label: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, links
        case imageUrl  = "image_url"
        case startsOn  = "starts_on"
        case endsOn    = "ends_on"
        case deadlineAt = "deadline_at"
        case dismissId = "dismiss_id"
        case position
        case isActive  = "is_active"
    }
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
    let crew_user_ids: [UUID]?   // migration 0099
    let houses: [String]?
    let menu: String?
    let served_time: String?
    let served_location: String?
    let prep_time: String?
    let prep_location: String?
    let position: Int
    var draft: FestDinnerDraft {
        FestDinnerDraft(id: id, day: day, title: title, emoji: emoji, chefUserId: chef_user_id,
                        chefName: chef_name, chefPhone: chef_phone, crewUserIds: crew_user_ids ?? [],
                        houses: houses ?? [], menu: menu,
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
