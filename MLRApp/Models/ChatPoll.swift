import Foundation

// MARK: - Chat quick-poll models (migration 0149)
//
// "Quick polls" any member can drop into a committee/house chat room: a
// question, 2–10 options (single- or multi-select), an optional write-in
// "Other", and anonymous (counts only) or attributed (counts + who picked
// what) results. Mirrors the web lib/chatPolls.ts seam. Distinct from the
// resort-wide family Poll (migration 0084) in Poll.swift.

/// Which room a poll lives in — drives both the fetch filter and create args.
enum ChatPollScope: Equatable {
    case committee(committeeId: UUID, slug: String, area: String?)
    case house(houseId: UUID, slug: String)
}

struct ChatPollOption: Identifiable, Decodable, Hashable {
    let id: UUID
    let label: String
    let position: Int
    let isOther: Bool
    let voteCount: Int

    enum CodingKeys: String, CodingKey {
        case id, label, position
        case isOther   = "is_other"
        case voteCount = "vote_count"
    }
}

struct ChatPoll: Identifiable, Decodable {
    let id: UUID
    let question: String
    let allowMultiple: Bool
    let anonymous: Bool
    let allowOther: Bool
    let createdBy: UUID?
    let createdByMe: Bool
    let createdAt: Date
    let closesOn: String?          // date-only, kept as a string like the web
    let isClosed: Bool
    let respondentCount: Int
    let options: [ChatPollOption]
    /// My own selected option ids — safe to read (it's the caller's own vote).
    let myOptionIds: [UUID]
    let myOtherText: String?

    enum CodingKeys: String, CodingKey {
        case id, question, anonymous, options
        case allowMultiple   = "allow_multiple"
        case allowOther      = "allow_other"
        case createdBy       = "created_by"
        case createdByMe     = "created_by_me"
        case createdAt       = "created_at"
        case closesOn        = "closes_on"
        case isClosed        = "is_closed"
        case respondentCount = "respondent_count"
        case myOptionIds     = "my_option_ids"
        case myOtherText     = "my_other_text"
    }

    var sortedOptions: [ChatPollOption] { options.sorted { $0.position < $1.position } }
    /// Did I vote in this poll at all?
    var iVoted: Bool { !myOptionIds.isEmpty }
    /// Total votes cast across options (may exceed respondentCount for multi-select).
    var totalVotes: Int { options.reduce(0) { $0 + $1.voteCount } }
}

/// Per-voter identity for a poll's results — only ever populated when the poll
/// isn't anonymous (enforced server-side, not just here).
struct ChatPollVoter: Identifiable, Decodable {
    let optionId: UUID
    let userId: UUID
    let name: String
    let avatarUrl: String?
    let otherText: String?

    var id: String { "\(optionId.uuidString)-\(userId.uuidString)" }

    enum CodingKeys: String, CodingKey {
        case optionId  = "option_id"
        case userId    = "user_id"
        case name
        case avatarUrl = "avatar_url"
        case otherText = "other_text"
    }
}
