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
    /// The web deep link (e.g. carries `&comment=<id>` a post_comment/reply/
    /// mention notification can't express via targetType/targetId alone).
    var url: String? = nil
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
    /// Migration 0126 — lets a send email the opted-in list without ever
    /// painting the top-of-app banner. Defaults true so seed rows (and any
    /// row from before this column existed) still show, matching the DB's
    /// own column default.
    var showBanner: Bool = true
    /// Migration 0096 — pairs with `excludeNotAttending` to hide the banner
    /// from anyone who explicitly RSVP'd "Can't make it" to the linked event.
    var eventId: String? = nil
    var excludeNotAttending: Bool = false

    enum CodingKeys: String, CodingKey {
        // The DB column is `severity` ('info' | 'alert'); AnnouncementKind maps to/from it.
        case id, title, body
        case kind = "severity"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
        case showBanner = "show_banner"
        case eventId = "event_id"
        case excludeNotAttending = "exclude_not_attending"
    }

    init(id: String, title: String, body: String?, kind: AnnouncementKind, expiresAt: Date?, createdAt: Date?, showBanner: Bool = true, eventId: String? = nil, excludeNotAttending: Bool = false) {
        self.id = id; self.title = title; self.body = body; self.kind = kind
        self.expiresAt = expiresAt; self.createdAt = createdAt; self.showBanner = showBanner
        self.eventId = eventId; self.excludeNotAttending = excludeNotAttending
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        kind = try c.decode(AnnouncementKind.self, forKey: .kind)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        showBanner = try c.decodeIfPresent(Bool.self, forKey: .showBanner) ?? true
        eventId = try c.decodeIfPresent(String.self, forKey: .eventId)
        excludeNotAttending = try c.decodeIfPresent(Bool.self, forKey: .excludeNotAttending) ?? false
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

// MARK: - Notification test roster (migrations 0156-0157)
// Admin → Notification Test: send one test push to a specific member, and a
// "confirmed" checklist of who's been manually verified to actually receive
// pushes. Mirrors web's lib/notificationTest.ts `NotificationTestMember`.

struct NotificationTestMember: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var avatarUrl: String?
    var confirmed: Bool
    var confirmedAt: Date?
    var confirmedByName: String?
}
