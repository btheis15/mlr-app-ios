import Foundation

// MARK: - Tournament models (migrations 0144–0154)
//
// A tournament hangs off a Family Fest schedule activity OR a member-made private
// activity (migration 0150). Three formats: single-elimination bracket,
// round-robin, and pools→bracket. Mirrors lib/tournaments.ts. Reads decode a raw
// row (with embedded entrants/matches/participants) then assemble() links
// participants onto their entrants.

enum TournamentFormat: String, Codable { case single_elim, round_robin, pools_bracket
    var label: String {
        switch self {
        case .single_elim:   return "Bracket"
        case .round_robin:   return "Round-robin"
        case .pools_bracket: return "Pools → bracket"
        }
    }
}
enum EntrantType: String, Codable { case individual, team }
enum ByeStrategy: String, Codable { case byes, play_in }
enum TournamentStatus: String, Codable { case setup, live, complete }
enum MatchStatus: String, Codable { case pending, ready, in_progress, complete }
enum MatchStage: String, Codable { case pool, bracket }

/// Where a tournament hangs.
enum TournamentHost: Equatable {
    case schedule(id: UUID)
    case activity(id: UUID)
}

struct TournamentParticipant: Identifiable, Decodable, Hashable {
    let id: UUID
    let entrantId: UUID?
    let userId: UUID?
    let name: String
    let position: Int
    enum CodingKeys: String, CodingKey {
        case id, name, position
        case entrantId = "entrant_id"
        case userId    = "user_id"
    }
}

struct TournamentEntrant: Identifiable, Hashable {
    let id: UUID
    let seed: Int?
    let displayName: String
    let teamName: String?
    let pool: String?
    let position: Int
    let withdrawnAt: Date?
    var members: [TournamentParticipant]
}

struct TournamentMatch: Identifiable, Decodable, Hashable {
    let id: UUID
    let stage: MatchStage
    let pool: String?
    let round: Int
    let position: Int
    let slot1EntrantId: UUID?
    let slot2EntrantId: UUID?
    let slot1Score: Int?
    let slot2Score: Int?
    let winnerEntrantId: UUID?
    let nextMatchId: UUID?
    let nextSlot: Int?
    let isPlayIn: Bool
    let status: MatchStatus
    let scheduledAt: Date?
    let reminderMinutes: [Int]?

    enum CodingKeys: String, CodingKey {
        case id, stage, pool, round, position, status
        case slot1EntrantId  = "slot1_entrant_id"
        case slot2EntrantId  = "slot2_entrant_id"
        case slot1Score      = "slot1_score"
        case slot2Score      = "slot2_score"
        case winnerEntrantId = "winner_entrant_id"
        case nextMatchId     = "next_match_id"
        case nextSlot        = "next_slot"
        case isPlayIn        = "is_play_in"
        case scheduledAt     = "scheduled_at"
        case reminderMinutes = "reminder_minutes"
    }
}

struct Tournament: Identifiable {
    let id: UUID
    let scheduleItemId: UUID?
    let privateActivityId: UUID?
    let title: String
    let format: TournamentFormat
    let entrantType: EntrantType
    let teamSize: Int?
    let byeStrategy: ByeStrategy
    let poolCount: Int?
    let advancePerPool: Int?
    let tiebreakers: [String]
    let targetScore: Int?
    let winBy: Int?
    let allowTies: Bool
    let status: TournamentStatus
    let createdBy: UUID?
    let winnerEntrantId: UUID?
    var entrants: [TournamentEntrant]
    var pool: [TournamentParticipant]     // sign-ups not yet on an entrant
    var matches: [TournamentMatch]

    func entrantName(_ id: UUID?) -> String {
        guard let id, let e = entrants.first(where: { $0.id == id }) else { return "—" }
        return e.displayName
    }

    var hasAnyScores: Bool { matches.contains { $0.slot1Score != nil || $0.slot2Score != nil } }
    var poolLabels: [String] { Set(entrants.compactMap { $0.pool }).sorted() }
    var hasKnockoutBracket: Bool { matches.contains { $0.stage == .bracket } }
    var poolStageComplete: Bool {
        let pool = matches.filter { $0.stage == .pool }
        return !pool.isEmpty && pool.allSatisfy { $0.status == .complete }
    }
    var bracketMatches: [TournamentMatch] { matches.filter { $0.stage == .bracket }.sorted { $0.round == $1.round ? $0.position < $1.position : $0.round < $1.round } }
    var maxRound: Int { bracketMatches.map(\.round).max() ?? 0 }
}

// MARK: - Bracket math (mirrors lib/tournaments.ts)

enum BracketMath {
    /// Next power of two ≥ n (the bracket draw size).
    static func bracketSize(_ n: Int) -> Int {
        if n < 2 { return n }
        var b = 1
        while b < n { b *= 2 }
        return b
    }
    /// Byes needed = bracketSize − n.
    static func byeCount(_ n: Int) -> Int { max(0, bracketSize(n) - n) }
    /// Largest power of two ≤ n (clean main-draw size for play-in framing).
    static func lowerPow2(_ n: Int) -> Int {
        if n < 1 { return 0 }
        var b = 1
        while b * 2 <= n { b *= 2 }
        return b
    }
    /// Standard fold-seed slot order for a size bracket (entry p = seed in slot p).
    static func seedOrder(_ size: Int) -> [Int] {
        if size <= 1 { return [1] }
        var arr = [1, 2]; var sz = 2
        while sz < size {
            var next: [Int] = []
            for s in arr { next.append(s); next.append(2 * sz + 1 - s) }
            arr = next; sz *= 2
        }
        return arr
    }
    /// One-line human summary of the bracket shape.
    static func bracketSummary(_ n: Int, _ strategy: ByeStrategy) -> String {
        if n < 2 { return "Need at least 2 entrants" }
        let b = bracketSize(n), byes = byeCount(n), games = n - lowerPow2(n)
        if byes == 0 { return "\(n) entrants · \(b)-team bracket · no byes" }
        if strategy == .play_in {
            return "\(n) entrants · \(games) play-in game\(games == 1 ? "" : "s") → clean \(lowerPow2(n))-team draw"
        }
        return "\(n) entrants · \(b)-team bracket · \(byes) bye\(byes == 1 ? "" : "s") (top seeds rest)"
    }
    /// First-round matchups (name pairs) for the setup preview, in seed order.
    static func firstRoundPreview(_ names: [String], _ strategy: ByeStrategy) -> [(a: String?, b: String?, isBye: Bool)] {
        let n = names.count
        if n < 2 { return [] }
        let b = bracketSize(n), order = seedOrder(b)
        var out: [(String?, String?, Bool)] = []
        for i in 0..<(b / 2) {
            let s1 = order[2 * i], s2 = order[2 * i + 1]
            let a = s1 <= n ? names[s1 - 1] : nil
            let bb = s2 <= n ? names[s2 - 1] : nil
            out.append((a, bb, a == nil || bb == nil))
        }
        return out
    }
}

// MARK: - Standings

struct Standing: Identifiable {
    let entrantId: UUID
    let name: String
    var played = 0, wins = 0, losses = 0, ties = 0
    var pointsFor = 0, pointsAgainst = 0
    var diff: Int { pointsFor - pointsAgainst }
    var rank = 0
    var id: UUID { entrantId }
    var record: String { ties > 0 ? "\(wins)-\(losses)-\(ties)" : "\(wins)-\(losses)" }
}

extension Tournament {
    /// Round-robin / pool standings. Ranked by win% then point differential then
    /// points-for then seed (a faithful subset of the web's configurable
    /// tiebreakers; head-to-head config is a deferred nicety).
    func standings(pool: String? = nil) -> [Standing] {
        let field = entrants.filter { $0.withdrawnAt == nil && (pool == nil || $0.pool == pool) }
        let ids = Set(field.map(\.id))
        var rows: [UUID: Standing] = [:]
        for e in field { rows[e.id] = Standing(entrantId: e.id, name: e.displayName) }
        let done = matches.filter { m in
            guard m.status == .complete, let a = m.slot1EntrantId, let b = m.slot2EntrantId else { return false }
            return ids.contains(a) && ids.contains(b)
        }
        for m in done {
            guard let aId = m.slot1EntrantId, let bId = m.slot2EntrantId else { continue }
            let s1 = m.slot1Score ?? 0, s2 = m.slot2Score ?? 0
            rows[aId]?.played += 1; rows[bId]?.played += 1
            rows[aId]?.pointsFor += s1; rows[aId]?.pointsAgainst += s2
            rows[bId]?.pointsFor += s2; rows[bId]?.pointsAgainst += s1
            if m.winnerEntrantId == nil {
                rows[aId]?.ties += 1; rows[bId]?.ties += 1
            } else if m.winnerEntrantId == aId {
                rows[aId]?.wins += 1; rows[bId]?.losses += 1
            } else {
                rows[bId]?.wins += 1; rows[aId]?.losses += 1
            }
        }
        func winPct(_ r: Standing) -> Double { r.played == 0 ? 0 : (Double(r.wins) + 0.5 * Double(r.ties)) / Double(r.played) }
        func seed(_ id: UUID) -> Int { entrants.first { $0.id == id }?.seed ?? entrants.first { $0.id == id }?.position ?? 1_000_000 }
        var sorted = Array(rows.values).sorted { x, y in
            if winPct(x) != winPct(y) { return winPct(x) > winPct(y) }
            if x.diff != y.diff { return x.diff > y.diff }
            if x.pointsFor != y.pointsFor { return x.pointsFor > y.pointsFor }
            return seed(x.entrantId) < seed(y.entrantId)
        }
        for i in sorted.indices { sorted[i].rank = i + 1 }
        return sorted
    }
}
