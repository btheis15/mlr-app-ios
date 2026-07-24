import SwiftUI

// MARK: - TournamentContainerView (migrations 0144–0154)
//
// The full tournament surface for a host (private activity or fest schedule
// activity). Setup lives in a dedicated sheet (create → import players →
// drag-to-seed → generate); the live tournament shows a round-pager bracket,
// round-robin / pool standings, and one-tap "who won" scoring. Managers can also
// rearrange the live bracket by tapping two slots to swap them. Mirrors the web
// TournamentView + TournamentBracket + TournamentSetupSheet + MatchResultSheet.

struct TournamentContainerView: View {
    let host: TournamentHost
    var canManage: Bool = false

    @Environment(AppEnvironment.self) private var env
    @State private var tournament: Tournament?
    @State private var loading = true
    @State private var showSetup = false
    @State private var resultMatch: TournamentMatch?
    @State private var tab: LiveTab = .bracket
    @State private var rearranging = false
    @State private var pickedUp: (matchId: UUID, slot: Int)?
    @State private var errorText: String?

    enum LiveTab: String, CaseIterable { case bracket = "Bracket", standings = "Standings", pools = "Pools", games = "Games" }

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let t = tournament {
                live(t)
            } else if canManage {
                ContentUnavailableView {
                    Label("No tournament yet", systemImage: "trophy")
                } description: {
                    Text("Set one up — import the players, seed them, and generate a bracket.")
                } actions: {
                    Button("Set up a tournament") { showSetup = true }.buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView("No tournament yet", systemImage: "trophy")
            }
        }
        .navigationTitle(tournament?.title ?? "Tournament")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let t = tournament, canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showSetup = true } label: { Label(t.status == .setup ? "Set up" : "Manage", systemImage: "slider.horizontal.3") }
                        if t.status != .setup && t.format != .round_robin {
                            Button { rearranging.toggle(); pickedUp = nil } label: {
                                Label(rearranging ? "Done rearranging" : "Rearrange bracket", systemImage: "arrow.left.arrow.right")
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .sheet(isPresented: $showSetup) {
            NavigationStack {
                TournamentSetupSheet(host: host, tournament: tournament) { Task { await reload() } }
            }
        }
        .sheet(item: $resultMatch) { m in
            MatchResultSheet(tournament: tournament, match: m) { Task { await reload() } }
        }
        .task { await reload() }
        .onChange(of: tournament?.format) { _, _ in tab = defaultTab }
    }

    // MARK: Live

    @ViewBuilder
    private func live(_ t: Tournament) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let champ = t.winnerEntrantId {
                    Label("Champion: \(t.entrantName(champ))", systemImage: "crown.fill")
                        .font(.mlrScaled(17, weight: .bold))
                        .foregroundStyle(Color.mlrWarning)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.mlrWarning.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if rearranging {
                    Text("Tap a player, then tap another slot to swap them.")
                        .font(.mlrScaled(12)).foregroundStyle(Color.mlrPrimary)
                }

                if t.status == .setup {
                    setupPrompt(t)
                } else {
                    let tabs = availableTabs(t)
                    if tabs.count > 1 {
                        Picker("View", selection: $tab) {
                            ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    content(t, tab: tabs.contains(tab) ? tab : (tabs.first ?? .bracket))
                }

                if let errorText {
                    Text(errorText).font(.mlrScaled(12)).foregroundStyle(Color.mlrDanger)
                }
            }
            .padding(16)
        }
    }

    private func setupPrompt(_ t: Tournament) -> some View {
        VStack(spacing: 10) {
            Text("\(t.entrants.count + t.pool.count) player\(t.entrants.count + t.pool.count == 1 ? "" : "s") ready.")
                .font(.mlrScaled(14)).foregroundStyle(Color.mlrTextMuted)
            if canManage {
                Button { showSetup = true } label: {
                    Label("Seed & generate the \(t.format.label.lowercased())", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("The organizer hasn't started it yet.").font(.mlrScaled(13)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func content(_ t: Tournament, tab: LiveTab) -> some View {
        switch tab {
        case .standings:
            StandingsTable(rows: t.standings(), showScores: t.hasAnyScores, leaderId: t.winnerEntrantId)
        case .games:
            matchList(t, t.matches.filter { $0.stage != .bracket })
        case .pools:
            poolsContent(t)
        case .bracket:
            if t.format == .pools_bracket && !t.hasKnockoutBracket {
                knockoutPending(t)
            } else {
                TournamentBracketView(
                    tournament: t, stageFilter: t.format == .pools_bracket ? .bracket : nil,
                    canManage: canManage, rearranging: rearranging, pickedUp: pickedUp,
                    onOpen: { resultMatch = $0 }, onSlotTap: { m, s in handleSlotTap(t, m, s) })
            }
        }
    }

    @ViewBuilder
    private func poolsContent(_ t: Tournament) -> some View {
        ForEach(t.poolLabels, id: \.self) { pool in
            VStack(alignment: .leading, spacing: 6) {
                Text("Pool \(pool)").font(.mlrScaled(14, weight: .bold)).foregroundStyle(Color.mlrText)
                StandingsTable(rows: t.standings(pool: pool), showScores: t.hasAnyScores, leaderId: nil)
            }
        }
        let poolGames = t.matches.filter { $0.stage == .pool }
        if !poolGames.isEmpty {
            Text("Pool games").font(.mlrScaled(13, weight: .semibold)).foregroundStyle(Color.mlrTextMuted)
            matchList(t, poolGames)
        }
        if t.poolStageComplete && !t.hasKnockoutBracket && canManage {
            Button { run { try await env.tournamentsService.generateBracketFromPools(id: t.id) } } label: {
                Label("Generate knockout bracket", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
        }
    }

    private func knockoutPending(_ t: Tournament) -> some View {
        Text("The knockout bracket seeds once every pool game is played.")
            .font(.mlrScaled(13)).foregroundStyle(.secondary).padding(.vertical, 12)
    }

    private func matchList(_ t: Tournament, _ matches: [TournamentMatch]) -> some View {
        VStack(spacing: 10) {
            ForEach(matches.sorted { $0.round == $1.round ? $0.position < $1.position : $0.round < $1.round }) { m in
                MatchCard(tournament: t, match: m, canManage: canManage, rearranging: rearranging,
                          pickedUp: pickedUp, onOpen: { resultMatch = m }, onSlotTap: { s in handleSlotTap(t, m, s) })
            }
        }
    }

    // MARK: Rearrange (tap-to-swap)

    private func handleSlotTap(_ t: Tournament, _ match: TournamentMatch, _ slot: Int) {
        guard rearranging, canManage else { return }
        let entrant = slot == 1 ? match.slot1EntrantId : match.slot2EntrantId
        guard let picked = pickedUp else {
            if entrant != nil { pickedUp = (match.id, slot) }   // pick up a filled slot
            return
        }
        if picked.matchId == match.id && picked.slot == slot { pickedUp = nil; return }  // tap same = cancel
        let a = picked
        pickedUp = nil
        run { try await env.tournamentsService.swapMatchEntrants(matchA: a.matchId, slotA: a.slot, matchB: match.id, slotB: slot) }
    }

    // MARK: Tabs

    private var defaultTab: LiveTab {
        switch tournament?.format {
        case .round_robin: return .standings
        case .pools_bracket: return .pools
        default: return .bracket
        }
    }
    private func availableTabs(_ t: Tournament) -> [LiveTab] {
        switch t.format {
        case .single_elim:   return [.bracket]
        case .round_robin:   return [.standings, .games]
        case .pools_bracket: return [.pools, .bracket]
        }
    }

    // MARK: Data

    private func reload() async {
        let list = await env.tournamentsService.fetch(host: host)
        tournament = list.first
        if let t = tournament, !availableTabs(t).contains(tab) { tab = defaultTab }
        loading = false
    }

    private func run(_ work: @escaping () async throws -> Void) {
        errorText = nil
        Task {
            do { try await work() } catch { errorText = "Something went wrong. Try again." }
            await reload()
        }
    }
}

// MARK: - Round-pager bracket

private struct TournamentBracketView: View {
    let tournament: Tournament
    var stageFilter: MatchStage? = nil
    let canManage: Bool
    let rearranging: Bool
    let pickedUp: (matchId: UUID, slot: Int)?
    let onOpen: (TournamentMatch) -> Void
    let onSlotTap: (TournamentMatch, Int) -> Void

    @State private var round = 1

    private var shown: [TournamentMatch] {
        tournament.matches.filter { stageFilter == nil || $0.stage == stageFilter }
    }
    private var rounds: [Int] { Array(Set(shown.map(\.round))).sorted() }
    private var numberedOnly: Bool { shown.allSatisfy { $0.nextMatchId == nil } }
    private var maxRound: Int { rounds.last ?? 1 }
    private var firstLive: Int {
        for r in rounds where shown.contains(where: { $0.round == r && $0.status != .complete && $0.slot1EntrantId != nil && $0.slot2EntrantId != nil }) {
            return r
        }
        return rounds.last ?? 1
    }
    private var activeRound: Int { rounds.contains(round) ? round : firstLive }

    var body: some View {
        if rounds.isEmpty {
            Text("No matches yet.").font(.mlrScaled(13)).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 12) {
                if rounds.count > 1 {
                    Picker("Round", selection: Binding(get: { activeRound }, set: { round = $0 })) {
                        ForEach(rounds, id: \.self) { r in Text(shortRound(r)).tag(r) }
                    }
                    .pickerStyle(.segmented)
                }
                VStack(spacing: 10) {
                    ForEach(shown.filter { $0.round == activeRound }.sorted { $0.position < $1.position }) { m in
                        MatchCard(tournament: tournament, match: m, canManage: canManage,
                                  rearranging: rearranging, pickedUp: pickedUp,
                                  onOpen: { onOpen(m) }, onSlotTap: { onSlotTap(m, $0) })
                    }
                }
            }
            .onAppear { round = firstLive }
        }
    }

    private func shortRound(_ r: Int) -> String {
        if numberedOnly { return "R\(r)" }
        switch maxRound - r {
        case 0: return "Final"
        case 1: return "SF"
        case 2: return "QF"
        default: return "R\(r)"
        }
    }
}

// MARK: - Match card

private struct MatchCard: View {
    let tournament: Tournament
    let match: TournamentMatch
    let canManage: Bool
    let rearranging: Bool
    let pickedUp: (matchId: UUID, slot: Int)?
    let onOpen: () -> Void
    let onSlotTap: (Int) -> Void

    private var bothSet: Bool { match.slot1EntrantId != nil && match.slot2EntrantId != nil }
    private var bye: Bool { (match.slot1EntrantId != nil) != (match.slot2EntrantId != nil) && match.status == .complete }
    private var tappable: Bool { !rearranging && canManage && (bothSet || match.status == .complete) && !bye }

    var body: some View {
        VStack(spacing: 0) {
            slotRow(match.slot1EntrantId, score: match.slot1Score, slot: 1)
            Divider()
            slotRow(match.slot2EntrantId, score: match.slot2Score, slot: 2)
            if match.isPlayIn || match.status == .ready || match.scheduledAt != nil {
                footer
            }
        }
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(rearranging ? Color.mlrPrimary.opacity(0.4) : Color.mlrBorder, lineWidth: 1))
        .opacity(bye ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if tappable { onOpen() } }
    }

    @ViewBuilder
    private func slotRow(_ entrantId: UUID?, score: Int?, slot: Int) -> some View {
        let isWinner = match.winnerEntrantId != nil && entrantId == match.winnerEntrantId
        let isPicked = rearranging && pickedUp?.matchId == match.id && pickedUp?.slot == slot
        let label = entrantId != nil ? tournament.entrantName(entrantId) : (match.status == .complete ? "Bye" : "TBD")
        HStack {
            Text(label)
                .font(.mlrScaled(15, weight: isWinner ? .bold : .regular))
                .foregroundStyle(entrantId != nil ? Color.mlrText : Color.mlrTextSubtle)
                .lineLimit(1)
            Spacer()
            if rearranging {
                if entrantId != nil { Text(isPicked ? "moving…" : "move").font(.mlrScaled(11, weight: .semibold)).foregroundStyle(Color.mlrPrimary) }
            } else if let score {
                Text("\(score)").font(.mlrScaled(15, weight: .bold)).monospacedDigit()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(isPicked ? Color.mlrPrimary.opacity(0.15) : (isWinner ? Color.mlrPrimary.opacity(0.08) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { if rearranging && canManage { onSlotTap(slot) } }
    }

    private var footer: some View {
        HStack {
            if match.isPlayIn {
                Text("PLAY-IN").font(.mlrScaled(10, weight: .bold)).foregroundStyle(Color.mlrPrimary).tracking(0.6)
            } else if match.status == .ready {
                Text("READY").font(.mlrScaled(10, weight: .bold)).foregroundStyle(Color.mlrPrimary).tracking(0.6)
            }
            if let at = match.scheduledAt, match.status != .complete {
                Text("🕒 \(at.formatted(date: .omitted, time: .shortened))").font(.mlrScaled(10)).foregroundStyle(Color.mlrTextMuted)
            }
            Spacer()
            if tappable && match.status != .complete {
                Text("Tap to score").font(.mlrScaled(10)).foregroundStyle(Color.mlrTextSubtle)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color.mlrSurface)
    }
}

// MARK: - Standings table

private struct StandingsTable: View {
    let rows: [Standing]
    let showScores: Bool
    let leaderId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("#").frame(width: 22, alignment: .leading)
                Text("Entrant")
                Spacer()
                Text("W-L").frame(width: 56, alignment: .trailing)
                if showScores { Text("Diff").frame(width: 44, alignment: .trailing) }
            }
            .font(.mlrScaled(11, weight: .semibold)).foregroundStyle(Color.mlrTextMuted)
            .padding(.horizontal, 12).padding(.vertical, 6)
            ForEach(rows) { r in
                HStack {
                    Text("\(r.rank)").font(.mlrScaled(13, weight: .bold)).foregroundStyle(Color.mlrTextMuted).frame(width: 22, alignment: .leading)
                    Text(r.name).font(.mlrScaled(14, weight: r.entrantId == leaderId ? .bold : .regular)).lineLimit(1)
                    if r.entrantId == leaderId { Image(systemName: "crown.fill").font(.mlrScaled(10)).foregroundStyle(Color.mlrWarning) }
                    Spacer()
                    Text(r.record).font(.mlrScaled(13, weight: .medium)).monospacedDigit().frame(width: 56, alignment: .trailing)
                    if showScores {
                        Text(r.diff >= 0 ? "+\(r.diff)" : "\(r.diff)").font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                Divider()
            }
        }
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
