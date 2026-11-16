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
    @State private var newTarget = 0        // 0 = no target score
    @State private var newWinBy = 1
    @State private var preset: GamePreset?
    // Manage-mode fields.
    @State private var poolCount = 2
    @State private var advance = 1
    @State private var byeStrategy: ByeStrategy = .byes
    @State private var addName = ""
    @State private var targetEdit = 0
    @State private var winByEdit = 1
    @State private var confirmStart = false
    // Danger area (0224): saved copies + confirmations.
    @State private var snapshots: [TournamentSnapshot]?     // nil = feature not available
    @State private var confirmReset = false
    @State private var pendingRestore: TournamentSnapshot?

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
            if let c = current, c.status == .setup {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
        }
        .onAppear {
            current = tournament
            newTitle = "Tournament"
            if let t = tournament { syncFrom(t) }
        }
        .task { await loadSnapshots() }
        // Someone else started or changed the tournament while this sheet is open.
        .onChange(of: tournament?.status) { _, _ in Task { await refresh() } }
        .confirmationDialog(
            "Start the tournament?", isPresented: $confirmStart, titleVisibility: .visible
        ) {
            if let t = current {
                Button("Start tournament") { Task { await doGenerate(t) } }
            }
            Button("Not yet", role: .cancel) {}
        } message: {
            Text("The bracket locks once it starts: the seeding and players can't be changed without erasing results. You can still start over from this screen, and a copy is saved first.")
        }
        .confirmationDialog(
            resetTitle, isPresented: $confirmReset, titleVisibility: .visible
        ) {
            if let t = current {
                let played = t.playedCount
                Button(played > 0 ? "Erase \(played) result\(played == 1 ? "" : "s") and start over" : "Start over",
                       role: .destructive) {
                    run { try await env.tournamentsService.resetBracket(id: t.id, confirm: played > 0) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetMessage)
        }
        .confirmationDialog(
            "Restore this copy?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible, presenting: pendingRestore
        ) { snap in
            Button("Restore this copy", role: .destructive) {
                run { try await env.tournamentsService.restoreSnapshot(id: snap.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { snap in
            let now = current?.playedCount ?? 0
            Text("This puts the tournament back to how it was \(Self.relative(snap.takenAt)) (\(snap.playedMatches) game\(snap.playedMatches == 1 ? "" : "s") played). Right now it has \(now) recorded result\(now == 1 ? "" : "s"). Your current state is saved first, so you can undo this.")
        }
    }

    // MARK: Create

    private var create: some View {
        Form {
            Section("Game") {
                GamePresetRow(selection: $preset) { p in applyPreset(p) }
            }
            Section("Name") { TextField("e.g. Cornhole tournament", text: $newTitle) }
            Section {
                Stepper(newTarget == 0 ? "Play to: no target" : "Play to: \(newTarget)", value: $newTarget, in: 0...100)
                if newTarget > 0 {
                    Stepper("Win by: \(newWinBy)", value: $newWinBy, in: 1...5)
                }
            } header: {
                Text("Scoring")
            } footer: {
                Text("Starting points you can change. They drive the quick scores when you enter a result.")
            }
            Section("Format") {
                FormatCards(selection: $newFormat)
                Text(formatBlurb(newFormat)).font(.mlrScaled(12)).foregroundStyle(.secondary)
            }
            Section {
                Picker("Entrants", selection: $newEntrantType) {
                    Text("Individuals").tag(EntrantType.individual)
                    Text("Teams").tag(EntrantType.team)
                }.pickerStyle(.segmented)
                if newEntrantType == .team {
                    Stepper("People per team: \(newTeamSize)", value: $newTeamSize, in: 2...6)
                }
            } header: {
                Text("Who competes")
            } footer: {
                Text("Players come from this activity's guest list. Next you can add anyone by hand, shuffle or drag the seeds, and preview the bracket.")
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
            if t.status != .setup {
                lockedBody(t)
            } else {
                setupBody(t)
            }

            if let note { Section { Text(note).foregroundStyle(Color.mlrPrimary).font(.mlrScaled(13)) } }
            if let errorText { Section { Text(errorText).foregroundStyle(Color.mlrDanger).font(.mlrScaled(13)) } }

            if t.status == .setup {
                Section {
                    Button { confirmStart = true } label: {
                        Text(generateLabel(t)).font(.mlrScaled(17, weight: .bold)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(busy || readyCount(t) < 2)
                } footer: {
                    Text("The bracket locks once the tournament starts.")
                }
            }

            dangerArea(t)
        }
    }

    /// Live or complete: nothing that could reshuffle the bracket is offered.
    @ViewBuilder
    private func lockedBody(_ t: Tournament) -> some View {
        Section {
            Label("This tournament is under way. The bracket is locked so nothing gets reshuffled by accident.",
                  systemImage: "lock.fill")
                .font(.mlrScaled(13)).foregroundStyle(Color.mlrTextMuted)
        }
        if !t.entrants.isEmpty {
            Section("Players") {
                ForEach(t.entrants) { e in
                    HStack {
                        if let seed = e.seed {
                            Text("\(seed)").font(.mlrScaled(12, weight: .bold)).foregroundStyle(Color.mlrTextMuted).frame(width: 22, alignment: .leading)
                        }
                        Text(e.displayName).font(.mlrScaled(15))
                    }
                }
            }
        }
        Section("Add someone by hand") {
            addByHandRow(t)
        }
    }

    @ViewBuilder
    private func addByHandRow(_ t: Tournament) -> some View {
        HStack {
            TextField("Name (works for people not on the app)", text: $addName)
            Button("Add") {
                let name = addName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !busy else { return }
                addName = ""
                run { _ = try await env.tournamentsService.addParticipant(id: t.id, forUser: nil, name: name) }
            }.disabled(addName.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
    }

    @ViewBuilder
    private func setupBody(_ t: Tournament) -> some View {
        Section("Format") {
            FormatCards(selection: Binding(get: { t.format }, set: { f in if f != t.format { run { try await env.tournamentsService.setFormat(id: t.id, format: f) } } }))
                .disabled(busy)
            Text(formatBlurb(t.format)).font(.mlrScaled(12)).foregroundStyle(.secondary)
        }

        Section("Players") {
            Button { run { _ = try await env.tournamentsService.importEntrants(host: host, tournamentId: t.id) } } label: {
                Label(isActivityHost ? "Re-sync players from activity" : "Pull in everyone who signed up", systemImage: "arrow.down.circle")
            }.disabled(busy)
            if order.count >= 2 {
                Button {
                    Haptics.select()
                    withAnimation(MLRMotion.reduceMotion ? nil : MLRMotion.spring) { order.shuffle() }
                } label: { Label("Shuffle seeds", systemImage: "shuffle") }
                    .disabled(busy)
            }
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
                .onMove { from, to in Haptics.select(); order.move(fromOffsets: from, toOffset: to) }
                .onDelete { offsets in
                    guard !busy else { return }
                    let ids = offsets.map { order[$0] }
                    order.remove(atOffsets: offsets)
                    run { for id in ids { try await env.tournamentsService.removeEntrant(entrantId: id) } }
                }
            } header: {
                Text("Seed order — top seeds first")
            } footer: {
                Text("Shuffle for a random draw, or tap Edit and drag players into the order you want (byes go to the top seeds). Swipe to remove. Seeding is only possible before the tournament starts.")
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
            addByHandRow(t)
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
            }
        }

        if order.count >= 2 {
            Section {
                TournamentSetupPreview(
                    names: order.compactMap { id in t.entrants.first { $0.id == id }?.displayName },
                    format: t.format, strategy: byeStrategy, poolCount: poolCount, advance: advance)
            } header: {
                Text("Preview: how it will play")
            }
        }

        Section {
            Stepper(targetEdit == 0 ? "Play to: no target" : "Play to: \(targetEdit)", value: $targetEdit, in: 0...100)
            if targetEdit > 0 { Stepper("Win by: \(winByEdit)", value: $winByEdit, in: 1...5) }
        } header: {
            Text("Scoring")
        } footer: {
            Text("Drives the quick scores when entering results.")
        }
    }

    // MARK: Danger area (managers only; this sheet is never shown to others or while previewing)

    @ViewBuilder
    private func dangerArea(_ t: Tournament) -> some View {
        Section {
            Button(role: .destructive) { confirmReset = true } label: {
                Label(t.status == .setup ? "Clear seeding & bracket" : "Start over", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .disabled(busy)

            if let snaps = snapshots, !snaps.isEmpty {
                ForEach(snaps) { snap in
                    Button { pendingRestore = snap } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snap.reasonLabel).font(.mlrScaled(14, weight: .medium)).foregroundStyle(Color.mlrText)
                            Text("\(Self.relative(snap.takenAt)) · \(snap.playedMatches) game\(snap.playedMatches == 1 ? "" : "s") played")
                                .font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                        }
                    }
                    .disabled(busy)
                }
            }
        } header: {
            Text("Danger area")
        } footer: {
            if let snaps = snapshots, !snaps.isEmpty {
                Text("Restore an earlier copy: tap one above. Your current state is saved first.")
            }
        }
    }

    private var resetTitle: String {
        let n = current?.playedCount ?? 0
        return n > 0 ? "Start over and erase \(n) result\(n == 1 ? "" : "s")?" : "Clear the seeding and bracket?"
    }
    private var resetMessage: String {
        let n = current?.playedCount ?? 0
        if n > 0 {
            return "This erases \(n) recorded result\(n == 1 ? "" : "s") and takes the tournament back to setup. A copy is saved first, so you can restore it from here."
        }
        return "Nothing has been played yet. This clears the seeding and bracket so you can set them up again."
    }

    private static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    // MARK: Actions

    private func doCreate() async {
        guard !busy else { return }
        busy = true; errorText = nil; defer { busy = false }
        do {
            // Never create over a tournament that already exists (stale screen).
            if let existing = try await env.tournamentsService.fetchChecked(host: host).first {
                current = existing; syncFrom(existing); onChanged()
                return
            }
            let id = try await env.tournamentsService.createForHost(
                host, title: newTitle.trimmingCharacters(in: .whitespaces), format: newFormat,
                entrantType: newEntrantType, teamSize: newEntrantType == .team ? newTeamSize : nil)
            _ = try? await env.tournamentsService.importEntrants(host: host, tournamentId: id)
            if newTarget > 0 {
                try? await env.tournamentsService.setScoring(id: id, targetScore: newTarget, winBy: newWinBy)
            }
            onChanged()
            await refresh()   // flip into manage mode on the fresh tournament
        } catch {
            errorText = TournamentsService.message(for: error, fallback: "Couldn't create it. Try again.")
        }
    }

    private func doGenerate(_ t: Tournament) async {
        guard !busy, t.status == .setup else { return }
        busy = true; errorText = nil; defer { busy = false }
        let seed = order.count >= 2 ? order : nil
        do {
            // Scoring rules ride along (set-only: the server keeps the old value for nulls).
            if targetEdit > 0, targetEdit != (t.targetScore ?? 0) || winByEdit != (t.winBy ?? 1) {
                try await env.tournamentsService.setScoring(id: t.id, targetScore: targetEdit, winBy: winByEdit)
            }
            switch t.format {
            case .single_elim:   try await env.tournamentsService.generateBracket(id: t.id, seedOrder: seed)
            case .round_robin:   try await env.tournamentsService.generateRoundRobin(id: t.id, seedOrder: seed)
            case .pools_bracket: try await env.tournamentsService.generatePools(id: t.id, poolCount: poolCount, advance: advance, seedOrder: seed)
            }
            onChanged()
            dismiss()
        } catch {
            errorText = TournamentsService.message(for: error, fallback: "Couldn't generate. Try again.")
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; errorText = nil; note = nil
        Task {
            do { try await work() } catch { errorText = TournamentsService.message(for: error) }
            await refresh()
            await loadSnapshots()
            onChanged()
            busy = false
        }
    }

    private func refresh() async {
        // A failed fetch keeps what is on screen; it never blanks the sheet.
        guard let list = try? await env.tournamentsService.fetchChecked(host: host) else {
            if errorText == nil { errorText = "Couldn't refresh. Pull the latest by closing and reopening this." }
            return
        }
        if let t = list.first { current = t; syncFrom(t) }
    }

    private func loadSnapshots() async {
        guard let t = current ?? tournament else { return }
        // Missing table or any failure: hide the restore list rather than error.
        snapshots = try? await env.tournamentsService.fetchSnapshots(tournamentId: t.id)
    }

    private func syncFrom(_ t: Tournament) {
        order = t.entrants.map(\.id)
        byeStrategy = t.byeStrategy
        poolCount = t.poolCount ?? 2
        advance = t.advancePerPool ?? 1
        // Keep a value the user is mid-way through editing; adopt the server's otherwise.
        if t.targetScore != nil || targetEdit == 0 { targetEdit = t.targetScore ?? targetEdit }
        winByEdit = t.winBy ?? winByEdit
    }

    private func applyPreset(_ p: GamePreset) {
        let old = preset?.title
        // Only retitle when the name is still a default, never over something typed.
        if newTitle == "Tournament" || newTitle == old || newTitle.isEmpty { newTitle = p.title }
        newTarget = p.target ?? 0
        newWinBy = p.winBy ?? 1
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
        case .single_elim, .round_robin, .pools_bracket: return "Start tournament"
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

// MARK: - Game presets (editable starting points only)

struct GamePreset: Identifiable, Equatable {
    let id: String
    let emoji: String
    let name: String
    let target: Int?
    let winBy: Int?
    var title: String { name == "Other" ? "Tournament" : "\(name) tournament" }

    static let all: [GamePreset] = [
        GamePreset(id: "bags", emoji: "🎯", name: "Bags", target: 21, winBy: nil),
        GamePreset(id: "pingpong", emoji: "🏓", name: "Ping-pong", target: 11, winBy: 2),
        GamePreset(id: "other", emoji: "🎲", name: "Other", target: nil, winBy: nil),
    ]
}

private struct GamePresetRow: View {
    @Binding var selection: GamePreset?
    let onPick: (GamePreset) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(GamePreset.all) { p in
                let picked = selection == p
                Button {
                    onPick(p)
                    selection = p
                } label: {
                    VStack(spacing: 4) {
                        Text(p.emoji).font(.mlrScaled(26))
                        Text(p.name).font(.mlrScaled(12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        if let t = p.target {
                            Text("to \(t)\(p.winBy.map { ", by \($0)" } ?? "")")
                                .font(.mlrScaled(10)).opacity(0.85)
                        }
                    }
                    .foregroundStyle(picked ? .white : Color.mlrPrimary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(picked ? Color.mlrPrimary : Color.mlrPrimaryLight)
                    .clipShape(RoundedRectangle(cornerRadius: MLRRadius.button))
                }
                .buttonStyle(.pressable)
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .mlrFeedback(.selection, trigger: selection)
    }
}

// MARK: - MatchResultSheet
//
// Record (or change) a result in two taps: pick the winner (two big side-by-side
// buttons, nothing pre-selected), then Save & advance. Scores are optional, with big
// steppers, a number pad and quick presets from the tournament's target score.
// Reopening a decided match warns if downstream matches will be reset. Also
// schedules the match + pushes the two players. Mirrors MatchResultSheet.tsx.

struct MatchResultSheet: View {
    let tournament: Tournament?
    let onChanged: () -> Void
    /// Called once a result was actually saved (not for clears or reloads).
    var onSaved: (() -> Void)? = nil
    /// The match as the container last fetched it (changes when realtime or a
    /// refetch brings in someone else's edit while this sheet is open).
    var latest: TournamentMatch?
    /// The match this sheet is currently editing; replaced when it changes underneath us.
    @State private var match: TournamentMatch

    init(tournament: Tournament?, match: TournamentMatch, latest: TournamentMatch? = nil,
         onSaved: (() -> Void)? = nil, onChanged: @escaping () -> Void) {
        self.tournament = tournament
        self.latest = latest
        self.onSaved = onSaved
        self.onChanged = onChanged
        _match = State(initialValue: match)
    }

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pickedWinner: UUID?
    @State private var showScores = false
    @State private var s1 = 0
    @State private var s2 = 0
    @State private var hasTime = false
    @State private var matchTime = Date()
    @State private var remind = false
    @State private var busy = false
    @State private var notice: String?
    @State private var errorText: String?
    @State private var confettiTrigger = 0
    @FocusState private var scoreFocus: Int?

    private var e1: UUID? { match.slot1EntrantId }
    private var e2: UUID? { match.slot2EntrantId }
    private var decided: Bool { match.winnerEntrantId != nil }
    private var bothSet: Bool { e1 != nil && e2 != nil }
    private func name(_ id: UUID?) -> String { tournament?.entrantName(id) ?? "—" }
    private var rules: ScoreRules { tournament?.scoreRules ?? ScoreRules(target: nil, winBy: nil) }

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
    /// Never defaults to slot 1. An explicit pick wins; otherwise differing
    /// scores decide; otherwise an already-decided match keeps its winner.
    private var winner: UUID? {
        if let p = pickedWinner { return p }
        if showScores, bothSet, s1 != s2 { return s1 > s2 ? e1 : e2 }
        return match.winnerEntrantId
    }
    private var scoresContradictPick: Bool {
        guard showScores, bothSet, s1 != s2, let p = pickedWinner else { return false }
        return p != (s1 > s2 ? e1 : e2)
    }
    private var willReset: Bool { decided && winner != match.winnerEntrantId && !downstreamToReset.isEmpty }

    /// Soft note when the entered scores don't fit the target / win-by rules.
    private var rulesNote: String? {
        guard showScores, bothSet, let w = winner, !scoresContradictPick else { return nil }
        return rules.note(winnerScore: w == e1 ? s1 : s2, loserScore: w == e1 ? s2 : s1)
    }

    private var saveTitle: String { willReset ? "Change & reset" : (decided ? "Save" : "Save & advance") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let t = tournament {
                        Text(t.gameLabel(match))
                            .font(.mlrScaled(13, weight: .bold)).foregroundStyle(Color.mlrTextMuted)
                            .textCase(.uppercase).tracking(0.6)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        winnerButton(e1, score: $s1, tag: 1)
                        winnerButton(e2, score: $s2, tag: 2)
                    }

                    quickScores

                    Button { withAnimation(reduceMotion ? nil : MLRMotion.spring) { showScores.toggle() } } label: {
                        Text(showScores ? "Hide scores" : "Add scores (optional)")
                            .font(.mlrScaled(15, weight: .semibold)).foregroundStyle(Color.mlrPrimary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }

                    if scoresContradictPick {
                        warning("The scores favour \(name(s1 > s2 ? e1 : e2)), but you picked \(name(pickedWinner)).")
                    }
                    if let rulesNote { warning(rulesNote) }
                    if willReset {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("This changes a result that later games were built on.").font(.mlrScaled(13, weight: .bold))
                            Text("Changing this resets \(downstreamToReset.count) later match\(downstreamToReset.count == 1 ? "" : "es") so they can be replayed.")
                                .font(.mlrScaled(12))
                        }
                        .foregroundStyle(Color.mlrWarning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.mlrWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityElement(children: .combine)
                    }
                    if let errorText {
                        Text(errorText).font(.mlrScaled(13)).foregroundStyle(Color.mlrDanger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if bothSet && match.status != .complete { notifyAndSchedule }

                    if decided {
                        Button("Clear this result", role: .destructive) { Task { await clear() } }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(busy)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.mlrSurface)
            .safeAreaInset(edge: .bottom) { saveBar }
            .overlay(ConfettiView(trigger: confettiTrigger).allowsHitTesting(false))
            .navigationTitle(decided ? "Change the result" : "Who won?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { scoreFocus = nil }
                }
            }
            .onAppear {
                load(match)
            }
            .onChange(of: latest) { _, new in
                // Someone else changed this game while the sheet is open: reload, don't overwrite.
                guard let new, !Self.sameResult(new, match), !busy else { return }
                adopt(new)
            }
        }
    }

    // MARK: Pieces

    private var saveBar: some View {
        Button { Task { await save() } } label: {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.white) }
                Text(saveTitle).font(.mlrScaled(18, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(winner == nil || busy ? Color.mlrTextSubtle : (willReset ? Color.mlrWarning : Color.mlrPrimary),
                        in: RoundedRectangle(cornerRadius: MLRRadius.button))
        }
        .buttonStyle(.pressable)
        .disabled(winner == nil || busy)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        .background(.bar)
        .accessibilityHint(winner == nil ? "Pick the winner first" : "")
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.mlrScaled(13)).foregroundStyle(Color.mlrWarning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.mlrWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Presets drawn from the target score (e.g. 21): tap "21 to 15" after picking a winner.
    @ViewBuilder
    private var quickScores: some View {
        if let target = rules.target, bothSet, !rules.loserPresets.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(winner == nil ? "Pick the winner, then tap a quick score" : "Quick score")
                    .font(.mlrScaled(12, weight: .semibold)).foregroundStyle(Color.mlrTextMuted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(rules.loserPresets, id: \.self) { p in
                            Button {
                                guard let w = winner else { return }
                                Haptics.select()
                                withAnimation(reduceMotion ? nil : MLRMotion.spring) {
                                    showScores = true
                                    if w == e1 { s1 = target; s2 = p } else { s2 = target; s1 = p }
                                }
                            } label: {
                                Text("\(target) to \(p)")
                                    .font(.mlrScaled(16, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(winner == nil ? Color.mlrTextSubtle : Color.mlrPrimary)
                                    .padding(.horizontal, 16).frame(minHeight: 44)
                                    .background(Color.mlrPrimaryLight, in: Capsule())
                            }
                            .buttonStyle(.pressable)
                            .disabled(winner == nil)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notifyAndSchedule: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Button("📣 Up next") { Task { await notify("is up next!") } }.disabled(busy)
                Button("📣 In ~15 minutes") { Task { await notify("is in about 15 minutes") } }.disabled(busy)
                Divider()
                Toggle("Set a time", isOn: $hasTime)
                if hasTime {
                    DatePicker("When", selection: $matchTime)
                    Toggle("Auto-remind 15 min before", isOn: $remind)
                }
                Button(hasTime ? "Save time" : "Clear time") { Task { await saveSchedule() } }.disabled(busy)
                if let notice { Text(notice).foregroundStyle(Color.mlrPrimary).font(.mlrScaled(13)) }
            }
            .padding(.top, 8)
        } label: {
            Text("Notify players & schedule").font(.mlrScaled(15, weight: .semibold)).foregroundStyle(Color.mlrText)
                .frame(minHeight: 44, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .cardStyle(cornerRadius: MLRRadius.button, elevation: .none)
    }

    @ViewBuilder
    private func winnerButton(_ id: UUID?, score: Binding<Int>, tag: Int) -> some View {
        let picked = winner != nil && winner == id
        let other = winner != nil && !picked
        VStack(spacing: 10) {
            Button {
                if let id { pickedWinner = id; scoreFocus = nil; Haptics.select() }
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.mlrScaled(30))
                        .symbolEffect(.bounce, value: picked)
                    Text(name(id))
                        .font(.mlrScaled(21, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .truncationMode(.middle)
                    Text(picked ? "Winner" : "Tap if they won")
                        .font(.mlrScaled(12, weight: .semibold))
                        .opacity(0.85)
                }
                .foregroundStyle(picked ? Color.white : Color.mlrText)
                .padding(.horizontal, 10).padding(.vertical, 16)
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(picked ? Color.mlrPrimary : Color.mlrCard)
                .clipShape(RoundedRectangle(cornerRadius: MLRRadius.card))
                .overlay(RoundedRectangle(cornerRadius: MLRRadius.card)
                    .strokeBorder(picked ? Color.mlrPrimaryDark : Color.mlrText.opacity(0.3), lineWidth: picked ? 3 : 1.5))
                .opacity(other ? 0.8 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(id == nil)
            .accessibilityLabel("\(name(id)) won")
            .accessibilityAddTraits(picked ? .isSelected : [])

            if showScores {
                ScoreStepper(value: score, name: name(id), focus: $scoreFocus, tag: tag)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    /// Only the result-relevant fields: a changed schedule time is not a conflict.
    private static func sameResult(_ a: TournamentMatch, _ b: TournamentMatch) -> Bool {
        a.slot1EntrantId == b.slot1EntrantId && a.slot2EntrantId == b.slot2EntrantId
            && a.slot1Score == b.slot1Score && a.slot2Score == b.slot2Score
            && a.winnerEntrantId == b.winnerEntrantId && a.status == b.status
    }

    private func load(_ m: TournamentMatch) {
        pickedWinner = nil
        showScores = m.slot1Score != nil || m.slot2Score != nil
        s1 = m.slot1Score ?? 0; s2 = m.slot2Score ?? 0
        if let at = m.scheduledAt { hasTime = true; matchTime = at } else { hasTime = false }
        remind = !(m.reminderMinutes ?? []).isEmpty
    }
    private func adopt(_ m: TournamentMatch) {
        match = m
        load(m)
        notice = nil
        errorText = "This game was just updated by someone else. We reloaded it. Check it and save again if you still want to change it."
    }

    private func save() async {
        guard !busy, let w = winner else { return }
        busy = true; errorText = nil; defer { busy = false }
        do {
            // Never save over a newer result: re-read the game first.
            if let fresh = try await env.tournamentsService.fetchMatch(id: match.id), !Self.sameResult(fresh, match) {
                adopt(fresh); onChanged(); return
            }
            try await env.tournamentsService.recordResult(matchId: match.id, winnerId: w, score1: showScores ? s1 : nil, score2: showScores ? s2 : nil)
            confettiTrigger += 1
            Haptics.success()
            onSaved?()
            onChanged()
            try? await Task.sleep(nanoseconds: 450_000_000)   // let the burst read
            dismiss()
        } catch { errorText = TournamentsService.message(for: error, fallback: "Couldn't save — try again.") }
    }
    private func clear() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { try await env.tournamentsService.clearResult(matchId: match.id); onChanged(); dismiss() }
        catch { errorText = TournamentsService.message(for: error, fallback: "Couldn't clear — try again.") }
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

/// Big minus / number-pad field / plus. 44pt targets, clamped to 0...199.
private struct ScoreStepper: View {
    @Binding var value: Int
    let name: String
    var focus: FocusState<Int?>.Binding
    let tag: Int

    var body: some View {
        HStack(spacing: 4) {
            button("minus", "Decrease") { value = max(0, value - 1) }
            TextField("0", value: $value, format: .number)
                .keyboardType(.numberPad)
                .focused(focus, equals: tag)
                .multilineTextAlignment(.center)
                .font(.mlrScaled(30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 52)
                .accessibilityLabel("\(name) score")
            button("plus", "Increase") { value = min(199, value + 1) }
        }
        .padding(4)
        .background(Color.mlrCard, in: RoundedRectangle(cornerRadius: MLRRadius.button))
        .overlay(RoundedRectangle(cornerRadius: MLRRadius.button).strokeBorder(Color.mlrText.opacity(0.25), lineWidth: 1.5))
        .onChange(of: value) { _, v in
            if v < 0 { value = 0 } else if v > 199 { value = 199 }
        }
        .mlrFeedback(.selection, trigger: value)
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { focus.wrappedValue = nil; action() } label: {
            Image(systemName: symbol).font(.mlrScaled(18, weight: .bold)).foregroundStyle(Color.mlrPrimary)
                .frame(width: 44, height: 52)
                .background(Color.mlrPrimaryLight, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(label) \(name) score")
    }
}


// MARK: - Format selection cards (Phase 2.7)

/// Tappable format cards with icons — replaces the bare segmented picker.
private struct FormatCards: View {
    @Binding var selection: TournamentFormat

    private static let items: [(TournamentFormat, String, String)] = [
        (.single_elim,   "Bracket",     "trophy"),
        (.round_robin,   "Round-robin", "arrow.triangle.2.circlepath"),
        (.pools_bracket, "Pools",       "square.grid.2x2"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.items, id: \.0) { format, label, icon in
                let picked = selection == format
                Button {
                    selection = format
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: icon)
                            .font(.mlrScaled(20, weight: .semibold))
                        Text(label)
                            .font(.mlrScaled(11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(picked ? .white : Color.mlrPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(picked ? Color.mlrPrimary : Color.mlrPrimaryLight)
                    .clipShape(RoundedRectangle(cornerRadius: MLRRadius.button))
                }
                .buttonStyle(.pressable)
            }
        }
        .mlrFeedback(.selection, trigger: selection)
    }
}
