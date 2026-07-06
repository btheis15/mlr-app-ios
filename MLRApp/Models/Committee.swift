import Foundation

// MARK: - Committee

struct Committee: Codable, Identifiable, Equatable {
    let id: UUID
    var slug: String
    var name: String
    var description: String?
    var emoji: String?
    var isPrivate: Bool?
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, slug, name, description, emoji
        case isPrivate = "is_private"
        case createdAt = "created_at"
    }
}

// MARK: - Committee Member

struct CommitteeMember: Codable, Identifiable, Equatable {
    let committeeId: UUID
    let userId: UUID
    var role: CommitteeRole?   // null in DB = regular member
    var areas: [String]        // committee_members.areas (text[], migration 0051)
    var joinedAt: Date?
    var profile: Profile?

    // committee_members has a composite PK (committee_id, user_id) — no id column.
    var id: String { "\(committeeId.uuidString)-\(userId.uuidString)" }

    enum CodingKeys: String, CodingKey {
        case committeeId = "committee_id"
        case userId = "user_id"
        case role
        case areas
        case joinedAt = "joined_at"
        case profile = "profiles"
    }
}

// MARK: - Committee Roster Entry
// A roster slot (migration 0055): a named person with roles, which links to a
// real account (linked_user_id + joined profile) once they verify with the
// matching email. Unlinked slots with an email are "pending verification".

struct CommitteeRosterEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var email: String?
    var phone: String?
    var roles: [String]
    var position: Int
    var linkedUserId: UUID?
    var profile: LinkedProfile?

    /// Whether a real account has claimed this slot.
    var isLinked: Bool { linkedUserId != nil }
    /// Invited (has an email) but not yet claimed by a verified account.
    var isPending: Bool { linkedUserId == nil && (email?.isEmpty == false) }
    /// The name to show — the linked account's current display name wins.
    var displayName: String {
        if let n = profile?.displayName, !n.isEmpty { return n }
        return name
    }
    /// Phone to use: the linked account's profile phone wins, else the roster's.
    var effectivePhone: String? {
        if let p = profile?.phone, !p.isEmpty { return p }
        return phone
    }
    /// Email to use: the linked account's contact email wins, else the roster's.
    var effectiveEmail: String? {
        if let e = profile?.contactEmail, !e.isEmpty { return e }
        return email
    }
    /// True when this slot is a Lead of any area.
    var isLead: Bool { roles.contains { $0.hasSuffix("· Lead") } }

    struct LinkedProfile: Codable, Equatable {
        var displayName: String?
        var avatarUrl: String?
        var phone: String?
        var contactEmail: String?
        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case avatarUrl = "avatar_url"
            case phone
            case contactEmail = "contact_email"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, email, phone, roles, position
        case linkedUserId = "linked_user_id"
        case profile = "profiles"
    }
}

enum CommitteeRole: String, Codable {
    case member
    case lead
    case admin

    // The DB stores the role as free text — leads are 'Lead' (capitalized),
    // regular members are null. Decode leniently so a present value never throws.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self).lowercased()
        switch raw {
        case "lead":  self = .lead
        case "admin": self = .admin
        default:      self = .member
        }
    }
}

// MARK: - Join Request

struct CommitteeJoinRequest: Codable, Identifiable, Equatable {
    let id: UUID
    let committeeId: UUID
    let userId: UUID
    var status: JoinRequestStatus
    var note: String?
    var requestedArea: String?     // legacy single area (migration 0051)
    var requestedAreas: [String]   // migration 0060 — the areas the member picked
    var createdAt: Date?
    var profile: Profile?

    /// All areas the requester asked for — prefers the array, falls back to the
    /// legacy single column so older rows still show something.
    var areas: [String] {
        if !requestedAreas.isEmpty { return requestedAreas }
        if let a = requestedArea, !a.isEmpty { return [a] }
        return []
    }

    enum CodingKeys: String, CodingKey {
        case id
        case committeeId = "committee_id"
        case userId = "user_id"
        case status
        case note = "message"
        case requestedArea = "requested_area"
        case requestedAreas = "requested_areas"
        case createdAt = "created_at"
        case profile = "profiles"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self, forKey: .id)
        committeeId    = try c.decode(UUID.self, forKey: .committeeId)
        userId         = try c.decode(UUID.self, forKey: .userId)
        status         = try c.decode(JoinRequestStatus.self, forKey: .status)
        note           = try? c.decodeIfPresent(String.self, forKey: .note)
        requestedArea  = try? c.decodeIfPresent(String.self, forKey: .requestedArea)
        requestedAreas = (try? c.decodeIfPresent([String].self, forKey: .requestedAreas)) ?? []
        createdAt      = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        profile        = try? c.decodeIfPresent(Profile.self, forKey: .profile)
    }
}

enum JoinRequestStatus: String, Codable {
    case pending
    case approved
    case rejected
}

// MARK: - Email recipient (committee_member_recipients RPC, migration 0031)

struct CommitteeRecipient: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let email: String
}

// MARK: - Committee Chat Message

struct CommitteeChatMessage: Codable, Identifiable, Equatable {
    let id: UUID
    let committeeId: UUID
    let authorId: UUID
    var authorName: String
    var authorAvatarUrl: String?
    var text: String
    var editedAt: Date?
    var deletedAt: Date?
    var createdAt: Date
    /// The role channel this message belongs to; nil = the committee-wide
    /// "General" channel (migration 0063). Set from the row, not decoded here.
    var area: String? = nil
    /// Attachments (photos/videos/files). Set from the embedded media rows in the
    /// service, not decoded here — so it's excluded from CodingKeys below.
    var media: [ChatMedia] = []

    enum CodingKeys: String, CodingKey {
        case id
        case committeeId = "committee_id"
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
