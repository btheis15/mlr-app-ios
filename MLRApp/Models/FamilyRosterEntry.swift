import Foundation

// MARK: - Family roster (migration 0123)
//
// A master list of family members who are NOT on the app yet (name + email +
// phone + optional house). Email is the join key: when someone verifies with a
// matching email their roster slot auto-links to the new account (server
// trigger). Enables emailing an entire house — including not-yet-signed-up
// people — plus the widened People email pools. Mirrors lib/familyRoster.ts.

struct FamilyRosterEntry: Identifiable, Equatable {
    let id: UUID
    var name: String
    var email: String?
    var phone: String?
    var houseId: UUID?
    var position: Int
    /// The claimed account, once someone verifies with this slot's email.
    var linkedUserId: UUID?
    var linkedName: String?
    var linkedAvatarUrl: String?

    /// Whether a real account has claimed this slot.
    var isLinked: Bool { linkedUserId != nil }
    var displayName: String { (linkedName?.isEmpty == false ? linkedName : nil) ?? name }
}

// MARK: - Email recipient (gated recipient RPCs, migrations 0028/0123/0124)

/// A person we can email: id, display name, best email, and (for committee
/// pools) the roles they hold — so the By-Role filter lights up.
struct EmailRecipient: Identifiable, Equatable {
    let id: UUID
    let name: String
    let email: String
    var areas: [String] = []
}
