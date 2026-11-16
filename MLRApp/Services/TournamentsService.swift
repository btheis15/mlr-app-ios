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

    /// Tournaments on a host (usually one), fully assembled. THROWS on any
    /// failure, so a caller can tell "the fetch failed" from "there is no
    /// tournament". Never treat a thrown error as an empty list.
    func fetchChecked(host: TournamentHost) async throws -> [Tournament] {
        let (col, id): (String, UUID) = {
            switch host {
            case .schedule(let i): return ("schedule_item_id", i)
            case .activity(let i): return ("private_activity_id", i)
            }
        }()
        let rows: [RawTournamentRow] = try await supabase
            .from("tournaments")
            .select("*, tournament_entrants!tournament_entrants_tournament_id_fkey(*), tournament_matches(*), tournament_participants(*)")
            .eq(col, value: id.uuidString)
            .execute()
            .value
        return rows.map { $0.assembled }
    }

    /// Read-only history callers (the Past Years archive) that can tolerate a
    /// failed fetch looking empty. Anything that can show a "set up" state or
    /// write must use `fetchChecked` instead.
    func fetch(host: TournamentHost) async -> [Tournament] {
        (try? await fetchChecked(host: host)) ?? []
    }

    /// One match, fresh from the server (to catch a result someone else saved).
    func fetchMatch(id: UUID) async throws -> TournamentMatch? {
        let rows: [TournamentMatch] = try await supabase
            .from("tournament_matches").select("*")
            .eq("id", value: id.uuidString).limit(1)
            .execute().value
        return rows.first
    }

    /// The server's own exception text is written to be read by people
    /// (migration 0224), so show it instead of a generic failure.
    static func message(for error: Error, fallback: String = "Something went wrong. Try again.") -> String {
        if let e = error as? PostgrestError {
            let m = e.message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !m.isEmpty { return m }
        }
        return fallback
    }

    // MARK: Snapshots (migration 0224)

    /// Saved copies of a tournament, newest first. Returns nil when the feature
    /// is not available (table missing: 42P01, or PostgREST's schema-cache
    /// PGRST205), so the UI hides itself. `data` is never selected.
    func fetchSnapshots(tournamentId: UUID) async throws -> [TournamentSnapshot]? {
        do {
            let rows: [TournamentSnapshot] = try await supabase
                .from("tournament_snapshots")
                .select("id, tournament_id, reason, taken_by, taken_at, played_matches")
                .eq("tournament_id", value: tournamentId.uuidString)
                .order("taken_at", ascending: false)
                .limit(30)
                .execute().value
            return rows
        } catch let e as PostgrestError where e.code == "42P01" || e.code == "PGRST205" {
            return nil
        }
    }

    func restoreSnapshot(id: UUID) async throws {
        struct P: Encodable { let p_snapshot: String }
        try await supabase.rpc("restore_tournament_snapshot", params: P(p_snapshot: id.uuidString)).execute()
    }

    // MARK: Realtime (tournaments, matches, entrants)

    private var channels: [UUID: RealtimeChannelV2] = [:]
    private var debounce: [UUID: Task<Void, Never>] = [:]

    /// Subscribe to changes on one tournament. Bursts (a reset rewrites many
    /// rows) collapse into a single `onChange` ~0.6s after the last event.
    func subscribe(tournamentId: UUID, onChange: @escaping @MainActor () -> Void) {
        guard channels[tournamentId] == nil else { return }
        let channel = supabase.channel("tournament-\(tournamentId.uuidString)")
        channels[tournamentId] = channel
        let fire: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.debounce[tournamentId]?.cancel()
                self.debounce[tournamentId] = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    onChange()
                }
            }
        }
        Task {
            channel.onPostgresChange(AnyAction.self, schema: "public", table: "tournaments",
                                     filter: "id=eq.\(tournamentId.uuidString)") { _ in fire() }
            for table in ["tournament_matches", "tournament_entrants"] {
                channel.onPostgresChange(AnyAction.self, schema: "public", table: table,
                                         filter: "tournament_id=eq.\(tournamentId.uuidString)") { _ in fire() }
            }
            await channel.subscribe()
        }
    }

    func unsubscribe(tournamentId: UUID) {
        debounce[tournamentId]?.cancel()
        debounce.removeValue(forKey: tournamentId)
        guard let channel = channels.removeValue(forKey: tournamentId) else { return }
        Task { await supabase.removeChannel(channel) }
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

    /// Web's add_entrant(p_tournament, p_team_name, p_members) -> new entrant id.
    /// Each member is {for_user, name}: a member uuid or a free-text guest name.
    func addEntrant(tournamentId: UUID, teamName: String?, members: [(forUser: UUID?, name: String?)]) async throws -> UUID {
        struct M: Encodable { let for_user: String?; let name: String? }
        struct P: Encodable { let p_tournament: String; let p_team_name: String?; let p_members: [M] }
        let p = P(p_tournament: tournamentId.uuidString, p_team_name: teamName,
                  p_members: members.map { M(for_user: $0.forUser?.uuidString, name: $0.name) })
        return try await supabase.rpc("add_entrant", params: p).execute().value
    }

    @discardableResult
    func importEntrants(host: TournamentHost, tournamentId: UUID) async throws -> Int {
        let rpc = { switch host { case .schedule: return "import_entrants_from_signups"; case .activity: return "import_entrants_from_activity_members" } }()
        struct P: Encodable { let p_tournament: String }
        let n: Int = try await supabase.rpc(rpc, params: P(p_tournament: tournamentId.uuidString)).execute().value
        return n
    }

    /// Auto-group the imported players into fixed-size teams (team tournaments).
    @discardableResult
    func generateTeams(id: UUID) async throws -> Int {
        struct P: Encodable { let p_tournament: String }
        struct R: Decodable { let teams_created: Int? }
        // The RPC returns a row {teams_created, leftover}; we only surface the count.
        let r: R = try await supabase.rpc("generate_teams", params: P(p_tournament: id.uuidString)).execute().value
        return r.teams_created ?? 0
    }

    func ungroupTeams(id: UUID) async throws {
        struct P: Encodable { let p_tournament: String }
        try await supabase.rpc("ungroup_teams", params: P(p_tournament: id.uuidString)).execute()
    }

    func setFormat(id: UUID, format: TournamentFormat) async throws {
        struct P: Encodable { let p_tournament: String; let p_format: String }
        try await supabase.rpc("set_tournament_format", params: P(p_tournament: id.uuidString, p_format: format.rawValue)).execute()
    }

    /// `seedOrder` (entrant ids, top seed first) hand-sets the bracket seeding;
    /// nil lets the server seed by its own order.
    func generateBracket(id: UUID, seedOrder: [UUID]? = nil) async throws { try await gen("generate_bracket", id, seedOrder) }
    func generateRoundRobin(id: UUID, seedOrder: [UUID]? = nil) async throws { try await gen("generate_round_robin", id, seedOrder) }
    func generateBracketFromPools(id: UUID) async throws {
        struct P: Encodable { let p_tournament: String }
        try await supabase.rpc("generate_bracket_from_pools", params: P(p_tournament: id.uuidString)).execute()
    }
    /// `confirm` is sent only when true: omitting the key keeps the call valid on
    /// a server that has not got migration 0224's `p_confirm` argument yet.
    func resetBracket(id: UUID, confirm: Bool = false) async throws {
        var params: [String: AnyJSON] = ["p_tournament": .string(id.uuidString)]
        if confirm { params["p_confirm"] = .bool(true) }
        try await supabase.rpc("reset_bracket", params: params).execute()
    }

    func generatePools(id: UUID, poolCount: Int, advance: Int, seedOrder: [UUID]? = nil) async throws {
        let params: [String: AnyJSON] = [
            "p_tournament": .string(id.uuidString),
            "p_pool_count": .double(Double(poolCount)),
            "p_advance":    .double(Double(advance)),
            "p_seed_order": seedJSON(seedOrder),
        ]
        try await supabase.rpc("generate_pools", params: params).execute()
    }

    private func gen(_ rpc: String, _ id: UUID, _ seedOrder: [UUID]?) async throws {
        let params: [String: AnyJSON] = ["p_tournament": .string(id.uuidString), "p_seed_order": seedJSON(seedOrder)]
        try await supabase.rpc(rpc, params: params).execute()
    }

    private func seedJSON(_ ids: [UUID]?) -> AnyJSON {
        guard let ids, !ids.isEmpty else { return .null }
        return .array(ids.map { AnyJSON.string($0.uuidString) })
    }

    // MARK: Entrant / participant / seeding management

    @discardableResult
    func addParticipant(id: UUID, forUser: UUID?, name: String?) async throws -> UUID {
        let params: [String: AnyJSON] = [
            "p_tournament": .string(id.uuidString),
            "p_for_user":   forUser.map { AnyJSON.string($0.uuidString) } ?? .null,
            "p_name":       name.map { AnyJSON.string($0) } ?? .null,
        ]
        return try await supabase.rpc("add_participant", params: params).execute().value
    }
    func removeParticipant(participantId: UUID) async throws {
        struct P: Encodable { let p_participant: String }
        try await supabase.rpc("remove_participant", params: P(p_participant: participantId.uuidString)).execute()
    }
    func removeEntrant(entrantId: UUID) async throws {
        struct P: Encodable { let p_entrant: String }
        try await supabase.rpc("remove_entrant", params: P(p_entrant: entrantId.uuidString)).execute()
    }
    func setByeStrategy(id: UUID, strategy: ByeStrategy) async throws {
        // update_tournament takes the full param set; send nulls for the rest.
        let params: [String: AnyJSON] = [
            "p_tournament":   .string(id.uuidString),
            "p_title":        .null,
            "p_bye_strategy": .string(strategy.rawValue),
            "p_allow_ties":   .null,
            "p_target_score": .null,
            "p_win_by":       .null,
        ]
        try await supabase.rpc("update_tournament", params: params).execute()
    }

    /// Target score / win-by through the same update_tournament RPC (nulls leave a
    /// field unchanged server-side, so this can set but not clear).
    func setScoring(id: UUID, targetScore: Int?, winBy: Int?) async throws {
        let params: [String: AnyJSON] = [
            "p_tournament":   .string(id.uuidString),
            "p_title":        .null,
            "p_bye_strategy": .null,
            "p_allow_ties":   .null,
            "p_target_score": targetScore.map { AnyJSON.double(Double($0)) } ?? .null,
            "p_win_by":       winBy.map { AnyJSON.double(Double($0)) } ?? .null,
        ]
        try await supabase.rpc("update_tournament", params: params).execute()
    }

    // MARK: Live bracket rearrange (tap-to-swap)

    func setMatchEntrant(matchId: UUID, slot: Int, entrantId: UUID?, force: Bool = false) async throws {
        var params: [String: AnyJSON] = [
            "p_match":      .string(matchId.uuidString),
            "p_slot":       .double(Double(slot)),
            "p_entrant_id": entrantId.map { AnyJSON.string($0.uuidString) } ?? .null,
        ]
        if force { params["p_force"] = .bool(true) }
        try await supabase.rpc("set_match_entrant", params: params).execute()
    }
    func swapMatchEntrants(matchA: UUID, slotA: Int, matchB: UUID, slotB: Int, force: Bool = false) async throws {
        var params: [String: AnyJSON] = [
            "p_match_a": .string(matchA.uuidString), "p_slot_a": .double(Double(slotA)),
            "p_match_b": .string(matchB.uuidString), "p_slot_b": .double(Double(slotB)),
        ]
        if force { params["p_force"] = .bool(true) }
        try await supabase.rpc("swap_match_entrants", params: params).execute()
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
            .sorted {
                // Seed (nulls last), then position, then id: a refetch can never reorder the screen.
                let s0 = $0.seed ?? Int.max, s1 = $1.seed ?? Int.max
                if s0 != s1 { return s0 < s1 }
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id.uuidString < $1.id.uuidString
            }
        let matches = (tournament_matches ?? []).sorted(by: TournamentMatch.inOrder)
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
