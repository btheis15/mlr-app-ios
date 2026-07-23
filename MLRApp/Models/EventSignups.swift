import Foundation
import Supabase

// MARK: - Event sign-ups (migrations 0135 / 0136 / 0143)
//
// A schedule event can take sign-ups in one of three modes:
//   • interval   — auto-generated time slots (start→end, every N minutes)
//   • slots      — an admin-defined list of named slots
//   • headcount  — no time dimension, just a running list of who's in
// Each sign-up is one person per row (a linked member or a typed name) plus a
// value for each admin-defined custom column. Mirrors lib/scheduleSignups.ts
// (schedule kind only — the activity kind was retired by migration 0141).

/// An admin-defined custom column collected at sign-up time.
struct SignupField: Identifiable, Codable, Hashable {
    let id: String
    let label: String
}

/// A named/explicit sign-up slot (slots mode).
struct ScheduleSlot: Identifiable, Decodable, Hashable {
    let id: UUID
    let day: String?
    let startTime: String
    let endTime: String?
    let label: String?
    let capacity: Int?
    let position: Int

    enum CodingKeys: String, CodingKey {
        case id, day, label, capacity, position
        case startTime = "start_time"
        case endTime   = "end_time"
    }
}

/// One person's sign-up row.
struct ScheduleSignup: Identifiable, Decodable, Hashable {
    let id: UUID
    let slotStart: String?
    let slotId: UUID?
    let userId: UUID?
    let name: String
    let addedBy: UUID?
    let fields: [String: String]?
    let teamId: UUID?
    let teamName: String?

    enum CodingKeys: String, CodingKey {
        case id, name, fields
        case slotStart = "slot_start"
        case slotId    = "slot_id"
        case userId    = "user_id"
        case addedBy   = "added_by"
        case teamId    = "team_id"
        case teamName  = "team_name"
    }
}

// MARK: - Service

@Observable
@MainActor
final class SignupsService {

    /// All sign-ups for an event (across every slot / the headcount bucket).
    func fetchSignups(itemId: UUID) async -> [ScheduleSignup] {
        do {
            return try await supabase
                .from("fest_schedule_signups")
                .select("*")
                .eq("schedule_item_id", value: itemId.uuidString)
                .execute()
                .value
        } catch {
            return []
        }
    }

    /// Explicit slots for a "slots"-mode event (empty for interval/headcount).
    func fetchSlots(itemId: UUID) async -> [ScheduleSlot] {
        do {
            return try await supabase
                .from("fest_schedule_slots")
                .select("*")
                .eq("schedule_item_id", value: itemId.uuidString)
                .order("position", ascending: true)
                .execute()
                .value
        } catch {
            return []
        }
    }

    /// Sign someone up. Pass `slotId` (slots mode), `slotStart` (interval), or
    /// neither (headcount). `forUserId`/`name` nil ⇒ the caller. Teams are not
    /// yet supported here (individual sign-up only).
    func signUp(
        itemId: UUID,
        slotStart: String? = nil,
        slotId: UUID? = nil,
        forUserId: UUID? = nil,
        name: String? = nil,
        fields: [String: String] = [:]
    ) async throws {
        let params: [String: AnyJSON] = [
            "p_item":     .string(itemId.uuidString),
            "p_slot":     slotStart.map { AnyJSON.string($0) } ?? .null,
            "p_for_user": forUserId.map { AnyJSON.string($0.uuidString) } ?? .null,
            "p_name":     name.map { AnyJSON.string($0) } ?? .null,
            "p_slot_id":  slotId.map { AnyJSON.string($0.uuidString) } ?? .null,
            "p_fields":   .object(fields.mapValues { AnyJSON.string($0) }),
        ]
        try await supabase.rpc("sign_up_for_schedule_slot", params: params).execute()
    }

    func remove(signupId: UUID) async throws {
        struct P: Encodable { let p_signup: String }
        try await supabase.rpc("remove_schedule_signup", params: P(p_signup: signupId.uuidString)).execute()
    }

    /// "HH:MM" start times from start up to (not reaching) end, `minutes` apart —
    /// mirrors the fest_schedule_slot_starts() Postgres function (interval mode).
    static func computeSlots(startTime: String?, endTime: String?, minutes: Int?) -> [String] {
        guard let minutes, minutes > 0,
              let start = toMinutes(startTime), let end = toMinutes(endTime), start < end
        else { return [] }
        var out: [String] = []
        var t = start
        while t < end {
            out.append(String(format: "%02d:%02d", t / 60, t % 60))
            t += minutes
        }
        return out
    }

    private static func toMinutes(_ hhmm: String?) -> Int? {
        guard let parts = hhmm?.split(separator: ":"), parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}
