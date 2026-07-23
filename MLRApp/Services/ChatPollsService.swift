import Foundation
import Supabase

// MARK: - ChatPollsService (migration 0149)
//
// Quick polls in committee/house chat rooms. Reads go through two SECURITY
// DEFINER RPCs (fetch_chat_polls_for_room + chat_poll_voters); writes through
// create_chat_poll / set_chat_poll_votes / close_chat_poll / delete_chat_poll.
// Everything degrades to safe no-ops / empty lists with no backend or before
// migration 0149 has run (the RPC simply doesn't exist yet). Mirrors
// lib/chatPolls.ts. RPC param names match the SQL exactly.

@Observable
@MainActor
final class ChatPollsService {

    /// Every poll in a room (newest first) with options/counts + my own votes.
    /// Empty on any failure (pre-migration, offline) — never throws.
    func fetchPolls(scope: ChatPollScope) async -> [ChatPoll] {
        do {
            return try await supabase
                .rpc("fetch_chat_polls_for_room", params: scopeParams(scope))
                .execute()
                .value
        } catch {
            return []
        }
    }

    /// Per-voter identity for a poll's results sheet — only populated when the
    /// poll isn't anonymous (server-enforced).
    func fetchVoters(pollId: UUID) async -> [ChatPollVoter] {
        struct P: Encodable { let p_poll: String }
        do {
            return try await supabase
                .rpc("chat_poll_voters", params: P(p_poll: pollId.uuidString))
                .execute()
                .value
        } catch {
            return []
        }
    }

    /// Start a poll — any room member. Returns the new poll id.
    @discardableResult
    func createPoll(
        scope: ChatPollScope,
        question: String,
        options: [String],
        allowMultiple: Bool,
        anonymous: Bool,
        allowOther: Bool,
        closesOn: String? = nil
    ) async throws -> UUID {
        var params = scopeParams(scope)
        params["p_question"] = .string(question)
        params["p_options"] = .array(options.map { AnyJSON.string($0) })
        params["p_allow_multiple"] = .bool(allowMultiple)
        params["p_anonymous"] = .bool(anonymous)
        params["p_allow_other"] = .bool(allowOther)
        params["p_closes_on"] = closesOn.map { AnyJSON.string($0) } ?? .null
        let id: UUID = try await supabase
            .rpc("create_chat_poll", params: params)
            .execute()
            .value
        return id
    }

    /// Set (or change/clear) my votes — full replace in one call. `otherText`
    /// is only used when the "Other" option id is included.
    func setVotes(pollId: UUID, optionIds: [UUID], otherText: String? = nil) async throws {
        let params: [String: AnyJSON] = [
            "p_poll":       .string(pollId.uuidString),
            "p_option_ids": .array(optionIds.map { AnyJSON.string($0.uuidString) }),
            "p_other_text": otherText.map { AnyJSON.string($0) } ?? .null,
        ]
        try await supabase.rpc("set_chat_poll_votes", params: params).execute()
    }

    /// Close a poll (freeze results) — its creator or an app admin.
    func closePoll(pollId: UUID) async throws {
        struct P: Encodable { let p_poll: String }
        try await supabase.rpc("close_chat_poll", params: P(p_poll: pollId.uuidString)).execute()
    }

    /// Delete a poll (options + votes cascade) — its creator or an app admin.
    func deletePoll(pollId: UUID) async throws {
        struct P: Encodable { let p_poll: String }
        try await supabase.rpc("delete_chat_poll", params: P(p_poll: pollId.uuidString)).execute()
    }

    // MARK: - Helpers

    private func scopeParams(_ scope: ChatPollScope) -> [String: AnyJSON] {
        switch scope {
        case let .committee(committeeId, _, area):
            return [
                "p_scope":        .string("committee"),
                "p_committee_id": .string(committeeId.uuidString),
                "p_area":         area.map { AnyJSON.string($0) } ?? .null,
                "p_house_id":     .null,
            ]
        case let .house(houseId, _):
            return [
                "p_scope":        .string("house"),
                "p_committee_id": .null,
                "p_area":         .null,
                "p_house_id":     .string(houseId.uuidString),
            ]
        }
    }
}
