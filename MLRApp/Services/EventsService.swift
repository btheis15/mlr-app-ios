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

    func fetchEvents() async {
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

            events = Array(merged.values).sorted {
                ($0.startDateParsed ?? .distantFuture) < ($1.startDateParsed ?? .distantFuture)
            }
        } catch {
            self.error = "Couldn't load events."
            print("[EventsService] fetchEvents error: \(error)")
            // Fall back to seed data so the UI isn't empty
            events = ResortEvent.seedEvents
        }
    }

    // MARK: - Attendance

    func fetchAttendance(userId: UUID) async {
        do {
            let rows: [EventAttendance] = try await supabase
                .from("event_attendance")
                .select("*")
                .eq("user_id", value: userId.uuidString)
                .execute()
                .value
            var map: [String: EventAttendance] = [:]
            for row in rows { map[row.eventId] = row }
            attendances = map
        } catch {
            print("[EventsService] fetchAttendance error: \(error)")
        }
    }

    func fetchSummary(eventId: String) async -> AttendanceSummary {
        struct SummaryRow: Decodable {
            let status: AttendanceStatus
            let count: Int
        }
        do {
            let rows: [SummaryRow] = try await supabase
                .from("event_attendance")
                .select("status, count:user_id.count()")
                .eq("event_id", value: eventId)
                .execute()
                .value
            var going = 0, maybe = 0, notGoing = 0
            for row in rows {
                switch row.status {
                case .going:    going    += row.count
                case .maybe:    maybe    += row.count
                case .notGoing: notGoing += row.count
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

    func fetchWhoIsGoing(eventId: String) async throws -> [Profile] {
        let rows: [AttendanceWithProfile] = try await supabase
            .from("event_attendance")
            .select("""
                status,
                profiles!user_id(id, display_name, contact_email, avatar_url, phone, is_admin,
                                 beta_tester, willing_to_help, intro_seen,
                                 email_alerts, push_level, push_types,
                                 notif_types, push_prompted, created_at)
            """)
            .eq("event_id", value: eventId)
            .in("status", values: ["going", "maybe"])
            .execute()
            .value
        return rows.compactMap(\.profile)
    }

    /// Attendees (going/maybe) of an event, each with their per-day RSVP — used
    /// by the Family Fest "Crew" tab to show who's coming and which days.
    func fetchAttendeesWithDays(eventId: String) async -> [FestAttendee] {
        do {
            let rows: [AttendeeWithDaysRow] = try await supabase
                .from("event_attendance")
                .select("""
                    status, days,
                    profiles!user_id(id, display_name, contact_email, avatar_url, phone, is_admin,
                                     beta_tester, willing_to_help, intro_seen,
                                     email_alerts, push_level, push_types,
                                     notif_types, push_prompted, created_at)
                """)
                .eq("event_id", value: eventId)
                .in("status", values: ["going", "maybe"])
                .execute()
                .value
            return rows.compactMap { row in
                guard let profile = row.profiles else { return nil }
                return FestAttendee(profile: profile, status: row.status, days: row.days)
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
        emoji: String? = nil
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
                p_day_rsvp: dayRsvp
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
        emoji: String? = nil
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
                p_day_rsvp: dayRsvp
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
    let status: AttendanceStatus
    let profile: Profile?

    enum CodingKeys: String, CodingKey {
        case status
        case profile = "profiles"
    }
}

private struct AttendeeWithDaysRow: Decodable {
    let status: AttendanceStatus
    let days: [String: AttendanceStatus]?
    let profiles: Profile?
}

// MARK: - FestAttendee
// A member coming to the Family Fest event, with their per-day RSVP (days are
// keyed by weekday name, e.g. "Monday"). Used by the Crew tab.

struct FestAttendee: Identifiable {
    let profile: Profile
    let status: AttendanceStatus
    let days: [String: AttendanceStatus]?

    var id: UUID { profile.id }

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
