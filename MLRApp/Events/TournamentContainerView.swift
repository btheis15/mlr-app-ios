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
    /// Preview-as never writes (existing app rule), so previewing is read-only.
    private var manage: Bool { canManage && !env.isPreviewing }

    @Environment(AppEnvironment.self) private var env
    @State private var tournament: Tournament?
    @State private var loading = true
    @State private var showSetup = false
    @State private var resultMatch: TournamentMatch?
    @State private var tab: LiveTab = .bracket
    @State private var rearranging = false
    @State private var pickedUp: (matchId: UUID, slot: Int)?
    @State private var errorText: String?
    // Fetch health: the empty/setup state is only legitimate after a fetch SUCCEEDED
    // with zero rows. A failed fetch keeps whatever was last loaded.
    @State private var fetchedOK = false
    @State private var refreshFailed = false
    @State private var busy = false
    @State private var pendingSwap: PendingSwap?
    @State private var subscribedId: UUID?
    // Bracket presentation + live feel.
    @State private var bracketMode: BracketMode = .diagram
    // Games that were ready at the last fetch (to spot "a new game just opened").
    @State private var prevReadyIds: Set<UUID> = []
    @State private var hasLoadedOnce = false
    // Set when this device just saved a result, so the "Next game" offer only
    // follows our own scoring (not someone else's realtime update).
    @State private var justScored = false
    @State private var nextOffer: TournamentMatch?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct PendingSwap: Identifiable {
        let id = UUID()
        let a: (matchId: UUID, slot: Int)
        let b: (matchId: UUID, slot: Int)
        let lost: Int
    }

    enum BracketMode: String, CaseIterable { case diagram = "Diagram", byRound = "By round" }

    enum LiveTab: String, CaseIterable { case bracket = "Bracket", standings = "Standings", pools = "Pools", games = "Games" }

    var body: some View {
        Group {
            if loading {
                TournamentLoadingView()
            } else if let t = tournament {
                live(t)
            } else if !fetchedOK {
                ContentUnavailableView {
                    Label("Couldn't load the tournament", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Retry") { Task { await reload() } }.buttonStyle(.borderedProminent)
                }
            } else if manage {
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
            if let t = tournament, t.status != .setup {
                ToolbarItem(placement: .topBarTrailing) { TournamentShareButton(tournament: t) }
            }
            if let t = tournament, manage {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showSetup = true } label: { Label(t.status == .setup ? "Set up" : "Manage", systemImage: "slider.horizontal.3") }
                        if t.status == .live && t.format != .round_robin {
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
            MatchResultSheet(tournament: tournament, match: m,
                             latest: tournament?.matches.first { $0.id == m.id },
                             onSaved: { justScored = true; nextOffer = nil }) { Task { await reload() } }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .safeAreaInset(edge: .bottom) {
            if let t = tournament, let offer = nextOffer, manage {
                NextGameBanner(
                    title: "\(t.entrantName(offer.slot1EntrantId)) vs \(t.entrantName(offer.slot2EntrantId))",
                    canScore: manage,
                    onOpen: { nextOffer = nil; resultMatch = offer },
                    onDismiss: { nextOffer = nil })
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : MLRMotion.spring, value: nextOffer?.id)
        .task { await reload() }
        .onDisappear { if let id = subscribedId { env.tournamentsService.unsubscribe(tournamentId: id); subscribedId = nil } }
        .onChange(of: tournament?.format) { _, _ in tab = defaultTab }
        .onChange(of: tournament?.status) { _, new in
            if new != .live { rearranging = false; pickedUp = nil }
        }
        .confirmationDialog(
            "Swap these players?", isPresented: Binding(get: { pendingSwap != nil }, set: { if !$0 { pendingSwap = nil } }),
            titleVisibility: .visible, presenting: pendingSwap
        ) { swap in
            Button("Swap and erase \(swap.lost) result\(swap.lost == 1 ? "" : "s")", role: .destructive) {
                run { try await env.tournamentsService.swapMatchEntrants(
                    matchA: swap.a.matchId, slotA: swap.a.slot, matchB: swap.b.matchId, slotB: swap.b.slot, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { swap in
            Text("A game involved already has a result. Swapping erases that result and every game decided after it (\(swap.lost) recorded result\(swap.lost == 1 ? "" : "s") in all). A copy is saved first.")
        }
    }

    // MARK: Live

    @ViewBuilder
    private func live(_ t: Tournament) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if refreshFailed {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.mlrTextMuted)
                        Text("Couldn't refresh").font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                        Spacer()
                        Button("Retry") { Task { await reload() } }.font(.mlrScaled(12, weight: .semibold))
                    }
                }
                if t.status != .setup {
                    TournamentNowCard(tournament: t, viewerEntrantId: t.entrantId(forUser: env.effectiveUserId),
                                      canScore: manage, onOpen: { resultMatch = $0 })
                }

                if rearranging {
                    Text("Tap a player, then tap another slot to swap them.")
                        .font(.mlrScaled(12)).foregroundStyle(Color.mlrPineText)
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
        .refreshable { await reload() }
    }

    private func setupPrompt(_ t: Tournament) -> some View {
        VStack(spacing: 10) {
            Text("\(t.entrants.count + t.pool.count) player\(t.entrants.count + t.pool.count == 1 ? "" : "s") ready.")
                .font(.mlrScaled(14)).foregroundStyle(Color.mlrTextMuted)
            if manage {
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
            gamesList(t)
        case .pools:
            poolsContent(t)
        case .bracket:
            if t.format == .pools_bracket && !t.hasKnockoutBracket {
                knockoutPending(t)
            } else {
                bracketArea(t)
            }
        }
    }

    /// THE BIG BRACKET (Phase 2.4): the connected diagram is the default; the
    /// round-pager remains as a compact fallback — automatic under Reduce Motion
    /// or for very large draws, and always reachable via the toggle.
    @ViewBuilder
    private func bracketArea(_ t: Tournament) -> some View {
        let stage: MatchStage? = t.format == .pools_bracket ? .bracket : nil
        let useDiagram = bracketMode == .diagram

        VStack(spacing: 12) {
            Picker("Bracket view", selection: $bracketMode) {
                ForEach(BracketMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if useDiagram {
                BracketDiagram(
                    tournament: t, stageFilter: stage,
                    canManage: manage, rearranging: rearranging, pickedUp: pickedUp,
                    viewerEntrantId: t.entrantId(forUser: env.effectiveUserId),
                    onOpen: { resultMatch = $0 }, onSlotTap: { m, s in handleSlotTap(t, m, s) })
                .frame(height: 520)
                .cardStyle(cornerRadius: MLRRadius.card, elevation: .low)
            } else {
                TournamentBracketView(
                    tournament: t, stageFilter: stage,
                    canManage: manage, rearranging: rearranging, pickedUp: pickedUp,
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
        if t.poolStageComplete && !t.hasKnockoutBracket && manage {
            Button { run { try await env.tournamentsService.generateBracketFromPools(id: t.id) } } label: {
                Label("Generate knockout bracket", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
        }
    }

    private func knockoutPending(_ t: Tournament) -> some View {
        ContentUnavailableView("Knockout bracket to come", systemImage: "square.grid.2x2",
                               description: Text("It seeds itself once every pool game is played."))
    }

    /// Plain tournament-order list of every real game (byes are not games).
    @ViewBuilder
    private func gamesList(_ t: Tournament) -> some View {
        let games = t.matches.filter { !t.isBye($0) }
        if games.isEmpty {
            ContentUnavailableView("No games yet", systemImage: "list.bullet",
                                   description: Text("Games show up here once the tournament starts."))
        } else {
            matchList(t, games)
        }
    }

    private func matchList(_ t: Tournament, _ matches: [TournamentMatch]) -> some View {
        VStack(spacing: 10) {
            ForEach(matches.sorted(by: TournamentMatch.inOrder)) { m in
                MatchCard(tournament: t, match: m, canManage: manage, rearranging: rearranging,
                          pickedUp: pickedUp, onOpen: { resultMatch = m }, onSlotTap: { s in handleSlotTap(t, m, s) })
            }
        }
    }

    // MARK: Rearrange (tap-to-swap)

    private func handleSlotTap(_ t: Tournament, _ match: TournamentMatch, _ slot: Int) {
        guard rearranging, manage else { return }
        let entrant = slot == 1 ? match.slot1EntrantId : match.slot2EntrantId
        guard let picked = pickedUp else {
            if entrant != nil { pickedUp = (match.id, slot) }   // pick up a filled slot
            return
        }
        if picked.matchId == match.id && picked.slot == slot { pickedUp = nil; return }  // tap same = cancel
        let a = picked
        pickedUp = nil
        guard !busy else { return }
        // Before any game is played this is free. Once either game has a result,
        // spell out what is lost and only then send force.
        let other = t.matches.first { $0.id == a.matchId }
        let destroys = t.slotChangeDestroys(match) || (other.map(t.slotChangeDestroys) ?? false)
        if destroys {
            pendingSwap = PendingSwap(a: a, b: (match.id, slot), lost: t.resultsLost(changing: [a.matchId, match.id]))
        } else {
            run { try await env.tournamentsService.swapMatchEntrants(matchA: a.matchId, slotA: a.slot, matchB: match.id, slotB: slot) }
        }
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
        case .single_elim:   return [.bracket, .games]
        case .round_robin:   return [.standings, .games]
        case .pools_bracket: return [.pools, .bracket, .games]
        }
    }

    // MARK: Data

    private func reload() async {
        do {
            let list = try await env.tournamentsService.fetchChecked(host: host)
            let fresh = list.first
            // Results from another phone glide in rather than jump.
            if reduceMotion { tournament = fresh } else { withAnimation(MLRMotion.spring) { tournament = fresh } }
            noteReadyChanges(fresh)
            fetchedOK = true
            refreshFailed = false
            if let t = tournament, !availableTabs(t).contains(tab) { tab = defaultTab }
            if let t = tournament, subscribedId != t.id {
                if let old = subscribedId { env.tournamentsService.unsubscribe(tournamentId: old) }
                subscribedId = t.id
                env.tournamentsService.subscribe(tournamentId: t.id) { Task { await reload() } }
            }
        } catch {
            // Keep the last loaded tournament on screen; never fall into the empty state.
            refreshFailed = true
        }
        loading = false
    }

    /// A light haptic when a game the viewer is in opens up, and the "Next game"
    /// offer after we score something that makes a new game ready.
    private func noteReadyChanges(_ t: Tournament?) {
        let ready = t?.readyMatches ?? []
        let ids = Set(ready.map(\.id))
        defer { prevReadyIds = ids; hasLoadedOnce = true }
        guard let t else { return }
        let fresh = ready.filter { !prevReadyIds.contains($0.id) }
        if hasLoadedOnce {
            let me = t.entrantId(forUser: env.effectiveUserId)
            if fresh.contains(where: { t.involves($0, entrant: me) }) { Haptics.tap() }
        }
        if justScored {
            justScored = false
            let me = t.entrantId(forUser: env.effectiveUserId)
            nextOffer = fresh.first(where: { t.involves($0, entrant: me) }) ?? fresh.first
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        errorText = nil
        Task {
            do { try await work() } catch { errorText = TournamentsService.message(for: error) }
            await reload()
            busy = false
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
            ContentUnavailableView("No games yet", systemImage: "trophy",
                                   description: Text("The bracket appears once the tournament starts."))
        } else {
            VStack(spacing: 12) {
                if rounds.count > 1 {
                    Picker("Round", selection: Binding(get: { activeRound }, set: { round = $0 })) {
                        ForEach(rounds, id: \.self) { r in Text(shortRound(r)).tag(r) }
                    }
                    .pickerStyle(.segmented)
                }
                VStack(spacing: 10) {
                    ForEach(shown.filter { $0.round == activeRound }.sorted(by: TournamentMatch.inOrder)) { m in
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

    private var isLive: Bool { match.status == .ready || match.status == .in_progress }

    var body: some View {
        VStack(spacing: 0) {
            slotRow(match.slot1EntrantId, score: match.slot1Score, slot: 1)
            Divider()
            slotRow(match.slot2EntrantId, score: match.slot2Score, slot: 2)
            if match.isPlayIn || isLive || match.scheduledAt != nil {
                footer
            }
        }
        .cardStyle(cornerRadius: 14, elevation: .medium)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(rearranging ? Color.mlrPrimary.opacity(0.45) : Color.clear, lineWidth: 1.5))
        .opacity(bye ? 0.7 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if tappable { Haptics.tap(); onOpen() } }
        .accessibilityElement(children: rearranging ? .contain : .ignore)
        .accessibilityLabel(tournament.a11yDescription(match))
        .accessibilityAddTraits(tappable ? .isButton : [])
        .accessibilityAction { if tappable { onOpen() } }
    }

    @ViewBuilder
    private func slotRow(_ entrantId: UUID?, score: Int?, slot: Int) -> some View {
        let isWinner = match.winnerEntrantId != nil && entrantId == match.winnerEntrantId
        let isPicked = rearranging && pickedUp?.matchId == match.id && pickedUp?.slot == slot
        let label = entrantId != nil ? tournament.entrantName(entrantId) : (match.status == .complete ? "Bye" : "TBD")
        let seed = tournament.entrants.first { $0.id == entrantId }?.seed
        HStack(spacing: 8) {
            // Gold accent bar marks the winning row.
            RoundedRectangle(cornerRadius: 1)
                .fill(isWinner ? Color.mlrFestGold : Color.clear)
                .frame(width: 3, height: 20)
            if let seed {
                Text("\(seed)")
                    .font(.mlrScaled(10, weight: .bold))
                    .foregroundStyle(Color.mlrTextSubtle)
                    .frame(width: 16)
            }
            Text(label)
                .font(.mlrScaled(15, weight: isWinner ? .bold : .regular))
                .foregroundStyle(entrantId != nil ? Color.mlrText : Color.mlrTextSubtle)
                .lineLimit(1)
            if isWinner {
                Image(systemName: "crown.fill")
                    .font(.mlrScaled(10))
                    .foregroundStyle(Color.mlrFestGold)
            }
            Spacer()
            if rearranging {
                if entrantId != nil { Text(isPicked ? "moving…" : "move").font(.mlrScaled(11, weight: .semibold)).foregroundStyle(Color.mlrPineText) }
            } else if let score {
                Text("\(score)").font(.mlrScaled(15, weight: .bold)).monospacedDigit().numericTransition()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(isPicked ? Color.mlrPrimary.mlrTint(0.25) : (isWinner ? Color.mlrPrimary.mlrTint(0.08) : Color.clear))
        .scaleEffect(isPicked ? 1.02 : 1)
        .animation(MLRMotion.spring, value: isPicked)
        .contentShape(Rectangle())
        .onTapGesture { if rearranging && canManage { Haptics.select(); onSlotTap(slot) } }
    }

    private var footer: some View {
        HStack {
            if match.isPlayIn {
                Text("PLAY-IN").font(.mlrScaled(10, weight: .bold)).foregroundStyle(Color.mlrPineText).tracking(0.6)
            } else if isLive {
                HStack(spacing: 5) {
                    PulsingLiveDot(color: .mlrSuccess).scaleEffect(0.8)
                    Text(match.status == .in_progress ? "LIVE" : "READY")
                        .font(.mlrScaled(10, weight: .bold)).foregroundStyle(Color.mlrSuccess).tracking(0.6)
                }
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
        .mlrBackdrop()
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
                let medal = medalColor(rank: r.rank)
                VStack(spacing: 4) {
                    HStack {
                        // Rank — medal symbol for the podium, plain number after.
                        Group {
                            if let medal {
                                Image(systemName: "medal.fill").font(.mlrScaled(12)).foregroundStyle(medal)
                            } else {
                                Text("\(r.rank)").font(.mlrScaled(13, weight: .bold)).foregroundStyle(Color.mlrTextMuted)
                            }
                        }
                        .frame(width: 22, alignment: .leading)
                        Text(r.name).font(.mlrScaled(14, weight: r.entrantId == leaderId || r.rank == 1 ? .bold : .regular)).lineLimit(1)
                        if r.entrantId == leaderId { Image(systemName: "crown.fill").font(.mlrScaled(10)).foregroundStyle(Color.mlrFestGold) }
                        Spacer()
                        Text(r.record).font(.mlrScaled(13, weight: .medium)).monospacedDigit().numericTransition().frame(width: 56, alignment: .trailing)
                        if showScores {
                            Text(r.diff >= 0 ? "+\(r.diff)" : "\(r.diff)").font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted).monospacedDigit().numericTransition().frame(width: 44, alignment: .trailing)
                        }
                    }
                    // Win% mini-bar.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.mlrBorder.opacity(0.5))
                            Capsule().fill(medal ?? Color.mlrPrimary.opacity(0.55))
                                .frame(width: max(3, geo.size.width * winPct(r)))
                        }
                    }
                    .frame(height: 3)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(medal.map { $0.opacity(0.07) } ?? Color.clear)
                Divider()
            }
        }
        .cardStyle(cornerRadius: 14, elevation: .low)
    }

    private func medalColor(rank: Int) -> Color? {
        switch rank {
        case 1: return .mlrFestGold
        case 2: return Color(light: "#8E9196", dark: "#B9BDC4")   // silver
        case 3: return Color(light: "#B0662C", dark: "#D08A50")   // bronze
        default: return nil
        }
    }

    private func winPct(_ r: Standing) -> CGFloat {
        guard r.played > 0 else { return 0 }
        return CGFloat(Double(r.wins) + 0.5 * Double(r.ties)) / CGFloat(r.played)
    }
}
