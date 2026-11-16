import Foundation
import Supabase

// MARK: - EventsService

@Observable
@MainActor
final class EventsService {
    /// Merged seed + DB events, sorted by startDate ascending.
    var events: [ResortEvent] = []

    /// Current user's RSVP per eventId.
    var attendances: [String: EventAttendance] = [:]

    /// Attendance summary (going/maybe/notGoing counts) per eventId.
    var summaries: [String: AttendanceSummary] = [:]

    var isLoading: Bool = false
    var error: String? = nil

    private var realtimeChannel: RealtimeChannelV2? = nil
    private var eventsFreshness = FreshnessWindow()

    /// Calendar events are family-wide (identical for every viewer), so their
    /// snapshot uses the shared "guest" key; attendance is keyed per user.
    private static let eventsCacheKey = DiskCache.key("events", user: nil)

    // MARK: - Computed

    /// All events starting today or later, sorted ascending.
    var upcomingEvents: [ResortEvent] {
        let today = Calendar.current.startOfDay(for: .now)
        return events
            .filter { event in
                guard let start = event.startDateParsed else { return false }
                let endDay = event.endDateParsed ?? start
                return endDay >= today
            }
            .sorted { a, b in
                (a.startDateParsed ?? .distantFuture) < (b.startDateParsed ?? .distantFuture)
            }
    }

    /// The nearest upcoming non-Family-Fest event.
    /// Returns nil when the fest takeover is active (callers check FestSeason themselves).
    var nearestEvent: ResortEvent? {
        upcomingEvents.first { !$0.isFamilyFest }
    }

    // MARK: - Fetch events

    /// `ifStale: true` skips the network when events were fetched in the last 30s
    /// (tab re-appearance); realtime, pull-to-refresh and mutations pass the default.
    func fetchEvents(ifStale: Bool = false) async {
        if events.isEmpty,
           let cached = DiskCache.load([ResortEvent].self, key: Self.eventsCacheKey), !cached.isEmpty {
            events = cached
        }
        if ifStale && eventsFreshness.isFresh() { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let dbEvents: [ResortEvent] = try await supabase
                .from("events")
                .select("*")
                .execute()
                .value

            // Merge: DB rows take precedence over seed rows with the same id.
            // Family Fest is always synthesized from FamilyFestConfig, never from DB.
            var merged: [String: ResortEvent] = [:]
            for event in ResortEvent.seedEvents {
                merged[event.id] = event
            }
            for event in dbEvents where !event.isFamilyFest {
                merged[event.id] = event
            }

            // Always include the synthesized Family Fest event
            let fest = synthesizeFamilyFest()
            merged[fest.id] = fest

            let sorted = Array(merged.values).sorted {
                ($0.startDateParsed ?? .distantFuture) < ($1.startDateParsed ?? .distantFuture)
            }
            applyRefreshed { events = sorted }
            eventsFreshness.touch()
            DiskCache.save(sorted, key: Self.eventsCacheKey)
        } catch {
            self.error = "Couldn't load events."
            print("[EventsService] fetchEvents error: \(error)")
            // Fall back to seed data so the UI isn't empty (keep a cached list if we have one)
            if events.isEmpty { events = ResortEvent.seedEvents }
        }
    }

    // MARK: - Attendance

    func fetchAttendance(userId: UUID) async {
        let cacheKey = DiskCache.key("event-attendance", user: userId)
        if attendances.isEmpty, let cached = DiskCache.load([EventAttendance].self, key: cacheKey) {
            attendances = Dictionary(cached.map { ($0.eventId, $0) }, uniquingKeysWith: { $1 })
        }
        do {
            let rows: [EventAttendance] = try await supabase
                .from("event_attendance")
                .select("*")
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value
            var map: [String: EventAttendance] = [:]
            for row in rows { map[row.eventId] = row }
            applyRefreshed { attendances = map }
            DiskCache.save(rows, key: cacheKey)
        } catch {
            print("[EventsService] fetchAttendance error: \(error)")
        }
    }

    func fetchSummary(eventId: String) async -> AttendanceSummary {
        struct StatusRow: Decodable { let status: AttendanceStatus }
        do {
            // Count client-side: PostgREST aggregate functions (`.count()`) are
            // disabled on this backend, so fetch the status rows and tally them.
            let rows: [StatusRow] = try await supabase
                .from("event_attendance")
                .select("status")
                .eq("event_id", value: eventId)
                .execute()
                .value
            var going = 0, maybe = 0, notGoing = 0
            for row in rows {
                switch row.status {
                case .going:    going    += 1
                case .maybe:    maybe    += 1
                case .notGoing: notGoing += 1
                }
            }
            let summary = AttendanceSummary(going: going, maybe: maybe, notGoing: notGoing)
            summaries[eventId] = summary
            return summary
        } catch {
            print("[EventsService] fetchSummary error: \(error)")
            return summaries[eventId] ?? AttendanceSummary(going: 0, maybe: 0, notGoing: 0)
        }
    }

    func upsertAttendance(eventId: String, status: AttendanceStatus, days: [String: AttendanceStatus]? = nil) async throws {
        struct UpsertParams: Encodable {
            let p_event: String
            let p_status: String
            let p_days: [String: String]?
        }
        let daysRaw = days.map { dict in dict.mapValues(\.rawValue) }
        try await supabase
            .rpc("set_event_attendance", params: UpsertParams(
                p_event: eventId,
                p_status: status.rawValue,
                p_days: daysRaw
            ))
            .execute()

        // Optimistic local update — also create a row on first RSVP (so e.g.
        // declining immediately hides the event from the Home spotlight).
        let uid: UUID?
        if let existing = attendances[eventId]?.userId {
            uid = existing
        } else {
            uid = try? await supabase.auth.session.user.id
        }
        if let uid {
            attendances[eventId] = EventAttendance(
                eventId: eventId,
                userId: uid,
                status: status,
                days: days,
                updatedAt: .now
            )
        }
    }

    // MARK: - Who is going

    /// ⚠️ event_attendance has THREE FKs to profiles (user_id, sponsor_user_id,
    /// added_by) — every embed names its FK or PostgREST returns PGRST201.
    /// Roster people (`roster_id`) and outside guests (`guest_name` +
    /// `sponsor_user_id`) have no profile, so they resolve from the extra embeds.
    private static let attendeeSelect = """
        id, user_id, roster_id, guest_name, sponsor_user_id, status, days, confirmed,
        profiles!event_attendance_user_id_fkey(id, display_name, contact_email, avatar_url, phone, is_admin,
                         beta_tester, willing_to_help, intro_seen,
                         email_alerts, push_level, push_types,
                         notif_types, push_prompted, created_at),
        family_roster(name),
        sponsor:profiles!event_attendance_sponsor_user_id_fkey(display_name)
        """

    private func fetchAttendanceRows(eventId: String) async throws -> [AttendanceWithProfile] {
        try await supabase
            .from("event_attendance")
            .select(Self.attendeeSelect)
            .eq("event_id", value: eventId)
            .in("status", values: ["going", "maybe"])
            .execute()
            .value
    }

    func fetchWhoIsGoing(eventId: String) async throws -> [EventAttendee] {
        try await fetchAttendanceRows(eventId: eventId).map { $0.asAttendee }
    }

    /// Per-day roster for day-RSVP events: every going/maybe row incl. roster
    /// people and guests, keyed on the attendance row id.
    func fetchDayRoster(eventId: String) async -> [DayRosterEntry] {
        do {
            return try await fetchAttendanceRows(eventId: eventId).map {
                DayRosterEntry(id: $0.id, name: $0.asAttendee.name, status: $0.status, days: $0.days)
            }
        } catch {
            print("[EventsService] fetchDayRoster error: \(error)")
            return []
        }
    }

    /// Remove one attendance row (migration 0196): a manager may remove any row;
    /// a member only their own. Same RPC the web uses.
    func removeAttendanceEntry(id: UUID) async throws {
        struct P: Encodable { let p_id: String }
        try await supabase.rpc("remove_event_attendance_entry", params: P(p_id: id.uuidString)).execute()
    }

    /// Clear the VIEWER'S OWN RSVP (`clear_event_attendance` is self-only on the
    /// server: event + auth.uid()). Managers use `removeAttendanceEntry`.
    func clearMyAttendance(eventId: String) async throws {
        struct P: Encodable { let p_event: String }
        try await supabase.rpc("clear_event_attendance", params: P(p_event: eventId)).execute()
        attendances[eventId] = nil
    }

    /// Attendees (going/maybe) of an event, each with their per-day RSVP — used
    /// by the Family Fest "Crew" tab to show who's coming and which days.
    func fetchAttendeesWithDays(eventId: String) async -> [FestAttendee] {
        do {
            // Same rows as the "who is going" count: members, roster people and
            // outside guests (the latter two have no profile).
            return try await fetchAttendanceRows(eventId: eventId).map { row in
                let a = row.asAttendee
                return FestAttendee(id: row.id, profile: row.profile, name: a.name, note: a.note,
                                    status: row.status, days: row.days)
            }
        } catch {
            print("[EventsService] fetchAttendeesWithDays error: \(error)")
            return []
        }
    }

    // MARK: - Admin: create / update / delete

    /// Create an event; returns the new event's id (so callers can link work items).
    @discardableResult
    func createEvent(
        title: String,
        description: String?,
        kind: EventKind,
        startDate: String,
        endDate: String?,
        location: String?,
        dayRsvp: Bool,
        emoji: String? = nil,
        startTime: String? = nil
    ) async throws -> String {
        struct CreateParams: Encodable {
            let p_title: String
            let p_start_date: String
            let p_end_date: String?
            let p_kind: String
            let p_emoji: String?
            let p_location: String?
            let p_description: String?
            let p_day_rsvp: Bool
            let p_start_time: String?
        }
        let newId: UUID = try await supabase
            .rpc("create_event", params: CreateParams(
                p_title: title,
                p_start_date: startDate,
                p_end_date: endDate,
                p_kind: kind.rawValue,
                p_emoji: emoji,
                p_location: location,
                p_description: description,
                p_day_rsvp: dayRsvp,
                p_start_time: startTime
            ))
            .execute()
            .value
        await fetchEvents()
        return newId.uuidString
    }

    func updateEvent(
        id: String,
        title: String,
        description: String?,
        kind: EventKind,
        startDate: String,
        endDate: String?,
        location: String?,
        dayRsvp: Bool,
        emoji: String? = nil,
        startTime: String? = nil
    ) async throws {
        // Use the SECURITY DEFINER RPC (matches web) instead of a direct table
        // write, so authorization + notification triggers run server-side.
        struct UpdateParams: Encodable {
            let p_id: String
            let p_title: String
            let p_start_date: String
            let p_end_date: String?
            let p_kind: String
            let p_emoji: String?
            let p_location: String?
            let p_description: String?
            let p_day_rsvp: Bool
            let p_start_time: String?
        }
        try await supabase
            .rpc("update_event", params: UpdateParams(
                p_id: id,
                p_title: title,
                p_start_date: startDate,
                p_end_date: endDate,
                p_kind: kind.rawValue,
                p_emoji: emoji,
                p_location: location,
                p_description: description,
                p_day_rsvp: dayRsvp,
                p_start_time: startTime
            ))
            .execute()
        await fetchEvents()
    }

    func deleteEvent(id: String) async throws {
        struct DeleteParams: Encodable { let p_id: String }
        try await supabase
            .rpc("delete_event", params: DeleteParams(p_id: id))
            .execute()
        events.removeAll { $0.id == id }
        summaries.removeValue(forKey: id)
    }

    // MARK: - Realtime

    /// Live-update events + this user's RSVPs when the calendar or attendance
    /// changes anywhere — matching the web app's `events-live` channel.
    func subscribeToRealtime(userId: UUID?) {
        guard realtimeChannel == nil else { return }
        let channel = supabase.channel("events-live")
        realtimeChannel = channel

        Task {
            for table in ["events", "event_attendance"] {
                channel.onPostgresChange(AnyAction.self, schema: "public", table: table) { [weak self] _ in
                    guard let self else { return }
                    Task { @MainActor in
                        await self.fetchEvents()
                        if let userId { await self.fetchAttendance(userId: userId) }
                    }
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

    // MARK: - Helpers

    private func synthesizeFamilyFest() -> ResortEvent {
        ResortEvent(
            id: FamilyFestConfig.id,
            title: "Family Fest \(FamilyFestConfig.year)",
            description: "The annual Theis Family gathering at Muskellunge Lake Resort.",
            kind: .familyFest,
            startDate: FamilyFestConfig.startDate,
            endDate: FamilyFestConfig.endDate,
            location: "Muskellunge Lake Resort",
            dayRsvp: true,
            source: .seed
        )
    }
}

// MARK: - Attendance row with embedded profile

private struct AttendanceWithProfile: Decodable {
    let id: UUID
    let userId: UUID?
    let rosterId: UUID?
    let guestName: String?
    let status: AttendanceStatus
    let days: [String: AttendanceStatus]?
    let confirmed: Bool?
    let profile: Profile?
    let roster: RosterName?
    let sponsor: RosterName?

    struct RosterName: Decodable {
        let name: String?
        let displayName: String?
        enum CodingKeys: String, CodingKey { case name; case displayName = "display_name" }
    }

    enum CodingKeys: String, CodingKey {
        case id, status, days, confirmed
        case userId = "user_id"
        case rosterId = "roster_id"
        case guestName = "guest_name"
        case profile = "profiles"
        case roster = "family_roster"
        case sponsor
    }

    /// Same precedence as web's lib/events.ts: profile, roster, then guest.
    var asAttendee: EventAttendee {
        func clean(_ s: String?) -> String? {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty ?? true) ? nil : t
        }
        var name = clean(profile?.name) ?? clean(roster?.name) ?? clean(guestName) ?? "Someone"
        var note: String?
        if profile == nil, roster == nil, guestName != nil {
            note = "Guest of \(clean(sponsor?.displayName) ?? "a member")"
            name = clean(guestName) ?? name
        }
        return EventAttendee(id: id, userId: userId, profile: profile, name: name,
                             note: note, confirmed: confirmed ?? true)
    }
}

/// One event's attendee: a member (has `profile`), a roster person, or an outside
/// guest (`note` = "Guest of …"). Keyed on the attendance row id.
struct EventAttendee: Identifiable {
    let id: UUID
    let userId: UUID?
    let profile: Profile?
    let name: String
    let note: String?
    let confirmed: Bool
}

struct DayRosterEntry: Identifiable {
    let id: UUID
    let name: String
    let status: AttendanceStatus
    let days: [String: AttendanceStatus]?

    func goingDays(allDays: [String]) -> Set<String> {
        if let days, !days.isEmpty { return Set(days.filter { $0.value == .going }.keys) }
        return status == .going ? Set(allDays) : []
    }
}

// MARK: - FestAttendee
// A member coming to the Family Fest event, with their per-day RSVP (days are
// keyed by weekday name, e.g. "Monday"). Used by the Crew tab.

struct FestAttendee: Identifiable {
    /// Attendance row id (roster people and guests have no profile).
    let id: UUID
    let profile: Profile?
    let name: String
    /// "Guest of {sponsor}" for outside guests.
    let note: String?
    let status: AttendanceStatus
    let days: [String: AttendanceStatus]?

    /// Weekday names the member is "going" on. Empty set + overall going means
    /// they're in for the whole week (no per-day picks).
    func goingDays(allDays: [String]) -> Set<String> {
        if let days, !days.isEmpty {
            let picked = Set(days.filter { $0.value == .going }.keys)
            return picked
        }
        return status == .going ? Set(allDays) : []
    }

    var isWholeWeek: Bool { (days?.isEmpty ?? true) && status == .going }
}
