import Foundation

// MARK: - Work Item
//
// A resort work-checklist task (migration 0048). Any signed-in member can add
// items and check them off; admins can edit, delete, and link them to events.
// Mirrors the web `WorkItem` (lib/types.ts) and `work_items` columns.

struct WorkItem: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var notes: String?
    var category: String?
    var status: WorkItemStatus
    var peopleNeeded: Int?     // null = not set (not 0)
    var createdBy: UUID?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, notes, category, status
        case peopleNeeded = "people_needed"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var isDone: Bool { status == .done }
}

enum WorkItemStatus: String, Codable {
    case open
    case done
}
