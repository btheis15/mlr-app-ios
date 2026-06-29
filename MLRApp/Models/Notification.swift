import Foundation

// MARK: - Notification

struct AppNotification: Codable, Identifiable, Equatable {
    let id: UUID
    let userId: UUID        // maps to recipient_id in DB
    var kind: NotifType     // maps to type in DB
    var title: String
    var body: String?
    var targetType: String? // maps to entity_type in DB
    var targetId: String?   // maps to entity_id in DB
    var actorName: String?      // populated from profiles join, not a flat column
    var actorAvatarUrl: String? // populated from profiles join, not a flat column
    var seenAt: Date?
    var readAt: Date?
    var expiresAt: Date?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "recipient_id"
        case kind = "type"
        case title, body
        case targetType = "entity_type"
        case targetId = "entity_id"
        case actorName = "actor_name"       // unused by synthesized decode; see NotifRow
        case actorAvatarUrl = "actor_avatar_url"
        case seenAt = "seen_at"
        case readAt = "read_at"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    var isUnread: Bool { readAt == nil }

    var isExpiredForBadge: Bool {
        guard let expires = expiresAt else { return false }
        return expires < .now
    }

    var countsForBadge: Bool {
        seenAt == nil && !isExpiredForBadge
    }
}

// MARK: - Announcement

struct Announcement: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var body: String?
    var kind: AnnouncementKind
    var expiresAt: Date?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        // The DB column is `severity` ('info' | 'alert'); AnnouncementKind maps to/from it.
        case id, title, body
        case kind = "severity"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    var isExpired: Bool {
        guard let expires = expiresAt else { return false }
        return expires < .now
    }
}

/// Visual style for an announcement. The DB only stores `severity` = 'info' | 'alert',
/// so on the wire we map 'info' → .info and 'alert' → .urgent (the loud style); when
/// saving, anything other than .info collapses back to 'alert'. The extra cases
/// (.warning/.fest) are used only for locally-constructed banners/previews.
enum AnnouncementKind: String, Codable {
    case info
    case warning
    case urgent
    case fest

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "info":    self = .info
        case "alert":   self = .urgent
        case "warning": self = .warning
        case "fest":    self = .fest
        default:        self = .info
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .info ? "info" : "alert")
    }

    /// The DB `severity` value this kind persists as.
    var severity: String { self == .info ? "info" : "alert" }
}
