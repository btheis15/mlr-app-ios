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

struct TournamentSnapshot: Identifiable, Decodable, Hashable {
    let id: UUID
    let tournamentId: UUID
    let reason: String
    let takenBy: UUID?
    let takenAt: Date
    let playedMatches: Int
    enum CodingKeys: String, CodingKey {
        case id, reason
        case tournamentId  = "tournament_id"
        case takenBy       = "taken_by"
        case takenAt       = "taken_at"
        case playedMatches = "played_matches"
    }
    /// Plain-language reason (the server stores a short code-ish phrase).
    var reasonLabel: String {
        switch reason {
        case "start over":                return "Before starting over"
        case "rearranged after results":  return "Before rearranging"
        case "before restore":            return "Before a restore"
        case "tournament deleted":        return "Tournament deleted"
        case "game deleted":              return "Activity deleted"
        default:                          return reason.prefix(1).uppercased() + reason.dropFirst()
        }
    }
}

extension TournamentMatch {
    /// Stage, then pool, then round, then position, then id.
    static func inOrder(_ a: TournamentMatch, _ b: TournamentMatch) -> Bool {
        func rank(_ s: MatchStage) -> Int { s == .pool ? 0 : 1 }
        if rank(a.stage) != rank(b.stage) { return rank(a.stage) < rank(b.stage) }
        let pa = a.pool ?? "", pb = b.pool ?? ""
        if pa != pb { return pa < pb }
        if a.round != b.round { return a.round < b.round }
        if a.position != b.position { return a.position < b.position }
        return a.id.uuidString < b.id.uuidString
    }

    /// A real result (not an auto-resolved bye). Mirrors the server's
    /// `_tournament_match_is_played`.
    var isPlayed: Bool {
        slot1EntrantId != nil && slot2EntrantId != nil
            && (winnerEntrantId != nil || (status == .complete && slot1Score != nil && slot2Score != nil))
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

    /// Recorded results (real games, not byes).
    var playedCount: Int { matches.filter(\.isPlayed).count }

    /// Would changing who is in a slot of `m` erase results? Mirrors the
    /// server's `_tournament_slot_change_destroys`.
    func slotChangeDestroys(_ m: TournamentMatch) -> Bool {
        if m.isPlayed { return true }
        if m.winnerEntrantId != nil, let n = m.nextMatchId,
           let next = matches.first(where: { $0.id == n }), next.isPlayed { return true }
        return false
    }

    /// Results that would be erased by changing `m`: its own and every played
    /// game downstream of it.
    func resultsLost(changing ids: [UUID]) -> Int {
        let byId = Dictionary(matches.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UUID>(); var count = 0
        for start in ids {
            var cur = byId[start]
            while let c = cur, !seen.contains(c.id) {
                seen.insert(c.id)
                if c.isPlayed { count += 1 }
                cur = c.nextMatchId.flatMap { byId[$0] }
            }
        }
        return count
    }

    var hasAnyScores: Bool { matches.contains { $0.slot1Score != nil || $0.slot2Score != nil } }
    var poolLabels: [String] { Set(entrants.compactMap { $0.pool }).sorted() }
    var hasKnockoutBracket: Bool { matches.contains { $0.stage == .bracket } }
    var poolStageComplete: Bool {
        let pool = matches.filter { $0.stage == .pool }
        return !pool.isEmpty && pool.allSatisfy { $0.status == .complete }
    }
    var bracketMatches: [TournamentMatch] { matches.filter { $0.stage == .bracket }.sorted(by: TournamentMatch.inOrder) }
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
    /// Round-robin / pool standings, ranked by the tournament's own ORDERED
    /// `tiebreakers` (default win_pct → head_to_head → point_diff →
    /// points_for) — mirrors web's computeStandings() exactly, including the
    /// head-to-head lookup, rather than a fixed order.
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
        /// -1 when x beat y, 1 when y beat x, 0 when they haven't played (or tied).
        func headToHead(_ x: Standing, _ y: Standing) -> Int {
            guard let m = done.first(where: {
                ($0.slot1EntrantId == x.entrantId && $0.slot2EntrantId == y.entrantId)
                    || ($0.slot1EntrantId == y.entrantId && $0.slot2EntrantId == x.entrantId)
            }), let winner = m.winnerEntrantId else { return 0 }
            return winner == x.entrantId ? -1 : 1
        }
        func seed(_ id: UUID) -> Int { entrants.first { $0.id == id }?.seed ?? entrants.first { $0.id == id }?.position ?? 1_000_000 }
        let order = tiebreakers.isEmpty ? ["win_pct", "head_to_head", "point_diff", "points_for"] : tiebreakers
        var sorted = Array(rows.values).sorted { x, y in
            for tb in order {
                let d: Int
                switch tb {
                case "win_pct":       d = winPct(x) == winPct(y) ? 0 : (winPct(x) > winPct(y) ? -1 : 1)
                case "point_diff":    d = x.diff == y.diff ? 0 : (x.diff > y.diff ? -1 : 1)
                case "points_for":    d = x.pointsFor == y.pointsFor ? 0 : (x.pointsFor > y.pointsFor ? -1 : 1)
                case "head_to_head":  d = headToHead(x, y)
                default:              d = 0
                }
                if d != 0 { return d < 0 }
            }
            return seed(x.entrantId) < seed(y.entrantId)
        }
        for i in sorted.indices { sorted[i].rank = i + 1 }
        return sorted
    }
}

// MARK: - Derived helpers for the live screen (presentation only; no new data)

/// Optional scoring rules a tournament may carry (target score / win by).
struct ScoreRules {
    let target: Int?
    let winBy: Int?

    /// Loser-score quick presets for a game played to `target` (e.g. 21: 19, 15, 10, 5, 0).
    var loserPresets: [Int] {
        guard let target, target > 1 else { return [] }
        let margin = max(winBy ?? 1, 1)
        var out: [Int] = [target - margin, (target * 3) / 4, target / 2, target / 4, 0]
        out = out.filter { $0 >= 0 && $0 <= target - margin }
        var seen = Set<Int>()
        return out.filter { seen.insert($0).inserted }.sorted(by: >)
    }

    /// A gentle, non-blocking note when the entered scores don't fit the rules
    /// (a game called early at the lake is still a result). nil = fits or no rules.
    func note(winnerScore w: Int, loserScore l: Int) -> String? {
        guard w != l else { return "The scores are tied but a winner is picked." }
        let hi = max(w, l), lo = min(w, l)
        if let target, hi < target { return "Usually played to \(target). The top score here is \(hi)." }
        if let winBy, winBy > 1, hi - lo < winBy { return "Usually win by \(winBy). This margin is \(hi - lo)." }
        return nil
    }
}

extension Tournament {
    var scoreRules: ScoreRules { ScoreRules(target: targetScore, winBy: winBy) }

    var isFinished: Bool { winnerEntrantId != nil || status == .complete }

    /// An auto-resolved bye: one side known, nothing to play.
    func isBye(_ m: TournamentMatch) -> Bool {
        (m.slot1EntrantId != nil) != (m.slot2EntrantId != nil) && m.status == .complete
    }

    /// Both sides known and no result yet: playable right now.
    func isReady(_ m: TournamentMatch) -> Bool {
        m.slot1EntrantId != nil && m.slot2EntrantId != nil && m.winnerEntrantId == nil && m.status != .complete
    }

    /// Games to play right now, in tournament order.
    var readyMatches: [TournamentMatch] {
        guard status == .live else { return [] }
        return matches.filter(isReady).sorted(by: TournamentMatch.inOrder)
    }

    /// Games feeding `m` (bracket tree).
    func feeders(of m: TournamentMatch) -> [TournamentMatch] {
        matches.filter { $0.nextMatchId == m.id }
    }

    /// Games waiting on exactly one result before they can be played.
    var upNextMatches: [TournamentMatch] {
        guard status == .live else { return [] }
        return matches.filter { m in
            guard m.status != .complete, !isReady(m) else { return false }
            return feeders(of: m).filter { $0.status != .complete }.count == 1
        }.sorted(by: TournamentMatch.inOrder)
    }

    /// Most recent real results, newest round first.
    func recentResults(limit: Int = 6) -> [TournamentMatch] {
        Array(matches.filter(\.isPlayed).sorted(by: { TournamentMatch.inOrder($1, $0) }).prefix(limit))
    }

    /// The entrant a signed-in member plays as (through participants' user ids).
    func entrantId(forUser userId: UUID?) -> UUID? {
        guard let userId else { return nil }
        return entrants.first { e in e.withdrawnAt == nil && e.members.contains { $0.userId == userId } }?.id
    }

    func involves(_ m: TournamentMatch, entrant id: UUID?) -> Bool {
        guard let id else { return false }
        return m.slot1EntrantId == id || m.slot2EntrantId == id
    }

    /// The champion's games in order (the road to the title).
    func path(of entrant: UUID) -> [TournamentMatch] {
        matches.filter { $0.isPlayed && involves($0, entrant: entrant) }.sorted(by: TournamentMatch.inOrder)
    }

    /// Opponent name from `entrant`'s point of view.
    func opponentName(in m: TournamentMatch, of entrant: UUID) -> String {
        entrantName(m.slot1EntrantId == entrant ? m.slot2EntrantId : m.slot1EntrantId)
    }

    private var namesRounds: Bool { bracketMatches.contains { $0.nextMatchId != nil } }

    /// "Quarterfinals", "Semifinals", "Final"; "Round n" otherwise.
    func roundTitle(_ m: TournamentMatch) -> String {
        if m.stage == .pool { return m.pool.map { "Pool \($0) · Round \(m.round)" } ?? "Round \(m.round)" }
        if namesRounds {
            switch maxRound - m.round {
            case 0: return "Final"
            case 1: return "Semifinals"
            case 2: return "Quarterfinals"
            default: break
            }
        }
        return "Round \(m.round)"
    }

    func roundTitle(round: Int) -> String {
        if namesRounds {
            switch maxRound - round {
            case 0: return "Final"
            case 1: return "Semifinals"
            case 2: return "Quarterfinals"
            default: break
            }
        }
        return "Round \(round)"
    }

    /// "Semifinal 2" / "Final" / "Round 3 · game 4" — singular, numbered when the round has several games.
    func gameLabel(_ m: TournamentMatch) -> String {
        let peers = matches.filter { $0.stage == m.stage && $0.pool == m.pool && $0.round == m.round && !isBye($0) }
            .sorted(by: TournamentMatch.inOrder)
        let n = (peers.firstIndex { $0.id == m.id } ?? 0) + 1
        let base: String
        if m.stage == .bracket, namesRounds {
            switch maxRound - m.round {
            case 0: base = "Final"
            case 1: base = "Semifinal"
            case 2: base = "Quarterfinal"
            default: base = "Round \(m.round) game"
            }
        } else if m.stage == .pool {
            base = m.pool.map { "Pool \($0) game" } ?? "Game"
        } else {
            base = "Round \(m.round) game"
        }
        return peers.count > 1 ? "\(base) \(n)" : base
    }

    /// Short tag for bracket placeholders ("SF 1").
    func shortGameLabel(_ m: TournamentMatch) -> String {
        gameLabel(m)
            .replacingOccurrences(of: "Quarterfinal", with: "QF")
            .replacingOccurrences(of: "Semifinal", with: "SF")
    }

    /// Placeholder for an empty slot: "Winner of SF 1", or nil when unknown.
    func slotPlaceholder(_ m: TournamentMatch, slot: Int) -> String? {
        let fed = feeders(of: m).filter { ($0.nextSlot ?? slot) == slot }
        guard fed.count == 1, let f = fed.first else { return nil }
        return "Winner of \(shortGameLabel(f))"
    }

    /// Full VoiceOver sentence: "Semifinal 1: Sam and Jo versus Pat and Lee, Sam and Jo won 21 to 15".
    func a11yDescription(_ m: TournamentMatch) -> String {
        let label = gameLabel(m)
        if isBye(m) {
            let id = m.slot1EntrantId ?? m.slot2EntrantId
            return "\(label): \(entrantName(id)) has a bye"
        }
        let n1 = m.slot1EntrantId != nil ? entrantName(m.slot1EntrantId).replacingOccurrences(of: " & ", with: " and ") : "to be decided"
        let n2 = m.slot2EntrantId != nil ? entrantName(m.slot2EntrantId).replacingOccurrences(of: " & ", with: " and ") : "to be decided"
        var s = "\(label): \(n1) versus \(n2)"
        if let w = m.winnerEntrantId {
            let wn = entrantName(w).replacingOccurrences(of: " & ", with: " and ")
            if let a = m.slot1Score, let b = m.slot2Score {
                let ws = w == m.slot1EntrantId ? a : b, ls = w == m.slot1EntrantId ? b : a
                s += ", \(wn) won \(ws) to \(ls)"
            } else {
                s += ", \(wn) won"
            }
        } else if isReady(m) {
            s += ", ready to play"
        } else {
            s += ", waiting"
        }
        return s
    }
}
