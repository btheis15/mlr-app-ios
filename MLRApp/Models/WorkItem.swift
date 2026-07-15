import Foundation

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
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    /// Minimal shape for counting embedded comment rows (`work_item_comments(id)`).
    private struct CommentRef: Decodable { let id: UUID }
}

enum WorkItemStatus: String, Codable {
    case open
    case done
}

// MARK: - Work Urgency (migration 0069)

enum WorkUrgency: String, Codable, CaseIterable {
    case asap
    case thisYear   = "this_year"
    case niceToHave = "nice_to_have"

    var label: String {
        switch self {
        case .asap:       return "ASAP"
        case .thisYear:   return "This year"
        case .niceToHave: return "Nice to have"
        }
    }

    /// Coloured dot used on badges (🔴 / 🟡 / 🟢).
    var emoji: String {
        switch self {
        case .asap:       return "🔴"
        case .thisYear:   return "🟡"
        case .niceToHave: return "🟢"
        }
    }

    /// Sort order within the open list (lower = more urgent). Unrated sorts last.
    var rank: Int {
        switch self {
        case .asap:       return 0
        case .thisYear:   return 1
        case .niceToHave: return 2
        }
    }
}
