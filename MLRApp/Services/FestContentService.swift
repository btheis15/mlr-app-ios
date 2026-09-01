import Foundation
import Supabase

// MARK: - Fest content models (DB-backed)

struct FestConfig: Equatable, Identifiable {
    var year: Int
    var name: String
    var tagline: String?
    var startDate: String   // yyyy-MM-dd
    var endDate: String     // yyyy-MM-dd
    /// This year's theme line, e.g. "Ye Olde Family Feste" (migration 0219).
    /// Nil means "use the built-in look" — never backfilled with the 2026 values.
    var theme: String?
    var coverUrl: String?

    var id: Int { year }

    var season: FestSeason { FestSeason.compute(startISO: startDate, endISO: endDate) }
    var dateRangeLabel: String { FamilyFestConfig.rangeLabel(start: startDate, end: endDate) }
}

/// A refusal the "start next year" sheet shows verbatim. These are answers to
/// the person, not diagnostics — "Family Fest 2027 already exists" tells them
/// what to do next; "insert failed" doesn't.
enum FestYearError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
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
    /// Migration 0139 — "Anytime all week" instead of a set day. `day` is
    /// still stored/sent even when true (mirrors web); it's just ignored for
    /// display and grouping.
    var anytime: Bool = false
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
    /// Migration 0147 — gates the "🏆 Tournament" section on this activity.
    var tournamentEnabled: Bool = false
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
    /// Linked Family Fest schedule item (migration 0137) — the card borrows its
    /// photo/details, and shows a "📝 Sign up" button when it takes sign-ups.
    var signupItemId: String? = nil
    /// Linked resort event (migration 0096) — pairs with `excludeNotAttending`
    /// to hide the card from anyone who explicitly RSVP'd "Can't make it".
    var eventId: String? = nil
    var excludeNotAttending: Bool = false
    /// Linked Drop Box folder (migration 0172) — shows a "📸 Add & see photos"
    /// button deep-linking straight into that shared album.
    var dropBoxId: String? = nil

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

    /// The fest year every other table filters on.
    ///
    /// ⚠️ NOT a constant. `fest_config`'s primary key is `fest_year` and there can
    /// be many rows; the current fest is the NEWEST one. A hardcoded 2026 here is
    /// what would keep the app serving a finished fest's schedule, dues and
    /// dinners after the family seeded the next year.
    private(set) var year = FamilyFestConfig.year

    /// Every fest year on record, newest first — the Past Years archive reads this.
    var allYears: [FestConfig] = []

    func load(force: Bool = false) async {
        if loaded && !force { return }
        do {
            // Resolve the year BEFORE anything that filters on it. This is one
            // extra round-trip on a tiny table, and it's the difference between
            // the whole hub showing the right fest and it showing last year's.
            await resolveYear()

            async let cfg = fetchConfig()
            async let sched = fetchSchedule()
            async let dins = fetchDinners()
            async let pays = fetchPayees()
            async let duesTiers = fetchDues()
            async let co = fetchCallouts()

            let (c, s, d, p, du, calloutRows) = try await (cfg, sched, dins, pays, duesTiers, co)

            if let c { config = c }
            // Migration 0141 merged the old fest_activities into fest_schedule_items
            // as anytime events, so the schedule is now the single source. iOS
            // dropped its own fest_activities read entirely (the dead
            // fetchActivities()/ActivityRow/FestActivityEditSheet trio this used
            // to feed were removed) rather than double-counting the copies.
            let combined = s

            // ⚠️ The in-code seed is NOT generic filler — it IS the 2026 week,
            // with 2026's dates, 2026's dues and 2026's payee. Backfilling any
            // other year from it presents last year's plan as that year's own:
            // Family Fest 2027 rendered "Gene Pool Concert" under day cards
            // reading July 26–30 for a fest running August 1–7, and naming last
            // year's collector as the person to send money to. Deleting them in
            // the Planner didn't help, because they were never rows.
            //
            // So the seed only stands in for the ONE year it honestly describes.
            // Every other year degrades to empty, and the empty states say "the
            // week isn't planned yet" rather than inventing a week.
            let seedApplies = year == FamilyFestConfig.fallbackYear

            schedule = combined.isEmpty ? (seedApplies ? ScheduleItem.seed : []) : combined
            dinners  = d.isEmpty        ? (seedApplies ? FestDinner.seed : []) : d
            payees   = p.isEmpty        ? (seedApplies ? Self.seedPayees : []) : p
            dues     = du.isEmpty       ? (seedApplies ? Self.seedDues : []) : du

            // calloutRows nil means the table doesn't exist yet → show seed fallback.
            // Empty array means "no callouts" — don't show the seed.
            callouts = calloutRows ?? [seedCallout]
            usingSeedFallback = combined.isEmpty && seedApplies
            loaded = true
        } catch {
            usingSeedFallback = true
            print("[FestContentService] load error (using seed fallback): \(error)")
        }
    }

    // MARK: - Fetches

    /// Reads every `fest_config` row, newest first, and adopts the newest as the
    /// current fest — then publishes its window into the App Group so the Siri
    /// intents and widgets (separate processes that can't await a fetch) stop
    /// working from the compiled-in fallback.
    ///
    /// Silently keeps the previous `year` on failure: an offline launch should
    /// show last-known content, not collapse to a hardcoded year.
    private func resolveYear() async {
        let rows: [ConfigRow]? = try? await supabase
            .from("fest_config").select("*")
            .order("fest_year", ascending: false)
            .execute().value
        guard let rows, !rows.isEmpty else { return }

        allYears = rows.map(\.config)
        guard let current = allYears.first else { return }
        year = current.year

        let snapshot = FestWindowSnapshot(
            year: current.year,
            startDate: current.startDate,
            endDate: current.endDate,
            name: current.name,
            tagline: current.tagline,
            theme: current.theme,
            coverUrl: current.coverUrl
        )
        // Only write and kick the widgets when something actually CHANGED.
        // `load()` runs on most fest screens, and reloading every timeline on
        // each one burns the widget refresh budget for a value that changes
        // about once a year.
        let previous = SharedStore.shared.festWindow
        guard previous?.year != snapshot.year
                || previous?.startDate != snapshot.startDate
                || previous?.endDate != snapshot.endDate
                || previous?.theme != snapshot.theme
                || previous?.coverUrl != snapshot.coverUrl
        else { return }

        SharedStore.shared.festWindow = snapshot
        SharedStore.shared.reloadWidgets()
    }

    private func fetchConfig() async throws -> FestConfig? {
        // `resolveYear()` already read every row this load; reuse it rather than
        // asking again and risking the two disagreeing.
        if let cached = allYears.first(where: { $0.year == year }) { return cached }
        let rows: [ConfigRow] = try await supabase
            .from("fest_config").select("*").eq("fest_year", value: year)
            .execute().value
        return rows.first?.config
    }

    /// Finished fests, newest first — more than 14 days past their end date, the
    /// same threshold as `FestPhase.concluded`, so the hub saying "that's a wrap"
    /// and the year appearing in the archive flip on the same day.
    ///
    /// Derived from DATES, not an `is_archived` flag. A flag would be a second
    /// source of truth someone has to remember to flip, and forgetting is exactly
    /// how the app ended up advertising a finished fest as live.
    var pastYears: [FestConfig] {
        allYears.filter { FestSeason.isPast(endISO: $0.endDate) }
    }

    struct ArchivedYear {
        var schedule: [ScheduleItem]
        var dinners: [FestDinner]
        var isEmpty: Bool { schedule.isEmpty && dinners.isEmpty }
    }

    /// One archived year's week, read-only.
    ///
    /// ⚠️ NO SEED FALLBACK. The live hub backfills an empty table with in-code
    /// seed data so it's never blank — an archive doing that would FABRICATE
    /// HISTORY, presenting the 2026 week as some other year's record. An archive
    /// with nothing saved has to say nothing was saved.
    func fetchArchivedYear(_ year: Int) async -> ArchivedYear {
        async let sched = try? fetchSchedule(year: year)
        async let dins = try? fetchDinners(year: year)
        return await ArchivedYear(schedule: sched ?? [], dinners: dins ?? [])
    }

    /// The well-known Drop Box id for a fest year's photo album. The year is a
    /// live segment of the uuid, so an unseeded year simply degrades to "folder
    /// isn't available" — linking one early is harmless.
    static func albumId(for year: Int) -> String {
        "0000fe57-\(year)-4000-8000-000000000001"
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
                    isActive: row.isActive ?? true,
                    signupItemId: row.signupItemId?.uuidString,
                    eventId: row.eventId,
                    excludeNotAttending: row.excludeNotAttending ?? false,
                    dropBoxId: row.dropBoxId?.uuidString
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
    /// `useLocal` folds in this device's own local completion snapshot — correct
    /// for the signed-in user, but must be OFF when previewing another member
    /// (their completions come only from the DB, not the admin's local cache).
    func fetchMyCalloutCompletions(userId: UUID, useLocal: Bool = true) async {
        struct CompletionRow: Decodable {
            let calloutId: String
            enum CodingKeys: String, CodingKey { case calloutId = "callout_id" }
        }
        let local = useLocal ? Self.localCompletions() : []
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
            "fest_year": .integer(year), "day": .string(d.day), "anytime": .bool(d.anytime), "title": .string(d.title),
            "start_time": j(d.startTime), "end_time": j(d.endTime), "emoji": j(d.emoji),
            "location": j(d.location), "description": j(d.description), "bring": j(d.bring),
            "is_private": .bool(d.isPrivate), "lead_name": j(d.leadName), "lead_phone": j(d.leadPhone),
            "lead_user_id": d.leadUserId.map { AnyJSON.string($0.uuidString) } ?? .null,
            "position": .integer(d.position), "tournament_enabled": .bool(d.tournamentEnabled),
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
        await resolveYear()
    }

    /// This year's theme line and cover photo (migration 0219).
    /// Nil clears the override and falls back to the built-in look.
    func saveYearLook(theme: String?, coverUrl: String?) async throws {
        var p: [String: AnyJSON] = [
            "fest_year": .integer(year), "theme": j(theme), "cover_url": j(coverUrl),
        ]
        if let uid = await currentUid() { p["updated_by"] = .string(uid) }
        try await supabase.from("fest_config").upsert(p, onConflict: "fest_year").execute()
        await resolveYear()
    }

    // MARK: - Starting the next fest year

    struct StartYearResult { var copied: Int; var warning: String? }

    /// INSERTs a brand-new `fest_config` row.
    ///
    /// ⚠️ INSERT, never an update of the current row. Editing the live row's
    /// dates drags the finished fest forward, so its archive describes a week
    /// that never happened and the app counts down to it all over again.
    ///
    /// ⚠️ Dates are typed in BY HAND and start empty — the fest week is
    /// different every year and the family picks it by poll. Nothing here
    /// defaults or computes them (the web shipped a "+52 weeks" default and it
    /// was wrong). The year is derived from `startDate` so the two can't disagree.
    ///
    /// ⚠️ The new year gets NO theme and NO cover. A null look renders the
    /// built-in parchment, so the year is never ugly while it's being planned —
    /// but the theme is the part of a fest that is *supposed* to change, so
    /// inheriting last year's is the one thing that would be actively wrong.
    @discardableResult
    func startFestYear(
        name: String,
        tagline: String?,
        startDate: String,
        endDate: String,
        copyFromYear: Int?
    ) async throws -> StartYearResult {
        guard let start = festISOFormatter.date(from: startDate),
              let end = festISOFormatter.date(from: endDate) else {
            throw FestYearError.message("Pick a start and an end date.")
        }
        guard end >= start else {
            throw FestYearError.message("End date must be on or after the start.")
        }
        let newYear = Calendar.current.component(.year, from: start)

        // Refuse to overwrite a year that already exists — this button's whole
        // job is to ADD a fest, and an upsert here would silently rewrite a real
        // one.
        await resolveYear()
        if allYears.contains(where: { $0.year == newYear }) {
            throw FestYearError.message("Family Fest \(newYear) already exists.")
        }

        var p: [String: AnyJSON] = [
            "fest_year": .integer(newYear), "name": .string(name), "tagline": j(tagline),
            "start_date": .string(startDate), "end_date": .string(endDate),
            "theme": .null, "cover_url": .null,
        ]
        if let uid = await currentUid() { p["updated_by"] = .string(uid) }
        try await supabase.from("fest_config").insert(p).execute()

        // From here the year EXISTS — the important part succeeded. A copy
        // failure is reported but never rolls the year back: an empty new fest
        // is a fine place to start, and undoing the row would leave the editor
        // with nothing.
        await resolveYear()
        await load(force: true)

        guard let from = copyFromYear else { return StartYearResult(copied: 0, warning: nil) }
        return await copyYear(from: from, to: newYear, newStart: startDate, newEnd: endDate)
    }

    /// Copies last year's plan forward, shifting every day by the gap between
    /// the two START dates so a week moved to a different part of the summer
    /// carries its shape with it.
    private func copyYear(from: Int, to newYear: Int,
                          newStart: String, newEnd: String) async -> StartYearResult {
        let stampUid = await currentUid()
        let sourceStart = allYears.first(where: { $0.year == from })?.startDate
        let shift = sourceStart.flatMap { Self.daysBetween($0, newStart) } ?? 0

        // ⚠️ Read errors are checked, not just writes. A failed select returns
        // no rows, which is indistinguishable from "nothing to copy" — so a
        // table that silently didn't copy would still report success, just with
        // a smaller count. A copy that half-happened has to say so.
        var copied = 0
        var warnings: [String] = []

        for spec in Self.copySpecs {
            let rows: [[String: AnyJSON]]
            do {
                rows = try await supabase.from(spec.table).select(spec.columns)
                    .eq("fest_year", value: from)
                    .order("position", ascending: true)
                    .execute().value
            } catch {
                warnings.append("\(spec.label) couldn't be read from \(from)")
                continue
            }
            if rows.isEmpty { continue }

            let payload: [[String: AnyJSON]] = rows.map { row in
                var r = row
                r["fest_year"] = .integer(newYear)
                if spec.shiftsDay, case let .string(day)? = row["day"] {
                    r["day"] = .string(Self.shiftDay(day, by: shift, clampingTo: newEnd))
                }
                if let stampUid { r["updated_by"] = .string(stampUid) }
                return r
            }
            do {
                try await supabase.from(spec.table).insert(payload).execute()
                copied += payload.count
            } catch {
                warnings.append("copying \(spec.label) failed")
            }
        }

        await load(force: true)
        let warning = warnings.isEmpty
            ? nil
            : "Family Fest \(newYear) was created, but \(warnings.joined(separator: ", "))."
        return StartYearResult(copied: copied, warning: warning)
    }

    private struct CopySpec {
        let table: String, label: String, columns: String, shiftsDay: Bool
    }

    private static let copySpecs: [CopySpec] = [
        CopySpec(table: "fest_schedule_items", label: "the schedule",
                 columns: "day, start_time, end_time, title, emoji, location, description, bring, is_private, anytime, lead_user_id, lead_name, lead_phone, crew_user_ids, position",
                 shiftsDay: true),
        CopySpec(table: "fest_dinners", label: "the dinners",
                 columns: "day, title, emoji, chef_user_id, chef_name, chef_phone, crew_user_ids, houses, menu, served_time, served_location, prep_time, prep_location, position",
                 shiftsDay: true),
        CopySpec(table: "fest_dues", label: "the dues",
                 columns: "label, amount, note, per_day, position", shiftsDay: false),
        CopySpec(table: "fest_payees", label: "the payees",
                 columns: "name, role, venmo, zelle, applecash, paypal, note, position", shiftsDay: false),
    ]

    private static func daysBetween(_ a: String, _ b: String) -> Int? {
        guard let d1 = festISOFormatter.date(from: a),
              let d2 = festISOFormatter.date(from: b) else { return nil }
        return Calendar.current.dateComponents([.day], from: d1, to: d2).day
    }

    /// Shifts a `yyyy-MM-dd` by `shift` days. Anything falling past the new end
    /// (a shorter week) clamps onto the last day rather than landing outside the
    /// fest, where no day card would render it.
    private static func shiftDay(_ day: String, by shift: Int, clampingTo end: String) -> String {
        guard let d = festISOFormatter.date(from: day),
              let moved = Calendar.current.date(byAdding: .day, value: shift, to: d)
        else { return day }
        if let endDate = festISOFormatter.date(from: end), moved > endDate { return end }
        return festISOFormatter.string(from: moved)
    }

    /// Updates a schedule item's location, description, and lead assignment inline
    /// (used by FestScheduleEditSheet; admin / canEditFest / assigned lead only).
    func updateScheduleItem(
        itemId: UUID,
        location: String?,
        description: String?,
        leadName: String?,
        leadUserId: UUID?,
        leadPhone: String?,
        bring: String? = nil,
        links: [ScheduleLink]? = nil,
        signup: SignupConfig? = nil
    ) async throws {
        var payload: [String: AnyJSON] = [
            "location":     j(location),
            "description":  j(description),
            "bring":        j(bring),
            "lead_name":    j(leadName),
            "lead_phone":   j(leadPhone),
            "lead_user_id": leadUserId.map { AnyJSON.string($0.uuidString) } ?? .null,
        ]
        // Ordered link buttons (migration 0142) — only written when provided.
        if let links {
            payload["links"] = .array(links.map { link in
                .object(["href": .string(link.href), "label": link.label.map { AnyJSON.string($0) } ?? .null])
            })
        }
        if let signup {
            payload["signup_enabled"]      = .bool(signup.enabled)
            payload["signup_mode"]         = .string(signup.mode)
            payload["signup_capacity"]     = signup.capacity.map { AnyJSON.double(Double($0)) } ?? .null
            payload["signup_slot_minutes"] = signup.slotMinutes.map { AnyJSON.double(Double($0)) } ?? .null
            payload["signup_start_time"]   = signup.startTime.map { AnyJSON.string($0) } ?? .null
            payload["signup_end_time"]     = signup.endTime.map { AnyJSON.string($0) } ?? .null
            payload["signup_instructions"] = signup.instructions.map { AnyJSON.string($0) } ?? .null
            payload["signup_team_size"]    = signup.teamSize.map { AnyJSON.double(Double($0)) } ?? .null
            payload["signup_hide_names"]   = .bool(signup.hideNames)
        }
        if let uid = await currentUid() { payload["updated_by"] = .string(uid) }
        try await supabase.from("fest_schedule_items").update(payload).eq("id", value: itemId.uuidString).execute()
    }

    /// The admin-editable sign-up config for a schedule event (migrations 0135/0143).
    struct SignupConfig {
        var enabled: Bool
        var mode: String            // interval | slots | headcount
        var capacity: Int?
        var slotMinutes: Int?
        var startTime: String?
        var endTime: String?
        var instructions: String?
        var teamSize: Int?
        var hideNames: Bool = false   // migration 0167 — schedule events only
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
        try await fetchSchedule(year: year)
    }

    private func fetchSchedule(year: Int) async throws -> [ScheduleItem] {
        let rows: [ScheduleRow] = try await supabase
            .from("fest_schedule_items").select("*").eq("fest_year", value: year)
            .order("day", ascending: true).order("position", ascending: true)
            .execute().value
        return rows.map { r in
            ScheduleItem(
                id: r.id.uuidString,
                // Anytime events (migration 0139/0141) group under the "Anytime"
                // bucket, not a weekday — their stored `day` is a placeholder.
                day: r.anytime == true ? "Anytime" : (Self.weekday(from: r.day) ?? r.day),
                isoDate: r.anytime == true ? nil : r.day,
                // An "Anytime all week" event with no set time isn't pending a
                // decision — "No specific time", not "TBD" (web #378). If it takes
                // TIMED sign-ups, the times live in the sign-up card, so point
                // there instead: "Specific time slots" (web #416).
                time: r.startTime?.nilIfBlank ?? (
                    r.anytime == true
                        ? ((r.signupEnabled ?? false) && r.signupMode != "headcount" ? "Specific time slots" : "No specific time")
                        : "TBD"),
                title: Self.titled(emoji: r.emoji, title: r.title),
                location: r.location?.nilIfBlank ?? "TBD",
                description: r.description,
                bring: r.bring?.nilIfBlank,
                isPrivate: r.isPrivate,
                leads: [r.leadName].compactMap { $0?.nilIfBlank },
                leadUserId: r.leadUserId,
                crewUserIds: r.crewUserIds ?? [],
                links: r.links ?? [],
                imageUrl: r.imageUrl?.nilIfBlank,
                signupEnabled: r.signupEnabled ?? false,
                signupMode: r.signupMode,
                signupCapacity: r.signupCapacity,
                signupSlotMinutes: r.signupSlotMinutes,
                signupStartTime: r.signupStartTime,
                signupEndTime: r.signupEndTime,
                signupInstructions: r.signupInstructions,
                signupTeamSize: r.signupTeamSize,
                signupFields: r.signupFields ?? [],
                signupHideNames: r.signupHideNames ?? false,
                tournamentEnabled: r.tournamentEnabled ?? false
            )
        }
    }

    private func fetchDinners() async throws -> [FestDinner] {
        try await fetchDinners(year: year)
    }

    private func fetchDinners(year: Int) async throws -> [FestDinner] {
        let rows: [DinnerRow] = try await supabase
            .from("fest_dinners").select("*").eq("fest_year", value: year)
            .order("day", ascending: true).order("position", ascending: true)
            .execute().value
        let dinners = rows.map { r in
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
        // Sort by calendar weekday order (Sun=0…Sat=6) since DB stores day as
        // weekday name or ISO date — both sort alphabetically, not chronologically.
        let order = ["Sunday":0,"Monday":1,"Tuesday":2,"Wednesday":3,"Thursday":4,"Friday":5,"Saturday":6]
        return dinners.sorted { (order[$0.day] ?? 99) < (order[$1.day] ?? 99) }
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
    let festYear: Int
    let name: String
    let tagline: String?
    let startDate: String
    let endDate: String
    // Migration 0219. Nil means "use the built-in look".
    let theme: String?
    let coverUrl: String?
    enum CodingKeys: String, CodingKey {
        case name, tagline, theme
        case festYear = "fest_year"
        case startDate = "start_date"
        case endDate = "end_date"
        case coverUrl = "cover_url"
    }

    var config: FestConfig {
        FestConfig(year: festYear, name: name, tagline: tagline,
                   startDate: startDate, endDate: endDate,
                   theme: theme, coverUrl: coverUrl)
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
    let crewUserIds: [UUID]?   // migration 0110 — crew can self-edit the event
    let anytime: Bool?         // migration 0139 — "Anytime all week", no set time
    let links: [ScheduleLink]? // migration 0142 — ordered link buttons
    let imageUrl: String?      // optional photo on the event/activity
    let bring: String?         // "what to bring" note
    // Sign-ups (migrations 0135/0136/0143)
    let signupEnabled: Bool?
    let signupMode: String?
    let signupCapacity: Int?
    let signupSlotMinutes: Int?
    let signupStartTime: String?
    let signupEndTime: String?
    let signupInstructions: String?
    let signupTeamSize: Int?
    let signupFields: [SignupField]?
    let signupHideNames: Bool?   // migration 0167
    let tournamentEnabled: Bool? // migration 0147
    enum CodingKeys: String, CodingKey {
        case id, day, title, emoji, location, description, anytime, links, bring
        case imageUrl    = "image_url"
        case startTime   = "start_time"
        case isPrivate   = "is_private"
        case leadName    = "lead_name"
        case leadUserId  = "lead_user_id"
        case crewUserIds = "crew_user_ids"
        case signupEnabled      = "signup_enabled"
        case signupMode         = "signup_mode"
        case signupCapacity     = "signup_capacity"
        case signupSlotMinutes  = "signup_slot_minutes"
        case signupStartTime    = "signup_start_time"
        case signupEndTime      = "signup_end_time"
        case signupInstructions = "signup_instructions"
        case signupTeamSize     = "signup_team_size"
        case signupFields       = "signup_fields"
        case signupHideNames    = "signup_hide_names"
        case tournamentEnabled  = "tournament_enabled"
    }
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
    let signupItemId: UUID?   // migration 0137 — linked fest schedule item
    let eventId: String?      // migration 0096 — event targeting
    let excludeNotAttending: Bool?
    let dropBoxId: UUID?      // migration 0172 — linked Drop Box folder

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
        case signupItemId = "signup_item_id"
        case eventId = "event_id"
        case excludeNotAttending = "exclude_not_attending"
        case dropBoxId = "drop_box_id"
    }
}

// Full rows for the editor (all editable columns).
private struct ScheduleRowFull: Decodable {
    let id: UUID
    let day: String
    let anytime: Bool?         // migration 0139
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
    let tournament_enabled: Bool?   // migration 0147
    var draft: FestScheduleDraft {
        FestScheduleDraft(id: id, day: day, anytime: anytime ?? false, startTime: start_time, endTime: end_time, title: title,
                          emoji: emoji, location: location, description: description, bring: bring,
                          isPrivate: is_private, leadUserId: lead_user_id, leadName: lead_name,
                          leadPhone: lead_phone, position: position, tournamentEnabled: tournament_enabled ?? false)
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
