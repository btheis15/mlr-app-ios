import Foundation
import SwiftUI

// MARK: - Work Item
//
// A resort work-checklist task (migration 0048). Any signed-in member can add
// items and check them off; admins can edit, delete, and link them to events.
// Items are scoped: house_id null = a resort-wide "MLR" item everyone sees;
// house_id set = a house-only item (migration 0066). An optional urgency rating
// (0069) ranks the list, and items can carry photo/video media (0067).
// Mirrors the web `WorkItem` (lib/types.ts) and `work_items` columns.

struct WorkItem: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var notes: String?
    var category: String?
    var status: WorkItemStatus
    var peopleNeeded: Int?     // null = not set (not 0)
    var houseId: UUID?         // null = MLR / resort-wide; set = house-only (0066)
    var urgency: WorkUrgency?  // null = unrated (0069)
    /// Only set when `urgency == .custom` (migration 0186).
    var customLabel: String?
    var customColor: WorkUrgencyColor?
    /// 1–15, or nil for a one-off (migration 0186). `mark_work_item_done()`
    /// auto-creates the next cycle when this is set.
    var recurEveryYears: Int?
    /// ⚠️ The auto-created next cycle exists IMMEDIATELY so the recurrence can
    /// never be lost — but it's stamped with Jan 1 of the year it's next due and
    /// MUST NOT show until then. Filter on `isSurfaced`.
    var surfaceOn: Date?
    var media: [WorkItemMedia] // photo/video attachments (0067), position order
    var commentCount: Int      // count of work_item_comments (0068)
    var createdBy: UUID?
    var createdAt: Date
    var updatedAt: Date
    var completedBy: UUID?       // migration 0088
    var completedAt: Date?       // migration 0088
    var completedByName: String? // from completed_by_profile join

    enum CodingKeys: String, CodingKey {
        case id, title, notes, category, status, urgency
        case customLabel = "custom_label"
        case customColor = "custom_color"
        case recurEveryYears = "recur_every_years"
        case surfaceOn = "surface_on"
        case peopleNeeded = "people_needed"
        case houseId = "house_id"
        case media = "work_item_media"
        case comments = "work_item_comments"   // embedded rows; only used to count
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case completedBy = "completed_by"
        case completedAt = "completed_at"
        case completedByProfile = "completed_by_profile"
    }

    var isDone: Bool { status == .done }

    /// True once a recurring item's next cycle is actually due.
    ///
    /// ⚠️ A future `surface_on` row is real and already in the table — it just
    /// isn't this year's problem. Showing it puts a chore three years out on
    /// today's checklist.
    var isSurfaced: Bool {
        guard let surfaceOn else { return true }
        return surfaceOn <= .now
    }

    var isRecurring: Bool { (recurEveryYears ?? 0) > 0 }

    // Custom decode so the embedded media/comment rows map onto flat fields.
    // A bare `work_items(*)` select (event links, widget) omits the embeds, so
    // everything embed-derived defaults gracefully.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = try c.decode(UUID.self, forKey: .id)
        title        = try c.decode(String.self, forKey: .title)
        notes        = try? c.decodeIfPresent(String.self, forKey: .notes)
        category     = try? c.decodeIfPresent(String.self, forKey: .category)
        status       = try c.decode(WorkItemStatus.self, forKey: .status)
        peopleNeeded = try? c.decodeIfPresent(Int.self, forKey: .peopleNeeded)
        houseId      = try? c.decodeIfPresent(UUID.self, forKey: .houseId)
        urgency      = try? c.decodeIfPresent(WorkUrgency.self, forKey: .urgency)
        customLabel  = try? c.decodeIfPresent(String.self, forKey: .customLabel)
        customColor  = try? c.decodeIfPresent(WorkUrgencyColor.self, forKey: .customColor)
        recurEveryYears = try? c.decodeIfPresent(Int.self, forKey: .recurEveryYears)
        surfaceOn    = try? c.decodeIfPresent(Date.self, forKey: .surfaceOn)
        let mediaRows = (try? c.decodeIfPresent([WorkItemMedia].self, forKey: .media)) ?? nil
        media        = (mediaRows ?? []).sorted { $0.position < $1.position }
        let commentRows = (try? c.decodeIfPresent([CommentRef].self, forKey: .comments)) ?? nil
        commentCount = (commentRows ?? []).count
        createdBy    = try? c.decodeIfPresent(UUID.self, forKey: .createdBy)
        createdAt    = try c.decode(Date.self, forKey: .createdAt)
        updatedAt    = try c.decode(Date.self, forKey: .updatedAt)
        completedBy  = try? c.decodeIfPresent(UUID.self, forKey: .completedBy)
        completedAt  = try? c.decodeIfPresent(Date.self, forKey: .completedAt)
        struct NameRef: Decodable { let displayName: String?; enum CodingKeys: String, CodingKey { case displayName = "display_name" } }
        completedByName = (try? c.decodeIfPresent(NameRef.self, forKey: .completedByProfile))?.displayName
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(peopleNeeded, forKey: .peopleNeeded)
        try c.encodeIfPresent(houseId, forKey: .houseId)
        try c.encodeIfPresent(urgency, forKey: .urgency)
        try c.encodeIfPresent(customLabel, forKey: .customLabel)
        try c.encodeIfPresent(customColor, forKey: .customColor)
        try c.encodeIfPresent(recurEveryYears, forKey: .recurEveryYears)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// Minimal shape for counting embedded comment rows (`work_item_comments(id)`).
    private struct CommentRef: Decodable { let id: UUID }
}

/// One row of `event_work_item_house_counts` — how many items a house has on an
/// event, readable even by someone who can't see the items themselves.
struct EventHouseItemCount: Decodable, Identifiable {
    let houseId: UUID
    let houseName: String
    let houseEmoji: String?
    let itemCount: Int

    var id: UUID { houseId }

    enum CodingKeys: String, CodingKey {
        case houseId = "house_id"
        case houseName = "house_name"
        case houseEmoji = "house_emoji"
        case itemCount = "item_count"
    }
}

enum WorkItemStatus: String, Codable {
    case open
    case done
}

// MARK: - Work Urgency (migration 0069)

enum WorkUrgency: String, Codable, CaseIterable {
    case asap
    case thisYear   = "this_year"
    /// Migration 0186 — the tier between "this year" and "nice to have".
    case nextYear   = "next_year"
    case niceToHave = "nice_to_have"
    /// Migration 0186 — a free-text tier the item names itself.
    ///
    /// ⚠️ A `custom` item has NO entry in the fixed tier table. Always resolve
    /// display through `WorkUrgencyDisplay(item:)`, never by switching on the
    /// raw case at a call site — a `custom` item hitting a fixed-tier lookup
    /// renders blank or crashes.
    case custom

    /// The tiers the composer offers as fixed picks. `custom` is excluded — it's
    /// chosen through its own control, since it needs a label and a colour.
    static var fixedTiers: [WorkUrgency] { [.asap, .thisYear, .nextYear, .niceToHave] }

    /// ⚠️ Only correct for the FIXED tiers. `custom` reads its label from the
    /// item's `customLabel`, so this returns a placeholder for it.
    var label: String {
        switch self {
        case .asap:       return "ASAP"
        case .thisYear:   return "This year"
        case .nextYear:   return "Next year"
        case .niceToHave: return "Nice to have"
        case .custom:     return "Custom"
        }
    }

    /// Coloured dot used on badges. `this_year` is ORANGE and `next_year` is
    /// yellow (web #545) — they used to collide on the same yellow.
    var emoji: String {
        switch self {
        case .asap:       return "🔴"
        case .thisYear:   return "🟠"
        case .nextYear:   return "🟡"
        case .niceToHave: return "🟢"
        case .custom:     return "⚪"
        }
    }

    /// Sort order within the open list (lower = more urgent). Unrated sorts
    /// last; a custom tier sorts alongside "this year", since it has no
    /// inherent position of its own.
    var rank: Double {
        switch self {
        case .asap:       return 0
        case .thisYear:   return 1
        case .custom:     return 1.5
        case .nextYear:   return 2
        case .niceToHave: return 3
        }
    }
}

/// The preset colours a custom urgency can pick.
enum WorkUrgencyColor: String, Codable, CaseIterable, Identifiable {
    case red, orange, yellow, green, blue, purple, gray
    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .red:    return "🔴"
        case .orange: return "🟠"
        case .yellow: return "🟡"
        case .green:  return "🟢"
        case .blue:   return "🔵"
        case .purple: return "🟣"
        case .gray:   return "⚪"
        }
    }

    var uiColor: Color {
        switch self {
        case .red:    return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green:  return .green
        case .blue:   return .blue
        case .purple: return .purple
        case .gray:   return .gray
        }
    }
}

/// ⚠️ THE ONE PLACE an item's urgency is turned into something displayable.
///
/// A `custom` item has no entry in the fixed tier table, so indexing that table
/// by its raw value renders blank. Every badge, chip and sort goes through here.
struct WorkUrgencyDisplay {
    let label: String
    let emoji: String
    let color: Color
    let rank: Double

    /// Returns nil for an unrated item (`urgency` null) — that's a real state,
    /// not a missing value, and it should render no chip at all.
    init?(item: WorkItem) {
        guard let urgency = item.urgency else { return nil }
        if urgency == .custom {
            let color = item.customColor ?? .gray
            self.label = item.customLabel?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Custom"
            self.emoji = color.emoji
            self.color = color.uiColor
        } else {
            self.label = urgency.label
            self.emoji = urgency.emoji
            self.color = urgency.uiColor
        }
        self.rank = urgency.rank
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
