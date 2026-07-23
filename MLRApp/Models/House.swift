import Foundation

// MARK: - House (migration 0064)
//
// An admin-assigned group (e.g. "MJT House") layered on top of the resort-wide
// "MLR" baseline. A member belongs to at most one house (profiles.house_id).
// Each house gets a private chat (0065) and house-scoped work items (0066).
// World-readable like committees; assignment is admin-only via set_member_house.

struct House: Codable, Identifiable, Equatable {
    let id: UUID
    var slug: String
    var name: String
    var emoji: String
    var description: String
    var position: Int
    /// A shared, editable open-text "house rules" doc (migration 0072). Any house
    /// member can edit it via set_house_rules; empty until someone writes it.
    var rules: String

    enum CodingKeys: String, CodingKey {
        case id, slug, name, emoji, description, position, rules
    }

    init(id: UUID, slug: String, name: String, emoji: String = "🏠", description: String = "", position: Int = 0, rules: String = "") {
        self.id = id; self.slug = slug; self.name = name
        self.emoji = emoji; self.description = description; self.position = position
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(UUID.self, forKey: .id)
        slug        = try c.decode(String.self, forKey: .slug)
        name        = try c.decode(String.self, forKey: .name)
        emoji       = (try? c.decodeIfPresent(String.self, forKey: .emoji)) ?? "🏠"
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        position    = (try? c.decodeIfPresent(Int.self, forKey: .position)) ?? 0
        rules       = (try? c.decodeIfPresent(String.self, forKey: .rules)) ?? ""
    }
}

// MARK: - Work Item Media (migration 0067)
//
// A photo/video attachment on a work item. `storage_path` holds the full URL to
// the Mac-mini media server (mirrors post_media). Ordered by `position`.

struct WorkItemMedia: Codable, Identifiable, Equatable {
    let id: UUID
    var url: String            // storage_path — full media URL
    var mediaType: String      // 'image' | 'video'
    var position: Int

    enum CodingKeys: String, CodingKey {
        case id
        case url = "storage_path"
        case mediaType = "media_type"
        case position
    }

    /// Whether to render with a video player (server transcodes to .mp4).
    var isVideo: Bool { mediaType == "video" || url.isVideoURL }
}

// MARK: - Work Item Comment (migration 0068)
//
// A plain-text comment (with @mentions) on a work item. Follows the parent
// item's visibility. Built in WorkItemsService from a row + the profiles join +
// a separate mentions query (not decoded directly), mirroring how Post is built.

struct WorkItemComment: Identifiable, Equatable {
    let id: UUID
    let workItemId: UUID
    let authorId: UUID
    var authorName: String
    var authorAvatarUrl: String?
    var text: String
    var mentions: [UUID]
    var createdAt: Date
}

// MARK: - House Chat Message (migration 0065)
//
// A single-room private chat message for a house — the house analogue of
// CommitteeChatMessage, minus the per-role `area` (a house is one room). Text +
// @mentions with 24h author edit / soft-delete, mirroring the committee chat.

struct HouseChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let houseId: UUID
    let authorId: UUID
    var authorName: String
    var authorAvatarUrl: String?
    var text: String
    var editedAt: Date?
    var deletedAt: Date?
    var createdAt: Date
    /// Moderation status (migration 0128): visible | pending | hidden. RLS returns
    /// non-'visible' rows only to the author + admins; held rows get a badge for
    /// them and vanish for everyone else on refetch. Set from the row, not decoded.
    var status: String? = nil
    /// Attachments (photos/videos/files). Set from the embedded media rows in the
    /// service, not decoded here — so it's excluded from CodingKeys below.
    var media: [ChatMedia] = []
    /// Tapback reactions. Set from the embedded reaction rows in the service.
    var reactions: [ChatReaction] = []

    enum CodingKeys: String, CodingKey {
        case id
        case houseId = "house_id"
        case authorId = "author_id"
        case authorName = "author_name"
        case authorAvatarUrl = "author_avatar_url"
        case text
        case editedAt = "edited_at"
        case deletedAt = "deleted_at"
        case createdAt = "created_at"
    }

    var isDeleted: Bool { deletedAt != nil }
    var isEdited: Bool { editedAt != nil }
    /// Held by moderation (pending review or hidden) — only the author + admins
    /// ever see such a row (RLS), so this drives a subtle "held" badge for them.
    var isHeld: Bool { let s = status ?? "visible"; return s != "visible" }

    func canEdit(userId: UUID, isAdmin: Bool, now: Date = .now) -> Bool {
        guard !isDeleted else { return false }
        if isAdmin { return true }
        guard authorId == userId else { return false }
        return now.timeIntervalSince(createdAt) < 86400
    }

    func canDelete(userId: UUID, isAdmin: Bool, now: Date = .now) -> Bool {
        canEdit(userId: userId, isAdmin: isAdmin, now: now)
    }
}
