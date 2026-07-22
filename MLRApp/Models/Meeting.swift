import Foundation

// MARK: - Meeting (migrations 0116–0122)
//
// A Doodle / when2meet-style scheduler pinned to any committee/area or house
// chat room, plus a family-wide scope. An organizer (admin, or a committee/area
// Lead) proposes candidate time slots; every member marks Yes / If-need-be / No
// per slot; the organizer picks the winner and either pastes a Google Meet link
// (posts a join message + notifies the room) or creates a real calendar Event.
//
// One backend, two clients: every table/RPC below is already live on the shared
// Supabase project. Reads go through the client (members-only under RLS, scoped
// to the room); writes go through SECURITY DEFINER RPCs. Mirrors the web app's
// lib/meetings.ts exactly.

enum MeetingAvailability: String, Codable, CaseIterable, Equatable {
    case yes
    case ifNeedBe = "if_need_be"
    case no

    var label: String {
        switch self {
        case .yes: return "Yes"
        case .ifNeedBe: return "If need be"
        case .no: return "No"
        }
    }
}

enum MeetingStatus: String, Codable, Equatable {
    case open
    case scheduled
    case cancelled
}

/// Which room a meeting lives in — drives both the fetch filter and create args.
/// `family` has no room at all — every signed-in member (organizing one is
/// admin-only, enforced server-side by can_organize_meeting).
enum MeetingScope: Equatable {
    case committee(committeeId: UUID, slug: String, area: String?)
    case house(houseId: UUID, slug: String)
    case family

    /// The p_scope value the RPCs expect.
    var typeString: String {
        switch self {
        case .committee: return "committee"
        case .house:     return "house"
        case .family:    return "family"
        }
    }

    /// Stable per-room segment for channels/cache. `family` has no room.
    var roomKey: String {
        switch self {
        case let .committee(_, slug, area): return "c:\(slug)|\(area ?? "")"
        case let .house(houseId, _):        return "h:\(houseId.uuidString)"
        case .family:                       return "family"
        }
    }
}

struct MeetingSlot: Identifiable, Equatable {
    let id: UUID
    var startsAt: Date
    /// Set ⇒ this slot is a DATE RANGE (e.g. a weekend), not a point-in-time
    /// call; `durationMin` is meaningless when this is set.
    var endsAt: Date?
    var durationMin: Int
    var position: Int
    /// Member ids in each bucket (resolve names against the room roster).
    var yes: [UUID]
    var ifNeedBe: [UUID]
    var no: [UUID]

    /// yes*1 + if_need_be*0.5 — the ranking used to pick the best time.
    var score: Double { Double(yes.count) + Double(ifNeedBe.count) * 0.5 }

    var isRange: Bool { endsAt != nil }
}

struct Meeting: Identifiable, Equatable {
    let id: UUID
    var scopeType: String        // "committee" | "house" | "family"
    var committeeSlug: String?
    var area: String?
    var houseId: UUID?
    var title: String
    var description: String?
    var createdBy: UUID?
    /// True when the viewer created it (drives Finalize/Cancel/Delete alongside isAdmin).
    var createdByMe: Bool
    var createdAt: Date
    var respondBy: String?       // YYYY-MM-DD; nil = no deadline
    var status: MeetingStatus
    var chosenSlotId: UUID?
    var meetUrl: String?
    /// Set once finalized as an Event instead of (or alongside) a Meet link.
    var createdEventId: UUID?
    var slots: [MeetingSlot]
    /// The viewer's own answer per slot id.
    var myAnswers: [UUID: MeetingAvailability]
    /// Slot id with the highest score (ties → earliest), or nil if no slots.
    var bestSlotId: UUID?
    /// Distinct members who have answered at least one slot.
    var respondentCount: Int

    var isOpen: Bool { status == .open }
}

// MARK: - Create inputs

/// One proposed slot when composing a meeting. Set `endsAt` for a date-range
/// slot (a weekend); otherwise it's a point-in-time call of `durationMin`.
struct MeetingSlotInput {
    var startsAt: Date
    var durationMin: Int = 60
    var endsAt: Date? = nil
}
