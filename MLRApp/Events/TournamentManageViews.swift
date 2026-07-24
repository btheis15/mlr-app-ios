import SwiftUI

// MARK: - TournamentSetupSheet
//
// Create a tournament, or manage one still in setup: switch format, import /
// re-sync players, auto-make teams, hand-order the seeds (drag to reorder),
// remove players, add someone by hand, set the bye framing (with a live first-
// round preview), and generate. Mirrors TournamentSetupSheet.tsx.

struct TournamentSetupSheet: View {
    let host: TournamentHost
    let tournament: Tournament?
    let onChanged: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.editMode) private var editMode

    // Own fresh copy so manage actions reflect immediately.
    @State private var current: Tournament?
    @State private var order: [UUID] = []
    @State private var busy = false
    @State private var note: String?
    @State private var errorText: String?

    // Create-mode fields.
    @State private var newTitle = ""
    @State private var newFormat: TournamentFormat = .single_elim
    @State private var newEntrantType: EntrantType = .individual
    @State private var newTeamSize = 2
    // Manage-mode fields.
    @State private var poolCount = 2
    @State private var advance = 1
    @State private var byeStrategy: ByeStrategy = .byes
    @State private var addName = ""

    var body: some View {
        Group {
            if let t = current {
                manage(t)
            } else {
                create
            }
        }
        .navigationTitle(current == nil ? "New tournament" : "Set up")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            if current != nil {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .onAppear {
            current = tournament
            newTitle = "Tournament"
            if let t = tournament { syncFrom(t) }
        }
    }

    // MARK: Create

    private var create: some View {
        Form {
            Section("Name") { TextField("e.g. Cornhole tournament", text: $newTitle) }
            Section("Format") {
                Picker("Format", selection: $newFormat) {
                    Text("Bracket").tag(TournamentFormat.single_elim)
                    Text("Round-robin").tag(TournamentFormat.round_robin)
                    Text("Pools").tag(TournamentFormat.pools_bracket)
                }.pickerStyle(.segmented)
                Text(formatBlurb(newFormat)).font(.mlrScaled(12)).foregroundStyle(.secondary)
            }
            Section("Who competes") {
                Picker("Entrants", selection: $newEntrantType) {
                    Text("Individuals").tag(EntrantType.individual)
                    Text("Teams").tag(EntrantType.team)
                }.pickerStyle(.segmented)
                if newEntrantType == .team {
                    Stepper("People per team: \(newTeamSize)", value: $newTeamSize, in: 2...6)
                }
            }
            if let errorText { Section { Text(errorText).foregroundStyle(Color.mlrDanger).font(.mlrScaled(13)) } }
            Section {
                Button(busy ? "Creating…" : "Create tournament") { Task { await doCreate() } }
                    .disabled(busy || newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Manage

    private func manage(_ t: Tournament) -> some View {
        List {
            Section("Format") {
                Picker("Format", selection: Binding(get: { t.format }, set: { f in if f != t.format { run { try await env.tournamentsService.setFormat(id: t.id, format: f) } } })) {
                    Text("Bracket").tag(TournamentFormat.single_elim)
                    Text("Round-robin").tag(TournamentFormat.round_robin)
                    Text("Pools").tag(TournamentFormat.pools_bracket)
                }.pickerStyle(.segmented)
                Text(formatBlurb(t.format)).font(.mlrScaled(12)).foregroundStyle(.secondary)
            }

            Section("Players") {
                Button { run { _ = try await env.tournamentsService.importEntrants(host: host, tournamentId: t.id) } } label: {
                    Label(isActivityHost ? "Re-sync players from activity" : "Pull in everyone who signed up", systemImage: "arrow.down.circle")
                }.disabled(busy)
                if t.entrantType == .team {
                    Button { run { _ = try await env.tournamentsService.generateTeams(id: t.id) } } label: {
                        Label("Auto-make teams", systemImage: "die.face.5")
                    }.disabled(busy)
                    Button(role: .destructive) { run { try await env.tournamentsService.ungroupTeams(id: t.id) } } label: {
                        Label("Undo teams", systemImage: "arrow.uturn.backward")
                    }.disabled(busy)
                }
            }

            // Drag-to-reorder seeds (tap Edit, then drag). Swipe a row to remove.
            if !order.isEmpty {
                Section {
                    ForEach(Array(order.enumerated()), id: \.element) { idx, id in
                        HStack {
                            Text("\(idx + 1)").font(.mlrScaled(12, weight: .bold)).foregroundStyle(Color.mlrTextMuted).frame(width: 22, alignment: .leading)
                            Text(t.entrants.first { $0.id == id }?.displayName ?? "—").font(.mlrScaled(15))
                        }
                    }
                    .onMove { from, to in order.move(fromOffsets: from, toOffset: to) }
                    .onDelete { offsets in
                        let ids = offsets.map { order[$0] }
                        order.remove(atOffsets: offsets)
                        run { for id in ids { try await env.tournamentsService.removeEntrant(entrantId: id) } }
                    }
                } header: {
                    Text("Seed order — top seeds first")
                } footer: {
                    Text("Tap Edit, then drag to set the seeding (byes go to the top). Swipe to remove.")
                }
            }

            if !t.pool.isEmpty {
                Section(t.entrantType == .team ? "Not yet on a team" : "Not yet seeded") {
                    ForEach(t.pool) { p in
                        Text(p.name).font(.mlrScaled(14))
                            .swipeActions {
                                Button(role: .destructive) { run { try await env.tournamentsService.removeParticipant(participantId: p.id) } } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
                }
            }

            Section("Add someone by hand") {
                HStack {
                    TextField("Name (works for people not on the app)", text: $addName)
                    Button("Add") {
                        let name = addName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        addName = ""
                        run { _ = try await env.tournamentsService.addParticipant(id: t.id, forUser: nil, name: name) }
                    }.disabled(addName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
            }

            if t.format == .pools_bracket && order.count >= 2 {
                Section("Pools") {
                    Stepper("Pools: \(poolCount)", value: $poolCount, in: 2...8)
                    Stepper("Advance per pool: \(advance)", value: $advance, in: 1...8)
                    Text("\(order.count) entrants → \(poolCount) pools; top \(advance) each (\(poolCount * advance) advance).")
                        .font(.mlrScaled(12)).foregroundStyle(.secondary)
                }
            }

            if t.format == .single_elim && order.count >= 2 {
                Section("Uneven bracket") {
                    Picker("Byes", selection: Binding(get: { byeStrategy }, set: { v in byeStrategy = v; run { try await env.tournamentsService.setByeStrategy(id: t.id, strategy: v) } })) {
                        Text("Byes").tag(ByeStrategy.byes)
                        Text("Play-in").tag(ByeStrategy.play_in)
                    }.pickerStyle(.segmented)
                    Text(BracketMath.bracketSummary(order.count, byeStrategy)).font(.mlrScaled(12)).foregroundStyle(.secondary)
                    let preview = BracketMath.firstRoundPreview(order.compactMap { id in t.entrants.first { $0.id == id }?.displayName }, byeStrategy)
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, m in
                        HStack {
                            Text(m.a ?? "Bye").foregroundStyle(m.a == nil ? Color.mlrTextSubtle : Color.mlrText)
                            Spacer()
                            Text(m.isBye ? "→" : "vs").foregroundStyle(Color.mlrTextSubtle)
                            Spacer()
                            Text(m.b ?? "Bye").foregroundStyle(m.b == nil ? Color.mlrTextSubtle : Color.mlrText)
                        }.font(.mlrScaled(12))
                    }
                }
            }

            if let note { Section { Text(note).foregroundStyle(Color.mlrPrimary).font(.mlrScaled(13)) } }
            if let errorText { Section { Text(errorText).foregroundStyle(Color.mlrDanger).font(.mlrScaled(13)) } }

            Section {
                Button(generateLabel(t)) { Task { await doGenerate(t) } }
                    .disabled(busy || readyCount(t) < 2)
                    .frame(maxWidth: .infinity).fontWeight(.semibold)
            }
            Section {
                Button("Clear seeding & bracket", role: .destructive) { run { try await env.tournamentsService.resetBracket(id: t.id) } }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Actions

    private func doCreate() async {
        busy = true; errorText = nil; defer { busy = false }
        do {
            let id = try await env.tournamentsService.createForHost(
                host, title: newTitle.trimmingCharacters(in: .whitespaces), format: newFormat,
                entrantType: newEntrantType, teamSize: newEntrantType == .team ? newTeamSize : nil)
            _ = try? await env.tournamentsService.importEntrants(host: host, tournamentId: id)
            onChanged()
            await refresh()   // flip into manage mode on the fresh tournament
        } catch {
            errorText = "Couldn't create it. Try again."
        }
    }

    private func doGenerate(_ t: Tournament) async {
        busy = true; errorText = nil; defer { busy = false }
        let seed = order.count >= 2 ? order : nil
        do {
            switch t.format {
            case .single_elim:   try await env.tournamentsService.generateBracket(id: t.id, seedOrder: seed)
            case .round_robin:   try await env.tournamentsService.generateRoundRobin(id: t.id, seedOrder: seed)
            case .pools_bracket: try await env.tournamentsService.generatePools(id: t.id, poolCount: poolCount, advance: advance, seedOrder: seed)
            }
            onChanged()
            dismiss()
        } catch {
            errorText = "Couldn't generate. Try again."
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; errorText = nil; note = nil
        Task {
            do { try await work() } catch { errorText = "Something went wrong. Try again." }
            await refresh()
            onChanged()
            busy = false
        }
    }

    private func refresh() async {
        let list = await env.tournamentsService.fetch(host: host)
        if let t = list.first { current = t; syncFrom(t) }
    }

    private func syncFrom(_ t: Tournament) {
        order = t.entrants.map(\.id)
        byeStrategy = t.byeStrategy
        poolCount = t.poolCount ?? 2
        advance = t.advancePerPool ?? 1
    }

    // MARK: Helpers

    private var isActivityHost: Bool {
        if case .activity = host { return true }
        return false
    }
    private func readyCount(_ t: Tournament) -> Int {
        t.entrantType == .individual ? order.count + t.pool.count : order.count
    }
    private func generateLabel(_ t: Tournament) -> String {
        if readyCount(t) < 2 { return "Add at least 2 players" }
        switch t.format {
        case .single_elim:   return "Generate bracket"
        case .round_robin:   return "Generate schedule"
        case .pools_bracket: return "Generate pools"
        }
    }
    private func formatBlurb(_ f: TournamentFormat) -> String {
        switch f {
        case .single_elim:   return "Single elimination — lose and you're out."
        case .round_robin:   return "Everyone plays everyone; ranked by a standings table."
        case .pools_bracket: return "Group play in pools, then the top of each advance to a knockout."
        }
    }
}

// MARK: - MatchResultSheet
//
// Record (or change) a result: the primary action is one tap on the winner —
// scores are optional (an expander reveals +/- steppers). Reopening a decided
// match warns if downstream matches will be reset. Also schedules the match +
// pushes the two players. Mirrors MatchResultSheet.tsx.

struct MatchResultSheet: View {
    let tournament: Tournament?
    let match: TournamentMatch
    let onChanged: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var winner: UUID?
    @State private var showScores = false
    @State private var s1 = 0
    @State private var s2 = 0
    @State private var hasTime = false
    @State private var matchTime = Date()
    @State private var remind = false
    @State private var busy = false
    @State private var notice: String?
    @State private var errorText: String?

    private var e1: UUID? { match.slot1EntrantId }
    private var e2: UUID? { match.slot2EntrantId }
    private var decided: Bool { match.winnerEntrantId != nil }
    private var bothSet: Bool { e1 != nil && e2 != nil }
    private func name(_ id: UUID?) -> String { tournament?.entrantName(id) ?? "—" }

    /// Downstream matches (via next_match chain) that already hold a result and
    /// would be reset if the winner changes.
    private var downstreamToReset: [TournamentMatch] {
        guard let t = tournament, decided else { return [] }
        let byId = Dictionary(t.matches.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [TournamentMatch] = []
        var cur = match.nextMatchId.flatMap { byId[$0] }
        while let c = cur, c.winnerEntrantId != nil { out.append(c); cur = c.nextMatchId.flatMap { byId[$0] } }
        return out
    }
    private var willReset: Bool { decided && winner != match.winnerEntrantId && !downstreamToReset.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tap the winner") {
                    winnerButton(e1, score: $s1)
                    winnerButton(e2, score: $s2)
                    Button(showScores ? "Hide scores" : "Add scores (optional)") { showScores.toggle() }
                        .font(.mlrScaled(14, weight: .medium)).foregroundStyle(Color.mlrPrimary)
                }

                if bothSet && match.status != .complete {
                    Section("Notify players") {
                        Button("📣 Up next") { Task { await notify("is up next!") } }.disabled(busy)
                        Button("📣 In ~15 minutes") { Task { await notify("is in about 15 minutes") } }.disabled(busy)
                    }
                    Section("Schedule (optional)") {
                        Toggle("Set a time", isOn: $hasTime)
                        if hasTime {
                            DatePicker("When", selection: $matchTime)
                            Toggle("Auto-remind 15 min before", isOn: $remind)
                        }
                        Button(hasTime ? "Save time" : "Clear time") { Task { await saveSchedule() } }.disabled(busy)
                    }
                    if let notice { Section { Text(notice).foregroundStyle(Color.mlrPrimary).font(.mlrScaled(13)) } }
                }

                if willReset {
                    Section {
                        Label("Changing this resets \(downstreamToReset.count) later match\(downstreamToReset.count == 1 ? "" : "es") so they can be replayed.", systemImage: "exclamationmark.triangle.fill")
                            .font(.mlrScaled(12)).foregroundStyle(Color.mlrWarning)
                    }
                }
                if let errorText { Section { Text(errorText).foregroundStyle(Color.mlrDanger).font(.mlrScaled(13)) } }

                if decided {
                    Section {
                        Button("Clear this result", role: .destructive) { Task { await clear() } }.disabled(busy)
                    }
                }
            }
            .navigationTitle(decided ? "Change the result" : "Who won?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(willReset ? "Change & reset" : (decided ? "Save" : "Save & advance")) { Task { await save() } }
                        .disabled(winner == nil || busy).fontWeight(.semibold)
                }
            }
            .onAppear {
                winner = match.winnerEntrantId ?? match.slot1EntrantId
                showScores = match.slot1Score != nil || match.slot2Score != nil
                s1 = match.slot1Score ?? 0; s2 = match.slot2Score ?? 0
                if let at = match.scheduledAt { hasTime = true; matchTime = at }
                remind = !(match.reminderMinutes ?? []).isEmpty
            }
        }
    }

    @ViewBuilder
    private func winnerButton(_ id: UUID?, score: Binding<Int>) -> some View {
        let picked = winner != nil && winner == id
        VStack(spacing: 8) {
            Button { if let id { winner = id } } label: {
                HStack {
                    Text(name(id)).font(.mlrScaled(16, weight: .semibold)).foregroundStyle(Color.mlrText)
                    Spacer()
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(picked ? Color.mlrPrimary : Color.mlrTextSubtle)
                }
            }
            .disabled(id == nil)
            if showScores {
                Stepper("Score: \(score.wrappedValue)", value: score, in: 0...199)
                    .font(.mlrScaled(13))
            }
        }
    }

    // MARK: Actions

    private func save() async {
        guard let w = winner else { return }
        busy = true; errorText = nil; defer { busy = false }
        do {
            try await env.tournamentsService.recordResult(matchId: match.id, winnerId: w, score1: showScores ? s1 : nil, score2: showScores ? s2 : nil)
            onChanged(); dismiss()
        } catch { errorText = "Couldn't save — try again." }
    }
    private func clear() async {
        busy = true; defer { busy = false }
        do { try await env.tournamentsService.clearResult(matchId: match.id); onChanged(); dismiss() }
        catch { errorText = "Couldn't clear — try again." }
    }
    private func notify(_ phrase: String) async {
        busy = true; notice = nil; defer { busy = false }
        do { try await env.tournamentsService.notifyMatch(matchId: match.id, when: phrase); notice = "Sent ✓" }
        catch { notice = "Couldn't send." }
    }
    private func saveSchedule() async {
        busy = true; notice = nil; defer { busy = false }
        do {
            try await env.tournamentsService.scheduleMatch(matchId: match.id, at: hasTime ? matchTime : nil, reminderMinutes: (hasTime && remind) ? [15] : [])
            notice = hasTime ? "Scheduled ✓" : "Cleared ✓"; onChanged()
        } catch { notice = "Couldn't save the time." }
    }
}
