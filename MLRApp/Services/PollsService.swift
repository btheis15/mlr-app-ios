import Foundation
import Supabase

// MARK: - PollsService (migration 0084)
// Fetches and mutates polls, options, and votes. Mirrors web poll RPCs:
// create_poll, cast_poll_vote, close_poll, delete_poll.

@Observable
@MainActor
final class PollsService {
    var polls: [Poll] = []
    var isLoading = false

    // MARK: - Fetch

    func fetchPolls(userId: UUID?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let rows: [PollRow] = try await supabase
                .from("polls")
                .select("*, poll_options(id, label, position)")
                .order("created_at", ascending: false)
                .execute()
                .value

            // Fetch all votes in one query — small dataset for a family resort.
            let allVotes: [VoteRow] = (try? await supabase
                .from("poll_votes")
                .select("poll_id, option_id, user_id")
                .execute()
                .value) ?? []

            var voteCounts: [UUID: Int] = [:]
            var myVotes: [UUID: UUID] = [:]  // pollId → optionId
            for v in allVotes {
                voteCounts[v.optionId, default: 0] += 1
                if let uid = userId, v.userId == uid { myVotes[v.pollId] = v.optionId }
            }

            polls = rows.map { row in
                Poll(
                    id: row.id,
                    question: row.question,
                    createdBy: row.createdBy,
                    createdAt: row.createdAt,
                    closesOn: row.closesOn,
                    isClosed: row.isClosed,
                    options: row.pollOptions
                        .sorted { $0.position < $1.position }
                        .map { opt in
                            PollOption(
                                id: opt.id,
                                label: opt.label,
                                position: opt.position,
                                voteCount: voteCounts[opt.id] ?? 0
                            )
                        },
                    myVoteOptionId: myVotes[row.id]
                )
            }
        } catch {
            print("[PollsService] fetchPolls error: \(error)")
        }
    }

    // MARK: - Vote

    func vote(pollId: UUID, optionId: UUID) async throws {
        struct VoteParams: Encodable { let p_poll: String; let p_option: String }
        try await supabase
            .rpc("cast_poll_vote", params: VoteParams(p_poll: pollId.uuidString, p_option: optionId.uuidString))
            .execute()
        // Optimistic update
        guard let idx = polls.firstIndex(where: { $0.id == pollId }) else { return }
        let prev = polls[idx].myVoteOptionId
        if let prev, let prevIdx = polls[idx].options.firstIndex(where: { $0.id == prev }) {
            polls[idx].options[prevIdx].voteCount = max(0, polls[idx].options[prevIdx].voteCount - 1)
        }
        if let newIdx = polls[idx].options.firstIndex(where: { $0.id == optionId }) {
            polls[idx].options[newIdx].voteCount += 1
        }
        polls[idx].myVoteOptionId = optionId
    }

    // MARK: - Create

    func createPoll(question: String, options: [String], closesOn: String?) async throws {
        struct CreateParams: Encodable {
            let p_question: String; let p_options: [String]; let p_closes_on: String?
        }
        try await supabase
            .rpc("create_poll", params: CreateParams(p_question: question, p_options: options, p_closes_on: closesOn))
            .execute()
    }

    // MARK: - Close

    func closePoll(pollId: UUID) async throws {
        struct CloseParams: Encodable { let p_poll: String }
        try await supabase
            .rpc("close_poll", params: CloseParams(p_poll: pollId.uuidString))
            .execute()
        if let idx = polls.firstIndex(where: { $0.id == pollId }) { polls[idx].isClosed = true }
    }

    // MARK: - Delete

    func deletePoll(pollId: UUID) async throws {
        struct DeleteParams: Encodable { let p_poll: String }
        try await supabase
            .rpc("delete_poll", params: DeleteParams(p_poll: pollId.uuidString))
            .execute()
        polls.removeAll { $0.id == pollId }
    }
}

// MARK: - Private row types

private struct PollRow: Decodable {
    let id: UUID
    let question: String
    let createdBy: UUID
    let createdAt: Date
    let closesOn: String?
    let isClosed: Bool
    let pollOptions: [PollOptionRow]

    enum CodingKeys: String, CodingKey {
        case id, question
        case createdBy   = "created_by"
        case createdAt   = "created_at"
        case closesOn    = "closes_on"
        case isClosed    = "is_closed"
        case pollOptions = "poll_options"
    }

    struct PollOptionRow: Decodable {
        let id: UUID; let label: String; let position: Int
    }
}

private struct VoteRow: Decodable {
    let pollId: UUID; let optionId: UUID; let userId: UUID
    enum CodingKeys: String, CodingKey {
        case pollId = "poll_id"; case optionId = "option_id"; case userId = "user_id"
    }
}
