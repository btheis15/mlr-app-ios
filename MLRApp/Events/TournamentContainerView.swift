import SwiftUI

// MARK: - TournamentContainerView (migrations 0144–0154)
//
// The tournament surface for a host (private activity or fest schedule activity):
// setup (import players → pick format → generate), then the live bracket /
// round-robin standings / pools, with managers recording match results. Mirrors
// TournamentView.tsx + TournamentBracket/TournamentStandings/TournamentSetupSheet.
// Deferred vs web: drag-to-reseed, match scheduling/notify, team-formation UI.

struct TournamentContainerView: View {
    let host: TournamentHost
    var canManage: Bool = false

    @Environment(AppEnvironment.self) private var env
    @State private var tournament: Tournament?
    @State private var loading = true
    @State private var busy = false
    @State private var newTitle = "Tournament"
    @State private var newFormat: TournamentFormat = .single_elim
    @State private var newEntrantType: EntrantType = .individual
    @State private var newTeamSize = 2
    @State private var poolCount = 2
    @State private var advance = 2
    @State private var resultMatch: TournamentMatch?
    @State private var errorText: String?

    var body: some View {
        List {
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let t = tournament {
                existing(t)
            } else if canManage {
                setupNew
            } else {
                Text("No tournament set up yet.").foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText).font(.mlrScaled(12)).foregroundStyle(Color.mlrDanger)
            }
        }
        .navigationTitle("Tournament")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let t = tournament, canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if t.status != .setup {
                            Button { run { try await env.tournamentsService.resetBracket(id: t.id) } } label: {
                                Label("Reset to setup", systemImage: "arrow.counterclockwise")
                            }
                        }
                        Button(role: .destructive) { run { try await env.tournamentsService.delete(id: t.id) } } label: {
                            Label("Delete tournament", systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .sheet(item: $resultMatch) { m in
            MatchResultSheet(tournament: tournament, match: m, onRecord: { winner, s1, s2 in
                run { try await env.tournamentsService.recordResult(matchId: m.id, winnerId: winner, score1: s1, score2: s2) }
            }, onClear: {
                run { try await env.tournamentsService.clearResult(matchId: m.id) }
            }, onChanged: {
                Task { await reload() }
            })
        }
        .task { await reload() }
    }

    // MARK: Create

    private var setupNew: some View {
        Section("Set up a tournament") {
            TextField("Title", text: $newTitle)
            Picker("Format", selection: $newFormat) {
                ForEach([TournamentFormat.single_elim, .round_robin, .pools_bracket], id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Entrants", selection: $newEntrantType) {
                Text("Individuals").tag(EntrantType.individual)
                Text("Teams").tag(EntrantType.team)
            }
            if newEntrantType == .team {
                Stepper("Team size: \(newTeamSize)", value: $newTeamSize, in: 2...8)
            }
            Button {
                run {
                    let id = try await env.tournamentsService.createForHost(
                        host, title: newTitle, format: newFormat,
                        entrantType: newEntrantType,
                        teamSize: newEntrantType == .team ? newTeamSize : nil)
                    _ = try? await env.tournamentsService.importEntrants(host: host, tournamentId: id)
                }
            } label: { Label("Create tournament", systemImage: "trophy") }
                .disabled(busy)
        }
    }

    // MARK: Existing

    @ViewBuilder
    private func existing(_ t: Tournament) -> some View {
        if let champ = t.winnerEntrantId {
            Section {
                Label("Champion: \(t.entrantName(champ))", systemImage: "crown.fill")
                    .font(.mlrScaled(16, weight: .bold))
                    .foregroundStyle(Color.mlrWarning)
            }
        }

        if t.status == .setup {
            setupExisting(t)
        } else {
            switch t.format {
            case .single_elim:   bracketSection(t)
            case .round_robin:   roundRobinSection(t)
            case .pools_bracket: poolsSection(t)
            }
        }
    }

    private func setupExisting(_ t: Tournament) -> some View {
        Group {
            Section("Players (\(t.entrants.count))") {
                if t.entrants.isEmpty {
                    Text("No players yet.").foregroundStyle(.secondary)
                }
                ForEach(t.entrants) { e in
                    Text(e.displayName).font(.mlrScaled(14))
                }
                if canManage {
                    Button { run { _ = try await env.tournamentsService.importEntrants(host: host, tournamentId: t.id) } } label: {
                        Label("Import players", systemImage: "square.and.arrow.down")
                    }.disabled(busy)
                    if t.entrantType == .team {
                        Button { run { _ = try await env.tournamentsService.generateTeams(id: t.id) } } label: {
                            Label("Form teams", systemImage: "person.2.badge.gearshape")
                        }.disabled(busy)
                        Button(role: .destructive) { run { try await env.tournamentsService.ungroupTeams(id: t.id) } } label: {
                            Label("Ungroup teams", systemImage: "person.2.slash")
                        }.disabled(busy)
                    }
                }
            }
            if canManage {
                Section("Format") {
                    Picker("Format", selection: Binding(
                        get: { t.format },
                        set: { fmt in run { try await env.tournamentsService.setFormat(id: t.id, format: fmt) } }
                    )) {
                        ForEach([TournamentFormat.single_elim, .round_robin, .pools_bracket], id: \.self) { Text($0.label).tag($0) }
                    }
                    if t.format == .pools_bracket {
                        Stepper("Pools: \(poolCount)", value: $poolCount, in: 2...8)
                        Stepper("Advance per pool: \(advance)", value: $advance, in: 1...8)
                    }
                    Button {
                        run {
                            switch t.format {
                            case .single_elim:   try await env.tournamentsService.generateBracket(id: t.id)
                            case .round_robin:   try await env.tournamentsService.generateRoundRobin(id: t.id)
                            case .pools_bracket: try await env.tournamentsService.generatePools(id: t.id, poolCount: poolCount, advance: advance)
                            }
                        }
                    } label: { Label("Generate \(t.format.label.lowercased())", systemImage: "wand.and.stars") }
                        .disabled(busy || t.entrants.count < 2)
                }
            }
        }
    }

    // MARK: Bracket

    private func bracketSection(_ t: Tournament) -> some View {
        ForEach(1...max(1, t.maxRound), id: \.self) { round in
            let ms = t.bracketMatches.filter { $0.round == round }
            if !ms.isEmpty {
                Section(roundName(round: round, maxRound: t.maxRound)) {
                    ForEach(ms) { m in matchRow(t, m) }
                }
            }
        }
    }

    private func roundName(round: Int, maxRound: Int) -> String {
        let fromEnd = maxRound - round
        switch fromEnd {
        case 0: return "Final"
        case 1: return "Semifinals"
        case 2: return "Quarterfinals"
        default: return "Round \(round)"
        }
    }

    // MARK: Round-robin

    private func roundRobinSection(_ t: Tournament) -> some View {
        Group {
            Section("Standings") {
                standingsTable(t.standings(), showScores: t.hasAnyScores)
            }
            Section("Games") {
                ForEach(t.matches.sorted { $0.round == $1.round ? $0.position < $1.position : $0.round < $1.round }) { m in
                    matchRow(t, m)
                }
            }
        }
    }

    // MARK: Pools → bracket

    private func poolsSection(_ t: Tournament) -> some View {
        Group {
            ForEach(t.poolLabels, id: \.self) { pool in
                Section("Pool \(pool)") {
                    standingsTable(t.standings(pool: pool), showScores: t.hasAnyScores)
                }
            }
            Section("Pool games") {
                ForEach(t.matches.filter { $0.stage == .pool }) { m in matchRow(t, m) }
            }
            if t.poolStageComplete && !t.hasKnockoutBracket && canManage {
                Section {
                    Button { run { try await env.tournamentsService.generateBracketFromPools(id: t.id) } } label: {
                        Label("Generate knockout bracket", systemImage: "wand.and.stars")
                    }.disabled(busy)
                }
            }
            if t.hasKnockoutBracket {
                bracketSection(t)
            }
        }
    }

    // MARK: Shared rows

    private func standingsTable(_ rows: [Standing], showScores: Bool) -> some View {
        VStack(spacing: 4) {
            ForEach(rows) { r in
                HStack(spacing: 8) {
                    Text("\(r.rank)").font(.mlrScaled(12, weight: .bold)).foregroundStyle(Color.mlrTextMuted).frame(width: 20, alignment: .leading)
                    Text(r.name).font(.mlrScaled(14)).lineLimit(1)
                    Spacer()
                    Text(r.record).font(.mlrScaled(13, weight: .medium)).monospacedDigit()
                    if showScores {
                        Text(r.diff >= 0 ? "+\(r.diff)" : "\(r.diff)")
                            .font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func matchRow(_ t: Tournament, _ m: TournamentMatch) -> some View {
        let done = m.status == .complete
        let bothSet = m.slot1EntrantId != nil && m.slot2EntrantId != nil
        return Button {
            if canManage && bothSet { resultMatch = m }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    slotLine(t.entrantName(m.slot1EntrantId), score: m.slot1Score, won: done && m.winnerEntrantId == m.slot1EntrantId)
                    slotLine(t.entrantName(m.slot2EntrantId), score: m.slot2Score, won: done && m.winnerEntrantId == m.slot2EntrantId)
                }
                Spacer()
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.mlrSuccess)
                } else if canManage && bothSet {
                    Text("Record").font(.mlrScaled(11, weight: .bold)).foregroundStyle(Color.mlrPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!(canManage && bothSet))
    }

    private func slotLine(_ name: String, score: Int?, won: Bool) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.mlrScaled(14, weight: won ? .bold : .regular))
                .foregroundStyle(won ? Color.mlrText : Color.mlrTextMuted)
                .lineLimit(1)
            if let score { Text("\(score)").font(.mlrScaled(13, weight: .semibold)).monospacedDigit() }
        }
    }

    // MARK: Data

    private func reload() async {
        let list = await env.tournamentsService.fetch(host: host)
        tournament = list.first
        loading = false
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; errorText = nil
        Task {
            do { try await work() } catch { errorText = "Something went wrong. Try again." }
            await reload()
            busy = false
        }
    }
}

// MARK: - Match result sheet

private struct MatchResultSheet: View {
    let tournament: Tournament?
    let match: TournamentMatch
    let onRecord: (UUID, Int?, Int?) -> Void
    let onClear: () -> Void
    var onChanged: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var s1 = ""
    @State private var s2 = ""
    @State private var winner: UUID?
    @State private var hasTime = false
    @State private var matchTime = Date()
    @State private var busy = false

    private var name1: String { tournament?.entrantName(match.slot1EntrantId) ?? "—" }
    private var name2: String { tournament?.entrantName(match.slot2EntrantId) ?? "—" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Score (optional)") {
                    HStack { Text(name1); Spacer(); TextField("0", text: $s1).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 60) }
                    HStack { Text(name2); Spacer(); TextField("0", text: $s2).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 60) }
                }
                Section("Winner") {
                    Picker("Winner", selection: $winner) {
                        Text(name1).tag(match.slot1EntrantId as UUID?)
                        Text(name2).tag(match.slot2EntrantId as UUID?)
                    }
                    .pickerStyle(.inline)
                }
                // Schedule the match + ping the two players (migration 0148).
                Section("Schedule") {
                    Toggle("Set a time", isOn: $hasTime)
                    if hasTime { DatePicker("When", selection: $matchTime) }
                    Button(busy ? "Saving…" : "Save time") {
                        Task { await save { try await env.tournamentsService.scheduleMatch(matchId: match.id, at: hasTime ? matchTime : nil) } }
                    }.disabled(busy)
                }
                Section("Notify players") {
                    Button("“Up next!”") {
                        Task { await save { try await env.tournamentsService.notifyMatch(matchId: match.id, when: "is up next!") } }
                    }
                    Button("“In about 15 minutes”") {
                        Task { await save { try await env.tournamentsService.notifyMatch(matchId: match.id, when: "is in about 15 minutes") } }
                    }
                }
                .disabled(busy)

                if match.status == .complete {
                    Section {
                        Button(role: .destructive) { onClear(); dismiss() } label: { Text("Clear result") }
                    }
                }
            }
            .navigationTitle("Record result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let w = winner { onRecord(w, Int(s1), Int(s2)); dismiss() }
                    }.disabled(winner == nil)
                }
            }
            .onAppear {
                winner = match.winnerEntrantId ?? match.slot1EntrantId
                if let v = match.slot1Score { s1 = "\(v)" }
                if let v = match.slot2Score { s2 = "\(v)" }
                if let at = match.scheduledAt { hasTime = true; matchTime = at }
            }
        }
    }

    private func save(_ work: @escaping () async throws -> Void) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        try? await work()
        onChanged()
    }
}
