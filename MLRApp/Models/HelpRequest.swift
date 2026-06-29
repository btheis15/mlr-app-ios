import Foundation
import CoreLocation

// MARK: - Help Request
//
// Mirrors the web `HelpRequest` (lib/types.ts / lib/helpRequests.ts) and the
// `help_requests` table (migrations 0037 + 0046). Built by HelpService's row
// mapper from the DB join, so property names here are app-internal — the wire
// column names live in HelpService.

struct HelpRequest: Identifiable, Equatable {
    let id: UUID
    let requesterId: UUID            // user_id
    var requesterName: String        // from profiles join
    var requesterAvatarUrl: String?  // from profiles join
    var category: HelpCategory       // free-text key in DB; unknown/null → .hand
    var what: String                 // description
    var neededCount: Int
    var whereDescription: String?    // where_text
    var latitude: Double?            // lat
    var longitude: Double?           // lng
    var scheduledFor: Date?          // needed_at
    var status: HelpRequestStatus
    var fulfilledAt: Date?
    var notifiedCount: Int
    var createdAt: Date
    var expiresAt: Date?
    var responses: [HelpResponse]
    var items: [BringItem]

    var isCovered: Bool { fulfilledAt != nil }

    var respondersCount: Int { responses.count }

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// Stored as the free-text `key` in help_requests.category. Keys match the web
// HELP_TYPES (lib/helpRequests.ts); unknown/null collapses to `.hand`.
enum HelpCategory: String, Codable, CaseIterable {
    case hand
    case move
    case setup
    case ride
    case supplies
    case urgent

    /// The default request type — a friendly "lend a hand", never urgent.
    static let `default`: HelpCategory = .hand

    /// Lenient lookup from the stored key (nil/unknown → default).
    init(key: String?) {
        self = key.flatMap(HelpCategory.init(rawValue:)) ?? .default
    }

    var label: String {
        switch self {
        case .hand:     return "Lend a hand"
        case .move:     return "Move / haul"
        case .setup:    return "Set up / project"
        case .ride:     return "Ride"
        case .supplies: return "Supplies"
        case .urgent:   return "Urgent"
        }
    }

    var emoji: String {
        switch self {
        case .hand:     return "🙌"
        case .move:     return "🪵"
        case .setup:    return "🔧"
        case .ride:     return "🚗"
        case .supplies: return "🛒"
        case .urgent:   return "🚨"
        }
    }
}

enum HelpRequestStatus: String, Codable {
    case open
    case resolved
    case cancelled
}

// MARK: - Help Response

struct HelpResponse: Identifiable, Equatable {
    let requestId: UUID
    let responderId: UUID   // user_id
    var responderName: String
    var responderAvatarUrl: String?
    var note: String?
    var createdAt: Date

    // help_responses has a composite PK (request_id, user_id) — no id column.
    var id: String { "\(requestId.uuidString)-\(responderId.uuidString)" }
}

// MARK: - Bring Item ("what to bring" checklist, migration 0046)

struct BringItem: Identifiable, Equatable {
    let id: UUID
    var label: String
    var claimedBy: UUID?
    var claimedByName: String?
    var claimedAt: Date?

    var isClaimed: Bool { claimedBy != nil }
}
