import Foundation

// MARK: - Private activities (migration 0150)
//
// A member-created, invite-only get-together that lives in the Events tab and is
// visible ONLY to the people it's shared with. Anyone can create one; the creator
// + any co-hosts manage it. It can host the same tournament as a Family Fest
// activity (tournamentEnabled). Mirrors lib/privateActivities.ts.

enum ActivityRole: String, Codable { case host, player }
enum ActivityRsvp: String, Codable, CaseIterable {
    case going, maybe, out
    var label: String {
        switch self {
        case .going: return "Going"
        case .maybe: return "Maybe"
        case .out:   return "Can't"
        }
    }
    var emoji: String {
        switch self {
        case .going: return "✅"
        case .maybe: return "🤔"
        case .out:   return "🚫"
        }
    }
}

struct PrivateActivityMember: Identifiable, Decodable, Hashable {
    let id: UUID
    let userId: UUID?
    let name: String
    let role: ActivityRole
    let rsvp: ActivityRsvp?
    let addedBy: UUID?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, role, rsvp
        case userId    = "user_id"
        case addedBy   = "added_by"
        case createdAt = "created_at"
    }

    var isHost: Bool { role == .host }
}

struct PrivateActivity: Identifiable, Decodable {
    let id: UUID
    let title: String
    let emoji: String?
    let description: String?
    let location: String?
    let startsAt: Date?
    let endsAt: Date?
    let tournamentEnabled: Bool
    let archivedAt: Date?
    let createdBy: UUID
    let createdAt: Date
    let members: [PrivateActivityMember]

    enum CodingKeys: String, CodingKey {
        case id, title, emoji, description, location, members = "private_activity_members"
        case startsAt          = "starts_at"
        case endsAt            = "ends_at"
        case tournamentEnabled = "tournament_enabled"
        case archivedAt        = "archived_at"
        case createdBy         = "created_by"
        case createdAt         = "created_at"
    }

    var isArchived: Bool { archivedAt != nil }

    /// Members sorted hosts-first, then by join time.
    var sortedMembers: [PrivateActivityMember] {
        members.sorted { a, b in
            if a.role == b.role { return a.createdAt < b.createdAt }
            return a.role == .host
        }
    }

    var hostNames: [String] { sortedMembers.filter { $0.isHost }.map(\.name) }
    var goingCount: Int { members.filter { $0.rsvp == .going }.count }

    /// Whether `viewer` (an admin, the creator, or a host) may manage this.
    func canManage(viewerId: UUID?, isAdmin: Bool) -> Bool {
        guard let viewerId else { return isAdmin }
        if isAdmin || createdBy == viewerId { return true }
        return members.contains { $0.userId == viewerId && $0.role == .host }
    }

    /// The viewer's own membership row, if any.
    func myMembership(viewerId: UUID?) -> PrivateActivityMember? {
        guard let viewerId else { return nil }
        return members.first { $0.userId == viewerId }
    }
}
