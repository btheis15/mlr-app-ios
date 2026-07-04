import Foundation

// MARK: - Push & Notification Types

enum PushType: String, Codable, CaseIterable {
    case chat
    case alerts
    case birthdays
    case committeeJoin = "committee_join"
    case committeeJoinRequest = "committee_join_request"
    case cabinDecision = "cabin_decision"
    case postTag = "post_tag"
    case postMention = "post_mention"
    case postReply = "post_reply"
    case eventRsvp = "event_rsvp"
    case helpRequest = "help_request"
    case helpResponse = "help_response"
    case workItemCreated = "work_item_created"
    case houseStayCreated = "house_stay_created"
}

enum NotifType: String, Codable, CaseIterable {
    case postComment = "post_comment"
    case postReply = "post_reply"
    case postMention = "post_mention"
    case postTag = "post_tag"
    case postReaction = "post_reaction"
    case newPost = "new_post"
    case chatMention = "chat_mention"
    case committeeJoin = "committee_join"
    case committeeJoinRequest = "committee_join_request"
    case cabinRequest = "cabin_request"
    case cabinDecision = "cabin_decision"
    case eventRsvp = "event_rsvp"
    case helpRequest = "help_request"
    case helpResponse = "help_response"
    case helpUrgent = "help_urgent"
    case workItemComment = "work_item_comment"
    case workItemMention = "work_item_mention"
    case workItemCreated = "work_item_created"
    case houseStayCreated = "house_stay_created"
    case broadcast
}

// MARK: - Profile

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var email: String
    var phone: String?
    var birthday: String?
    var bio: String?
    var avatarUrl: String?
    var venmoHandle: String?
    var zelleHandle: String?
    var appleCashHandle: String?
    var paypalHandle: String? = nil
    var contactPreferred: String? = nil
    var payPreferred: String? = nil
    var address: String? = nil
    var fullName: String? = nil
    var household: String? = nil
    var houseId: UUID? = nil        // the member's House (migration 0064); admin-assigned
    var includeInDirectory: Bool = true
    var notifyNewMembers: Bool = true
    var emailAlerts: Bool
    var pushLevel: String?
    var pushTypes: [PushType]
    var notifTypes: [NotifType]
    var pushPrompted: Bool
    var isAdmin: Bool
    var betaTester: Bool
    var willingToHelp: Bool
    var introSeen: Bool
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name = "display_name"
        case email = "contact_email"
        case phone, birthday, bio
        case avatarUrl = "avatar_url"
        case venmoHandle = "venmo"
        case zelleHandle = "zelle"
        case appleCashHandle = "cashapp"
        case paypalHandle = "paypal"
        case contactPreferred = "contact_preferred"
        case payPreferred = "pay_preferred"
        case address
        case fullName = "full_name"
        case household
        case houseId = "house_id"
        case includeInDirectory = "include_in_directory"
        case notifyNewMembers = "notify_new_members"
        case emailAlerts = "email_alerts"
        case pushLevel = "push_level"
        case pushTypes = "push_types"
        case notifTypes = "notif_types"
        case pushPrompted = "push_prompted"
        case isAdmin = "is_admin"
        case betaTester = "beta_tester"
        case willingToHelp = "willing_to_help"
        case introSeen = "intro_seen"
        case createdAt = "created_at"
    }

    var displayName: String { name }

    var hasPaymentHandle: Bool {
        venmoHandle != nil || zelleHandle != nil || appleCashHandle != nil || paypalHandle != nil
    }

    static let guest = Profile(
        id: UUID(),
        name: "Guest",
        email: "",
        phone: nil,
        birthday: nil,
        bio: nil,
        avatarUrl: nil,
        venmoHandle: nil,
        zelleHandle: nil,
        appleCashHandle: nil,
        emailAlerts: false,
        pushLevel: nil,
        pushTypes: [],
        notifTypes: [],
        pushPrompted: false,
        isAdmin: false,
        betaTester: false,
        willingToHelp: false,
        introSeen: true,
        createdAt: nil
    )
}

// MARK: - Profile Decodable
// Custom init handles nullable DB columns (display_name, contact_email) for new accounts.

extension Profile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self, forKey: .id)
        name            = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        email           = (try? c.decodeIfPresent(String.self, forKey: .email)) ?? ""
        phone           = try? c.decodeIfPresent(String.self, forKey: .phone)
        birthday        = try? c.decodeIfPresent(String.self, forKey: .birthday)
        bio             = try? c.decodeIfPresent(String.self, forKey: .bio)
        avatarUrl       = try? c.decodeIfPresent(String.self, forKey: .avatarUrl)
        venmoHandle     = try? c.decodeIfPresent(String.self, forKey: .venmoHandle)
        zelleHandle     = try? c.decodeIfPresent(String.self, forKey: .zelleHandle)
        appleCashHandle = try? c.decodeIfPresent(String.self, forKey: .appleCashHandle)
        paypalHandle      = try? c.decodeIfPresent(String.self, forKey: .paypalHandle)
        contactPreferred  = try? c.decodeIfPresent(String.self, forKey: .contactPreferred)
        payPreferred      = try? c.decodeIfPresent(String.self, forKey: .payPreferred)
        address           = try? c.decodeIfPresent(String.self, forKey: .address)
        fullName          = try? c.decodeIfPresent(String.self, forKey: .fullName)
        household         = try? c.decodeIfPresent(String.self, forKey: .household)
        houseId           = try? c.decodeIfPresent(UUID.self, forKey: .houseId)
        includeInDirectory = (try? c.decode(Bool.self, forKey: .includeInDirectory)) ?? true
        notifyNewMembers   = (try? c.decode(Bool.self, forKey: .notifyNewMembers)) ?? true
        emailAlerts     = (try? c.decode(Bool.self, forKey: .emailAlerts)) ?? true
        pushLevel       = try? c.decodeIfPresent(String.self, forKey: .pushLevel)
        pushTypes       = (try? c.decode([PushType].self, forKey: .pushTypes)) ?? []
        notifTypes      = (try? c.decode([NotifType].self, forKey: .notifTypes)) ?? []
        pushPrompted    = (try? c.decode(Bool.self, forKey: .pushPrompted)) ?? false
        isAdmin         = (try? c.decode(Bool.self, forKey: .isAdmin)) ?? false
        betaTester      = (try? c.decode(Bool.self, forKey: .betaTester)) ?? false
        willingToHelp   = (try? c.decode(Bool.self, forKey: .willingToHelp)) ?? false
        introSeen       = (try? c.decode(Bool.self, forKey: .introSeen)) ?? false
        createdAt       = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }
}

// MARK: - Sign-In Log Entry

struct SignInEntry: Codable, Identifiable {
    let id: UUID
    let userId: UUID
    let email: String
    let ipAddress: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case email
        case ipAddress = "ip_address"
        case createdAt = "created_at"
    }
}
