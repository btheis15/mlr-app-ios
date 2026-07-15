import Foundation

// MARK: - Poll (migration 0084)
// Family-wide polls any signed-in member can create. Live vote counts shown to
// all members. Mirrors the polls / poll_options / poll_votes tables and the
// create_poll / cast_poll_vote / close_poll / delete_poll RPCs.

struct Poll: Identifiable, Equatable {
    let id: UUID
    var question: String
    var createdBy: UUID
    var createdAt: Date
    var closesOn: String?       // YYYY-MM-DD; nil = never auto-closes
    var isClosed: Bool
    var options: [PollOption]
    var myVoteOptionId: UUID?   // set when the signed-in user has voted

    var isOpen: Bool {
        guard !isClosed else { return false }
        guard let closesOn else { return true }
        return closesOn >= pollIsoToday()
    }

    var totalVotes: Int { options.reduce(0) { $0 + $1.voteCount } }

    func votePercent(for option: PollOption) -> Double {
        guard totalVotes > 0 else { return 0 }
        return Double(option.voteCount) / Double(totalVotes)
    }

    func closesInDays() -> Int? {
        guard let closesOn else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let closeDate = f.date(from: closesOn) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: closeDate).day ?? 0
        return max(0, days)
    }
}

struct PollOption: Identifiable, Equatable {
    let id: UUID
    var label: String
    var position: Int
    var voteCount: Int
}

private func pollIsoToday() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "America/Chicago")
    return f.string(from: Date())
}
