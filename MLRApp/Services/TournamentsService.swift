import Foundation
import Supabase

// MARK: - TournamentsService (migrations 0144–0154)
//
// Fetch + manage a tournament hanging off a Family Fest schedule activity or a
// private activity. Reads decode a raw row (embedded entrants/matches/
// participants) then assemble() links participants onto their entrants. Writes
// go through SECURITY DEFINER RPCs. Mirrors lib/tournaments.ts. Degrades to
// empty / thrown errors surfaced by callers.

@Observable
@MainActor
final class TournamentsService {

    /// Tournaments on a host (usually one), fully assembled.
    func fetch(host: TournamentHost) async -> [Tournament] {
        let (col, id): (String, UUID) = {
            switch host {
            case .schedule(let i): return ("schedule_item_id", i)
            case .activity(let i): return ("private_activity_id", i)
            }
        }()
        do {
            let rows: [RawTournamentRow] = try await supabase
                .from("tournaments")
                .select("*, tournament_entrants!tournament_entrants_tournament_id_fkey(*), tournament_matches(*), tournament_participants(*)")
                .eq(col, value: id.uuidString)
                .execute()
                .value
            return rows.map { $0.assembled }
        } catch {
            return []
        }
    }

    // MARK: Setup

    @discardableResult
    func createForHost(_ host: TournamentHost, title: String, format: TournamentFormat,
                       entrantType: EntrantType = .individual, teamSize: Int? = nil) async throws -> UUID {
        var params: [String: AnyJSON] = [
            "p_title":        .string(title),
            "p_format":       .string(format.rawValue),
            "p_entrant_type": .string(entrantType.rawValue),
            "p_team_size":    teamSize.map { AnyJSON.double(Double($0)) } ?? .null,
            "p_bye_strategy": .string("byes"),
        ]
        let rpc: String
        switch host {
        case .schedule(let i): rpc = "create_tournament";          params["p_item"] = .string(i.uuidString)
        case .activity(let i): rpc = "create_activity_tournament";  params["p_activity"] = .string(i.uuidString)
        }
        return try await supabase.rpc(rpc, params: params).execute().value
    }

    @discardableResult
    func importEntrants(host: TournamentHost, tournamentId: UUID) async throws -> Int {
        let rpc = { switch host { case .schedule: return "import_entrants_from_signups"; case .activity: return "import_entrants_from_activity_members" } }()
        struct P: Encodable { let p_tournament: String }
        let n: Int = try await supabase.rpc(rpc, params: P(p_tournament: tournamentId.uuidString)).execute().value
        return n
    }

    func setFormat(id: UUID, format: TournamentFormat) async throws {
        struct P: Encodable { let p_tournament: String; let p_format: String }
        try await supabase.rpc("set_tournament_format", params: P(p_tournament: id.uuidString, p_format: format.rawValue)).execute()
    }

    func generateBracket(id: UUID) async throws { try await gen("generate_bracket", id) }
    func generateRoundRobin(id: UUID) async throws { try await gen("generate_round_robin", id) }
    func generateBracketFromPools(id: UUID) async throws { try await gen("generate_bracket_from_pools", id) }
    func resetBracket(id: UUID) async throws { try await gen("reset_bracket", id) }

    func generatePools(id: UUID, poolCount: Int, advance: Int) async throws {
        let params: [String: AnyJSON] = [
            "p_tournament": .string(id.uuidString),
            "p_pool_count": .double(Double(poolCount)),
            "p_advance":    .double(Double(advance)),
            "p_seed_order": .null,
        ]
        try await supabase.rpc("generate_pools", params: params).execute()
    }

    private func gen(_ rpc: String, _ id: UUID) async throws {
        let params: [String: AnyJSON] = ["p_tournament": .string(id.uuidString), "p_seed_order": .null]
        // reset/from-pools take only p_tournament; the extra key is ignored by PG functions
        // that don't declare it — so send the minimal shape instead.
        if rpc == "reset_bracket" || rpc == "generate_bracket_from_pools" {
            struct P: Encodable { let p_tournament: String }
            try await supabase.rpc(rpc, params: P(p_tournament: id.uuidString)).execute()
        } else {
            try await supabase.rpc(rpc, params: params).execute()
        }
    }

    func delete(id: UUID) async throws {
        struct P: Encodable { let p_tournament: String }
        try await supabase.rpc("delete_tournament", params: P(p_tournament: id.uuidString)).execute()
    }

    // MARK: Results

    func recordResult(matchId: UUID, winnerId: UUID, score1: Int?, score2: Int?) async throws {
        let params: [String: AnyJSON] = [
            "p_match":  .string(matchId.uuidString),
            "p_winner": .string(winnerId.uuidString),
            "p_score1": score1.map { AnyJSON.double(Double($0)) } ?? .null,
            "p_score2": score2.map { AnyJSON.double(Double($0)) } ?? .null,
        ]
        try await supabase.rpc("record_match_result", params: params).execute()
    }

    func clearResult(matchId: UUID) async throws {
        struct P: Encodable { let p_match: String }
        try await supabase.rpc("clear_match_result", params: P(p_match: matchId.uuidString)).execute()
    }

    // MARK: Scheduling + notify

    /// Set (or clear, with nil) a match's scheduled time + reminder lead-times.
    func scheduleMatch(matchId: UUID, at: Date?, reminderMinutes: [Int] = []) async throws {
        let params: [String: AnyJSON] = [
            "p_match":     .string(matchId.uuidString),
            "p_at":        at.map { AnyJSON.string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "p_reminders": .array(reminderMinutes.map { AnyJSON.double(Double($0)) }),
        ]
        try await supabase.rpc("schedule_match", params: params).execute()
    }

    /// Send an immediate matchup push to the two players. `when` is the trailing
    /// phrase, e.g. "is up next!" or "is in about 15 minutes".
    func notifyMatch(matchId: UUID, when: String) async throws {
        struct P: Encodable { let p_match: String; let p_when: String }
        try await supabase.rpc("notify_match", params: P(p_match: matchId.uuidString, p_when: when)).execute()
    }
}

// MARK: - Raw row decode + assembly

private struct RawTournamentRow: Decodable {
    let id: UUID
    let schedule_item_id: UUID?
    let private_activity_id: UUID?
    let title: String
    let format: TournamentFormat
    let entrant_type: EntrantType
    let team_size: Int?
    let bye_strategy: ByeStrategy
    let pool_count: Int?
    let advance_per_pool: Int?
    let tiebreakers: [String]?
    let target_score: Int?
    let win_by: Int?
    let allow_ties: Bool
    let status: TournamentStatus
    let created_by: UUID?
    let winner_entrant_id: UUID?
    let tournament_entrants: [EntrantRow]?
    let tournament_matches: [TournamentMatch]?
    let tournament_participants: [TournamentParticipant]?

    struct EntrantRow: Decodable {
        let id: UUID
        let seed: Int?
        let display_name: String
        let team_name: String?
        let pool: String?
        let position: Int
        let withdrawn_at: Date?
    }

    var assembled: Tournament {
        let parts = tournament_participants ?? []
        var byEntrant: [UUID: [TournamentParticipant]] = [:]
        var loose: [TournamentParticipant] = []
        for p in parts {
            if let eid = p.entrantId { byEntrant[eid, default: []].append(p) } else { loose.append(p) }
        }
        let entrants = (tournament_entrants ?? [])
            .map { e in
                TournamentEntrant(
                    id: e.id, seed: e.seed, displayName: e.display_name, teamName: e.team_name,
                    pool: e.pool, position: e.position, withdrawnAt: e.withdrawn_at,
                    members: (byEntrant[e.id] ?? []).sorted { $0.position < $1.position })
            }
            .sorted { ($0.seed ?? 1_000_000, $0.position) < ($1.seed ?? 1_000_000, $1.position) }
        let matches = (tournament_matches ?? []).sorted { $0.round == $1.round ? $0.position < $1.position : $0.round < $1.round }
        return Tournament(
            id: id, scheduleItemId: schedule_item_id, privateActivityId: private_activity_id,
            title: title, format: format, entrantType: entrant_type, teamSize: team_size,
            byeStrategy: bye_strategy, poolCount: pool_count, advancePerPool: advance_per_pool,
            tiebreakers: tiebreakers ?? [], targetScore: target_score, winBy: win_by,
            allowTies: allow_ties, status: status, createdBy: created_by,
            winnerEntrantId: winner_entrant_id, entrants: entrants,
            pool: loose.sorted { $0.position < $1.position }, matches: matches)
    }
}
