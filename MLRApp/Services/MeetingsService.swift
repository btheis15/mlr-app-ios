import Foundation
import Supabase

// MARK: - MeetingsService (migrations 0116–0122)
//
// Client helpers for committee/house/family meeting scheduling. Mirrors the web
// app's lib/meetings.ts: reads pull the meetings + slots + availability under
// RLS and compute the per-slot buckets / best slot / the viewer's own answers
// client-side; writes go through SECURITY DEFINER RPCs (p_ param names must
// match the SQL exactly). Everything degrades to safe empties on error.

@Observable
@MainActor
final class MeetingsService {

    /// Live realtime channels keyed by scope.roomKey.
    private var channels: [String: RealtimeChannelV2] = [:]

    /// ISO-8601 (UTC, "Z") — the format Postgres timestamptz accepts, matching
    /// the web's `new Date(...).toISOString()`.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func isoString(_ date: Date) -> String { Self.iso.string(from: date) }

    // MARK: - Read

    /// Every meeting for a room (newest first) with its slots, per-slot
    /// availability buckets, the best slot, and the viewer's own answers — all
    /// computed client-side from one meeting_availability read. `uid` is the
    /// signed-in member (for "mine" / respondent resolution). Empty on any error.
    func fetchMeetings(scope: MeetingScope, uid: UUID?) async -> [Meeting] {
        do {
            var query = supabase
                .from("meetings")
                .select("id, scope_type, committee_slug, area, house_id, title, description, created_by, created_at, respond_by, status, chosen_slot_id, meet_url, created_event_id, meeting_slots(id, starts_at, ends_at, duration_min, position)")

            switch scope {
            case let .committee(_, slug, area):
                query = query.eq("scope_type", value: "committee").eq("committee_slug", value: slug)
                query = area == nil ? query.is("area", value: nil) : query.eq("area", value: area!)
            case let .house(houseId, _):
                query = query.eq("scope_type", value: "house").eq("house_id", value: houseId.uuidString)
            case .family:
                query = query.eq("scope_type", value: "family")
            }

            let rows: [MeetingRow] = try await query
                .order("created_at", ascending: false)
                .execute()
                .value
            if rows.isEmpty { return [] }

            // One availability read for all these meetings.
            let ids = rows.map { $0.id.uuidString }
            let avail: [AvailabilityRow] = (try? await supabase
                .from("meeting_availability")
                .select("meeting_id, slot_id, user_id, status")
                .in("meeting_id", values: ids)
                .execute()
                .value) ?? []

            return rows.map { $0.toMeeting(availability: avail, uid: uid) }
        } catch {
            print("[MeetingsService] fetchMeetings error: \(error)")
            return []
        }
    }

    /// A meeting with the viewer's answers merged in + slot buckets/score/best
    /// recomputed — the optimistic local update the sheet paints before
    /// set_my_availability confirms. Slots omitted keep the viewer's existing answer.
    func applyMyAvailability(_ meeting: Meeting, uid: UUID, answers: [UUID: MeetingAvailability]) -> Meeting {
        var m = meeting
        var myAnswers = meeting.myAnswers
        for (k, v) in answers { myAnswers[k] = v }
        m.myAnswers = myAnswers
        m.slots = meeting.slots.map { slot in
            var s = slot
            s.yes.removeAll { $0 == uid }
            s.ifNeedBe.removeAll { $0 == uid }
            s.no.removeAll { $0 == uid }
            switch myAnswers[s.id] {
            case .yes:      s.yes.append(uid)
            case .ifNeedBe: s.ifNeedBe.append(uid)
            case .no:       s.no.append(uid)
            case nil:       break
            }
            return s
        }
        m.bestSlotId = Self.bestSlotId(m.slots)
        var responders = Set<UUID>()
        for s in m.slots { responders.formUnion(s.yes); responders.formUnion(s.ifNeedBe); responders.formUnion(s.no) }
        m.respondentCount = responders.count
        return m
    }

    /// Can the viewer propose a meeting in this room? Admin (any room) or — for a
    /// committee — a Lead of that committee/area. Asks the server so button
    /// visibility can't drift from the RLS gate. False on any error.
    func canOrganize(scope: MeetingScope) async -> Bool {
        struct Params: Encodable {
            let p_scope: String
            let p_committee_id: String?
            let p_area: String?
            let p_house_id: String?
        }
        do {
            let ok: Bool = try await supabase
                .rpc("can_organize_meeting", params: params(scope))
                .execute()
                .value
            return ok
        } catch {
            return false
        }
    }

    // MARK: - Write

    /// Propose a meeting — admin, or a committee/area Lead. Returns the new id.
    @discardableResult
    func createMeeting(
        scope: MeetingScope,
        title: String,
        description: String?,
        slots: [MeetingSlotInput],
        respondBy: String?,
        emailEveryone: Bool
    ) async throws -> UUID? {
        struct SlotParam: Encodable {
            let starts_at: String
            let duration_min: Int
            let ends_at: String?
        }
        struct Params: Encodable {
            let p_scope: String
            let p_committee_id: String?
            let p_area: String?
            let p_house_id: String?
            let p_title: String
            let p_description: String?
            let p_slots: [SlotParam]
            let p_respond_by: String?
            let p_email: Bool
        }
        let base = params(scope)
        let response = try await supabase
            .rpc("create_meeting", params: Params(
                p_scope: base.p_scope,
                p_committee_id: base.p_committee_id,
                p_area: base.p_area,
                p_house_id: base.p_house_id,
                p_title: title,
                p_description: description,
                p_slots: slots.map { SlotParam(
                    starts_at: isoString($0.startsAt),
                    duration_min: $0.durationMin,
                    ends_at: $0.endsAt.map(isoString)
                ) },
                p_respond_by: respondBy,
                p_email: emailEveryone
            ))
            .execute()
        return try? JSONDecoder().decode(UUID.self, from: response.data)
    }

    /// Create a meeting at a single known time — no voting. Lands as scheduled
    /// with the (optional) Meet link, posting to the room + notifying everyone.
    @discardableResult
    func createScheduledMeeting(
        scope: MeetingScope,
        title: String,
        description: String?,
        startsAt: Date,
        durationMin: Int,
        meetUrl: String?,
        endsAt: Date? = nil
    ) async throws -> UUID? {
        struct Params: Encodable {
            let p_scope: String
            let p_committee_id: String?
            let p_area: String?
            let p_house_id: String?
            let p_title: String
            let p_description: String?
            let p_starts_at: String
            let p_duration_min: Int
            let p_meet_url: String?
            let p_ends_at: String?
        }
        let base = params(scope)
        let response = try await supabase
            .rpc("create_scheduled_meeting", params: Params(
                p_scope: base.p_scope,
                p_committee_id: base.p_committee_id,
                p_area: base.p_area,
                p_house_id: base.p_house_id,
                p_title: title,
                p_description: description,
                p_starts_at: isoString(startsAt),
                p_duration_min: durationMin,
                p_meet_url: meetUrl?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                p_ends_at: endsAt.map(isoString)
            ))
            .execute()
        return try? JSONDecoder().decode(UUID.self, from: response.data)
    }

    /// Set (or change) my availability — bulk upsert of my own rows.
    func setMyAvailability(meetingId: UUID, answers: [UUID: MeetingAvailability]) async throws {
        struct Params: Encodable {
            let p_meeting: String
            let p_answers: [String: String]
        }
        var map: [String: String] = [:]
        for (slot, status) in answers { map[slot.uuidString] = status.rawValue }
        try await supabase
            .rpc("set_my_availability", params: Params(p_meeting: meetingId.uuidString, p_answers: map))
            .execute()
    }

    /// Finalize — pick the winning slot + attach the Meet link — organizer or admin.
    func finalizeMeeting(meetingId: UUID, slotId: UUID, meetUrl: String) async throws {
        struct Params: Encodable { let p_meeting: String; let p_slot: String; let p_meet_url: String }
        try await supabase
            .rpc("finalize_meeting", params: Params(
                p_meeting: meetingId.uuidString,
                p_slot: slotId.uuidString,
                p_meet_url: meetUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            .execute()
    }

    /// Finalize — pick the winning slot and create a real Event from it. Carries
    /// yes/if-need-be voters over as unconfirmed Going/Maybe RSVPs.
    @discardableResult
    func finalizeMeetingAsEvent(
        meetingId: UUID,
        slotId: UUID,
        kind: EventKind,
        title: String?,
        description: String? = nil,
        location: String?
    ) async throws -> UUID? {
        struct Params: Encodable {
            let p_meeting: String
            let p_slot: String
            let p_kind: String
            let p_title: String?
            let p_description: String?
            let p_location: String?
        }
        let response = try await supabase
            .rpc("finalize_meeting_as_event", params: Params(
                p_meeting: meetingId.uuidString,
                p_slot: slotId.uuidString,
                p_kind: kind.rawValue,
                p_title: title,
                p_description: description,
                p_location: location
            ))
            .execute()
        return try? JSONDecoder().decode(UUID.self, from: response.data)
    }

    func cancelMeeting(meetingId: UUID) async throws {
        struct Params: Encodable { let p_meeting: String }
        try await supabase.rpc("cancel_meeting", params: Params(p_meeting: meetingId.uuidString)).execute()
    }

    func deleteMeeting(meetingId: UUID) async throws {
        struct Params: Encodable { let p_meeting: String }
        try await supabase.rpc("delete_meeting", params: Params(p_meeting: meetingId.uuidString)).execute()
    }

    // MARK: - Realtime

    /// Live-refetch (via `onChange`) when any meeting / slot / availability row
    /// changes for this room. Idempotent per roomKey.
    func subscribe(scope: MeetingScope, onChange: @escaping () -> Void) {
        let key = scope.roomKey
        guard channels[key] == nil else { return }
        let channel = supabase.channel("meetings-\(key)")
        channels[key] = channel
        Task {
            for table in ["meetings", "meeting_slots", "meeting_availability"] {
                channel.onPostgresChange(AnyAction.self, schema: "public", table: table) { _ in
                    Task { @MainActor in onChange() }
                }
            }
            await channel.subscribe()
        }
    }

    func unsubscribe(scope: MeetingScope) {
        let key = scope.roomKey
        guard let channel = channels[key] else { return }
        channels[key] = nil
        Task { await supabase.removeChannel(channel) }
    }

    // MARK: - Google Meet / link helpers (pure, mirror lib/meetings.ts)

    /// A prefilled Google Calendar "create event" link (TEMPLATE action, no
    /// OAuth). The organizer taps it, adds Google Meet in the created event,
    /// saves, then pastes the resulting Meet link back into the app.
    static func googleCalendarCreateUrl(title: String, startsAt: Date, durationMin: Int, details: String?) -> URL? {
        let end = startsAt.addingTimeInterval(Double(durationMin) * 60)
        func stamp(_ d: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            // 20260720T143000Z
            return f.string(from: d).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
        }
        var comps = URLComponents(string: "https://calendar.google.com/calendar/render")
        var items = [
            URLQueryItem(name: "action", value: "TEMPLATE"),
            URLQueryItem(name: "text", value: title),
            URLQueryItem(name: "dates", value: "\(stamp(startsAt))/\(stamp(end))"),
        ]
        if let details, !details.isEmpty { items.append(URLQueryItem(name: "details", value: details)) }
        comps?.queryItems = items
        return comps?.url
    }

    /// Lightweight check that a pasted string looks like a Meet / Calendar link.
    static func looksLikeMeetLink(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.range(of: #"^https?://"#, options: .regularExpression) != nil else { return false }
        return v.range(of: #"(meet\.google\.com|calendar\.google\.com|goo\.gl)"#, options: .regularExpression) != nil
    }

    // MARK: - Private

    private struct ScopeParams: Encodable {
        let p_scope: String
        let p_committee_id: String?
        let p_area: String?
        let p_house_id: String?
    }

    private func params(_ scope: MeetingScope) -> ScopeParams {
        switch scope {
        case let .committee(committeeId, _, area):
            return ScopeParams(p_scope: "committee", p_committee_id: committeeId.uuidString, p_area: area, p_house_id: nil)
        case let .house(houseId, _):
            return ScopeParams(p_scope: "house", p_committee_id: nil, p_area: nil, p_house_id: houseId.uuidString)
        case .family:
            return ScopeParams(p_scope: "family", p_committee_id: nil, p_area: nil, p_house_id: nil)
        }
    }

    fileprivate static func bestSlotId(_ slots: [MeetingSlot]) -> UUID? {
        var best: UUID? = nil
        var bestScore = -1.0
        for s in slots where s.score > bestScore {
            bestScore = s.score
            best = s.id
        }
        return best
    }
}

// MARK: - Row decoding

private struct MeetingRow: Decodable {
    let id: UUID
    let scopeType: String
    let committeeSlug: String?
    let area: String?
    let houseId: UUID?
    let title: String
    let description: String?
    let createdBy: UUID?
    let createdAt: Date
    let respondBy: String?
    let status: MeetingStatus
    let chosenSlotId: UUID?
    let meetUrl: String?
    let createdEventId: UUID?
    let meetingSlots: [SlotRow]?

    struct SlotRow: Decodable {
        let id: UUID
        let startsAt: Date
        let endsAt: Date?
        let durationMin: Int
        let position: Int
        enum CodingKeys: String, CodingKey {
            case id
            case startsAt = "starts_at"
            case endsAt = "ends_at"
            case durationMin = "duration_min"
            case position
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case scopeType = "scope_type"
        case committeeSlug = "committee_slug"
        case area
        case houseId = "house_id"
        case title, description
        case createdBy = "created_by"
        case createdAt = "created_at"
        case respondBy = "respond_by"
        case status
        case chosenSlotId = "chosen_slot_id"
        case meetUrl = "meet_url"
        case createdEventId = "created_event_id"
        case meetingSlots = "meeting_slots"
    }

    func toMeeting(availability: [AvailabilityRow], uid: UUID?) -> Meeting {
        // Index availability per slot + per meeting for "mine" + respondents.
        var bySlot: [UUID: (yes: [UUID], ifNeedBe: [UUID], no: [UUID])] = [:]
        var mine: [UUID: MeetingAvailability] = [:]
        var responders = Set<UUID>()
        for a in availability where a.meetingId == id {
            var bucket = bySlot[a.slotId] ?? ([], [], [])
            switch a.status {
            case .yes:      bucket.yes.append(a.userId)
            case .ifNeedBe: bucket.ifNeedBe.append(a.userId)
            case .no:       bucket.no.append(a.userId)
            }
            bySlot[a.slotId] = bucket
            responders.insert(a.userId)
            if let uid, a.userId == uid { mine[a.slotId] = a.status }
        }

        let slots: [MeetingSlot] = (meetingSlots ?? [])
            .sorted { $0.position != $1.position ? $0.position < $1.position : $0.startsAt < $1.startsAt }
            .map { s in
                let b = bySlot[s.id] ?? ([], [], [])
                return MeetingSlot(
                    id: s.id, startsAt: s.startsAt, endsAt: s.endsAt,
                    durationMin: s.durationMin, position: s.position,
                    yes: b.yes, ifNeedBe: b.ifNeedBe, no: b.no
                )
            }

        return Meeting(
            id: id, scopeType: scopeType, committeeSlug: committeeSlug, area: area,
            houseId: houseId, title: title, description: description, createdBy: createdBy,
            createdByMe: uid != nil && createdBy == uid, createdAt: createdAt,
            respondBy: respondBy, status: status, chosenSlotId: chosenSlotId,
            meetUrl: meetUrl, createdEventId: createdEventId, slots: slots,
            myAnswers: mine, bestSlotId: MeetingsService.bestSlotId(slots),
            respondentCount: responders.count
        )
    }
}

private struct AvailabilityRow: Decodable {
    let meetingId: UUID
    let slotId: UUID
    let userId: UUID
    let status: MeetingAvailability
    enum CodingKeys: String, CodingKey {
        case meetingId = "meeting_id"
        case slotId = "slot_id"
        case userId = "user_id"
        case status
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
