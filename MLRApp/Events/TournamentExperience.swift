import SwiftUI

// MARK: - Tournament experience
//
// The "what do I do now?" layer of the tournament screen: the Now card (games ready
// to play, "You're up", up next, latest results), the champion card with a one-time
// celebration, the share-as-image card, the setup bracket preview, and the designed
// loading state. Presentation only: every fact comes from `Tournament` helpers.

// MARK: Celebration ledger

@MainActor
private enum CelebrationLedger {
    /// Tournaments already celebrated this launch, so reopening doesn't re-fire it.
    static var seen = Set<UUID>()
}

// MARK: Canvas confetti

/// A one-shot confetti-style burst drawn in a Canvas. Bump `trigger` to fire.
/// Renders nothing at rest and nothing at all under Reduce Motion.
struct CanvasConfetti: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Piece {
        let x: CGFloat          // 0...1 emitter position across the top
        let vx: CGFloat
        let vy: CGFloat
        let spin: Double
        let size: CGSize
        let color: Color
    }

    @State private var start: Date?
    @State private var pieces: [Piece] = []
    private let duration: TimeInterval = 2.6

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { tl in
            Canvas { ctx, size in
                guard let start else { return }
                let t = tl.date.timeIntervalSince(start)
                guard t >= 0, t < duration else { return }
                let fade = t > duration - 0.8 ? max(0, (duration - t) / 0.8) : 1
                for p in pieces {
                    let x = p.x * size.width + p.vx * t
                    let y = -12 + p.vy * t + 0.5 * 520 * t * t
                    var c = ctx
                    c.opacity = fade
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(p.spin * t))
                    c.fill(Path(CGRect(x: -p.size.width / 2, y: -p.size.height / 2, width: p.size.width, height: p.size.height)),
                           with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in fire() }
    }

    private func fire() {
        guard !reduceMotion, trigger > 0 else { return }
        let palette: [Color] = [.mlrFestGold, .mlrSun, .mlrPrimary, .mlrLake, .mlrCampfire, .mlrDusk]
        pieces = (0..<70).map { _ in
            Piece(x: .random(in: 0.1...0.9), vx: .random(in: -90...90), vy: .random(in: 60...260),
                  spin: .random(in: -9...9),
                  size: CGSize(width: .random(in: 6...10), height: .random(in: 9...15)),
                  color: palette.randomElement() ?? .mlrFestGold)
        }
        start = Date()
        Task {
            try? await Task.sleep(nanoseconds: UInt64((duration + 0.2) * 1_000_000_000))
            start = nil
        }
    }
}

// MARK: Now card

struct TournamentNowCard: View {
    let tournament: Tournament
    let viewerEntrantId: UUID?
    /// Only managers score (and never while previewing as someone else).
    let canScore: Bool
    let onOpen: (TournamentMatch) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if tournament.isFinished, let champ = tournament.winnerEntrantId {
                TournamentChampionCard(tournament: tournament, championId: champ, viewerEntrantId: viewerEntrantId)
            } else if tournament.status == .live {
                liveBody
            }
        }
        .animation(reduceMotion ? nil : MLRMotion.spring, value: tournament.readyMatches.map(\.id))
    }

    private var ready: [TournamentMatch] {
        // The viewer's own game is pinned first.
        let all = tournament.readyMatches
        return all.filter { tournament.involves($0, entrant: viewerEntrantId) }
            + all.filter { !tournament.involves($0, entrant: viewerEntrantId) }
    }

    @ViewBuilder
    private var liveBody: some View {
        let ready = self.ready
        let upNext = tournament.upNextMatches
        let recent = tournament.recentResults()
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                PulsingLiveDot(color: .mlrSuccess)
                Text("Now").font(.mlrScaled(22, weight: .bold, design: .rounded)).foregroundStyle(Color.mlrText)
                Spacer()
                if !ready.isEmpty {
                    Text("\(ready.count) ready").font(.mlrScaled(13, weight: .semibold)).foregroundStyle(Color.mlrTextMuted)
                        .numericTransition()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            if ready.isEmpty {
                waitingCard
            } else {
                ForEach(ready) { m in
                    NowGameCard(tournament: tournament, match: m,
                                mine: tournament.involves(m, entrant: viewerEntrantId),
                                canScore: canScore, onOpen: { onOpen(m) })
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                }
                if !canScore {
                    Text("The organizers enter the results.")
                        .font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
                }
            }

            if !upNext.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Up next")
                    ForEach(upNext.prefix(3)) { m in upNextRow(m) }
                }
            }
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Latest results")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(recent) { m in resultChip(m) } }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.mlrScaled(13, weight: .bold)).foregroundStyle(Color.mlrTextMuted)
            .textCase(.uppercase).tracking(0.6)
            .accessibilityAddTraits(.isHeader)
    }

    private var waitingCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass").font(.mlrScaled(22)).foregroundStyle(Color.mlrTextMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting on results").font(.mlrScaled(16, weight: .semibold)).foregroundStyle(Color.mlrText)
                Text("The next game opens as soon as the current ones finish.")
                    .font(.mlrScaled(13)).foregroundStyle(Color.mlrTextMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .cardStyle(cornerRadius: MLRRadius.card, elevation: .low)
        .accessibilityElement(children: .combine)
    }

    private func upNextRow(_ m: TournamentMatch) -> some View {
        func side(_ id: UUID?, _ slot: Int) -> String {
            id != nil ? tournament.entrantName(id) : (tournament.slotPlaceholder(m, slot: slot) ?? "TBD")
        }
        return HStack(spacing: 10) {
            Text(tournament.shortGameLabel(m))
                .font(.mlrScaled(11, weight: .bold)).foregroundStyle(Color.mlrTextMuted)
                .frame(minWidth: 40, alignment: .leading)
            Text("\(side(m.slot1EntrantId, 1))  vs  \(side(m.slot2EntrantId, 2))")
                .font(.mlrScaled(14, weight: .medium)).foregroundStyle(Color.mlrText)
                .lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(minHeight: 44)
        .cardStyle(cornerRadius: MLRRadius.button, elevation: .none)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Up next. \(tournament.a11yDescription(m))")
    }

    private func resultChip(_ m: TournamentMatch) -> some View {
        let w = m.winnerEntrantId
        let wScore = w == m.slot1EntrantId ? m.slot1Score : m.slot2Score
        let lScore = w == m.slot1EntrantId ? m.slot2Score : m.slot1Score
        let loser = w == m.slot1EntrantId ? m.slot2EntrantId : m.slot1EntrantId
        return HStack(spacing: 6) {
            Text(tournament.entrantName(w)).font(.mlrScaled(13, weight: .bold)).lineLimit(1).truncationMode(.middle)
            if let wScore, let lScore {
                Text("\(wScore)\u{2013}\(lScore)").font(.mlrScaled(13, weight: .bold)).monospacedDigit().foregroundStyle(Color.mlrFestGold)
            } else {
                Text("def.").font(.mlrScaled(12)).foregroundStyle(Color.mlrTextMuted)
            }
            Text(tournament.entrantName(loser)).font(.mlrScaled(13)).foregroundStyle(Color.mlrTextMuted).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: 280)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.mlrCard, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mlrBorder, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tournament.a11yDescription(m))
    }
}

/// A ready game as one large tappable matchup.
private struct NowGameCard: View {
    let tournament: Tournament
    let match: TournamentMatch
    let mine: Bool
    let canScore: Bool
    let onOpen: () -> Void

    var body: some View {
        let content = VStack(spacing: 10) {
            HStack {
                Text(tournament.gameLabel(match))
                    .font(.mlrScaled(12, weight: .bold)).foregroundStyle(Color.mlrTextMuted)
                    .textCase(.uppercase).tracking(0.5)
                Spacer()
                if mine {
                    Label("You're up", systemImage: "bolt.fill")
                        .font(.mlrScaled(13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.mlrPrimary, in: Capsule())
                }
            }
            name(match.slot1EntrantId)
            Text("vs").font(.mlrScaled(13, weight: .black, design: .rounded)).foregroundStyle(Color.mlrTextSubtle)
            name(match.slot2EntrantId)
            if canScore {
                Label("Tap to enter the result", systemImage: "hand.tap.fill")
                    .font(.mlrScaled(13, weight: .semibold)).foregroundStyle(Color.mlrPrimary)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132)
        .background(mine ? Color.mlrPrimaryLight : Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: MLRRadius.card))
        .overlay(RoundedRectangle(cornerRadius: MLRRadius.card).strokeBorder(mine ? Color.mlrPrimary : Color.mlrText.opacity(0.25), lineWidth: mine ? 3 : 1.5))
        .shadow(.medium)

        if canScore {
            Button { Haptics.tap(); onOpen() } label: { content }
                .buttonStyle(.pressable)
                .accessibilityLabel((mine ? "You're up. " : "") + tournament.a11yDescription(match))
                .accessibilityHint("Double tap to enter the result")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel((mine ? "You're up. " : "") + tournament.a11yDescription(match))
        }
    }

    private func name(_ id: UUID?) -> some View {
        Text(tournament.entrantName(id))
            .font(.mlrScaled(24, weight: .bold, design: .rounded))
            .foregroundStyle(Color.mlrText)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity)
    }
}

// MARK: Champion card

struct TournamentChampionCard: View {
    let tournament: Tournament
    let championId: UUID
    let viewerEntrantId: UUID?
    /// False when rendered into the share image (no celebration side effects).
    var celebrate: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confetti = 0
    @State private var bounce = 0

    private var path: [TournamentMatch] { tournament.path(of: championId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trophy.fill")
                    .font(.mlrScaled(40, weight: .bold))
                    .symbolEffect(.bounce, value: bounce)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CHAMPION").font(.mlrScaled(12, weight: .bold)).tracking(1.4).opacity(0.9)
                    Text(tournament.entrantName(championId))
                        .font(.mlrScaled(28, weight: .bold, design: .rounded))
                        .lineLimit(2).minimumScaleFactor(0.65).truncationMode(.middle)
                    if championId == viewerEntrantId {
                        Text("That's you!").font(.mlrScaled(14, weight: .semibold)).opacity(0.95)
                    }
                }
                Spacer(minLength: 0)
            }
            if !path.isEmpty {
                Divider().overlay(.white.opacity(0.4))
                Text("The road to the title").font(.mlrScaled(12, weight: .bold)).tracking(0.6).textCase(.uppercase).opacity(0.9)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(path) { m in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(tournament.roundTitle(m)).font(.mlrScaled(12, weight: .semibold)).opacity(0.85)
                                .frame(width: 96, alignment: .leading).lineLimit(1)
                            Text(line(m)).font(.mlrScaled(14, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gradientCard(
            LinearGradient(colors: [.mlrFestGold, .mlrSun, .mlrFestGold], startPoint: .topLeading, endPoint: .bottomTrailing),
            cornerRadius: MLRRadius.lg, elevation: .high)
        .overlay(alignment: .top) { CanvasConfetti(trigger: confetti).frame(height: 360) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Champion: \(tournament.entrantName(championId)). "
            + path.map { tournament.a11yDescription($0) }.joined(separator: ". "))
        .onAppear { celebrateOnce() }
    }

    private func line(_ m: TournamentMatch) -> String {
        let opp = tournament.opponentName(in: m, of: championId)
        let mine = m.slot1EntrantId == championId ? m.slot1Score : m.slot2Score
        let theirs = m.slot1EntrantId == championId ? m.slot2Score : m.slot1Score
        if let mine, let theirs { return "beat \(opp), \(mine) to \(theirs)" }
        return "beat \(opp)"
    }

    private func celebrateOnce() {
        guard celebrate, CelebrationLedger.seen.insert(tournament.id).inserted else { return }
        guard !reduceMotion else { return }
        confetti += 1; bounce += 1
        Haptics.success()
    }
}

// MARK: Next game offer

/// Shown after saving a result when that made a new game ready.
struct NextGameBanner: View {
    let title: String
    let canScore: Bool
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Next game").font(.mlrScaled(12, weight: .bold)).foregroundStyle(Color.mlrTextMuted).textCase(.uppercase)
                Text(title).font(.mlrScaled(16, weight: .bold)).foregroundStyle(Color.mlrText)
                    .lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if canScore {
                Button { onOpen() } label: {
                    Text("Score it").font(.mlrScaled(15, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(Color.mlrPrimary, in: Capsule())
                }.buttonStyle(.pressable)
            }
            Button { onDismiss() } label: {
                Image(systemName: "xmark").font(.mlrScaled(14, weight: .bold)).foregroundStyle(Color.mlrTextMuted)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MLRRadius.card))
        .overlay(RoundedRectangle(cornerRadius: MLRRadius.card).strokeBorder(Color.mlrPrimary.opacity(0.6), lineWidth: 2))
        .shadow(.high)
        .padding(.horizontal, 12).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
}

// MARK: Loading

/// Designed loading state: placeholder cards in the shape of the real screen.
struct TournamentLoadingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            bar(width: 90, height: 24)
            block(height: 132)
            bar(width: 110, height: 16)
            block(height: 52)
            block(height: 52)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(dim ? 0.5 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading the tournament")
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(Color.mlrBorder).frame(width: width, height: height)
    }
    private func block(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: MLRRadius.card).fill(Color.mlrBorder.opacity(0.6)).frame(height: height)
    }
}

// MARK: Share

/// Renders the current bracket (or the champion card) to an image for the family chat.
struct TournamentShareButton: View {
    let tournament: Tournament
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ShareLink(item: Image(uiImage: image),
                          subject: Text(tournament.title),
                          message: Text(tournament.isFinished ? "\(tournament.title): final results" : "\(tournament.title): where it stands"),
                          preview: SharePreview(tournament.title, image: Image(uiImage: image))) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share the bracket as a picture")
            } else {
                Image(systemName: "square.and.arrow.up").foregroundStyle(Color.mlrTextSubtle)
                    .accessibilityHidden(true)
            }
        }
        .task(id: tournament.matches) { render() }
    }

    @MainActor
    private func render() {
        let card = TournamentShareCard(tournament: tournament)
        let width = card.estimatedWidth
        let renderer = ImageRenderer(content: card
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large))
        renderer.scale = width > 1000 ? 1.5 : 2.5
        image = renderer.uiImage
    }
}

/// The picture itself: branded header, then the champion (finished) or the bracket / standings.
struct TournamentShareCard: View {
    let tournament: Tournament

    private var stage: MatchStage? { tournament.format == .pools_bracket ? .bracket : nil }
    private var showsBracket: Bool { tournament.format != .round_robin && tournament.hasKnockoutBracket }

    var estimatedWidth: CGFloat {
        if tournament.isFinished || !showsBracket { return 420 }
        return BracketLayout.make(tournament, stage: stage, compact: false).size.width + 48
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "trophy.fill").foregroundStyle(Color.mlrFestGold)
                Text(tournament.title).font(.mlrScaled(22, weight: .bold, design: .rounded)).foregroundStyle(Color.mlrText)
                    .lineLimit(2)
            }
            if tournament.isFinished, let champ = tournament.winnerEntrantId {
                TournamentChampionCard(tournament: tournament, championId: champ, viewerEntrantId: nil, celebrate: false)
            } else if showsBracket {
                BracketTree(tournament: tournament,
                            layout: BracketLayout.make(tournament, stage: stage, compact: false),
                            isStatic: true)
            } else {
                standings
            }
        }
        .padding(24)
        .frame(width: tournament.isFinished || !showsBracket ? 420 : nil, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background(Color.mlrSurface)
    }

    private var standings: some View {
        let rows = tournament.standings().prefix(10)
        return VStack(spacing: 8) {
            ForEach(Array(rows)) { r in
                HStack {
                    Text("\(r.rank)").font(.mlrScaled(15, weight: .bold)).frame(width: 28, alignment: .leading)
                    Text(r.name).font(.mlrScaled(16, weight: r.rank == 1 ? .bold : .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(r.record).font(.mlrScaled(15, weight: .semibold)).monospacedDigit()
                }
                .foregroundStyle(Color.mlrText)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.mlrCard, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

// MARK: Setup preview

/// Shows how the draw will fall for the entrants as seeded, before anything is generated.
struct TournamentSetupPreview: View {
    let names: [String]
    let format: TournamentFormat
    let strategy: ByeStrategy
    let poolCount: Int
    let advance: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch format {
            case .single_elim: bracketBody
            case .round_robin:
                let n = names.count
                line("\(n) players, \(n * max(n - 1, 0) / 2) games. Everyone plays everyone, then a standings table ranks them.")
            case .pools_bracket:
                let per = names.isEmpty ? 0 : Int((Double(names.count) / Double(max(poolCount, 1))).rounded(.up))
                line("\(poolCount) pools of about \(per). The top \(advance) from each advance to a knockout bracket.")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func line(_ s: String) -> some View {
        Text(s).font(.mlrScaled(13)).foregroundStyle(Color.mlrTextMuted)
    }

    @ViewBuilder
    private var bracketBody: some View {
        let n = names.count
        if n < 2 {
            line("Add at least 2 players to see the bracket.")
        } else {
            let size = BracketMath.bracketSize(n)
            let rounds = max(1, Int((log2(Double(size))).rounded()))
            let order = BracketMath.seedOrder(size)
            let byes = BracketMath.byeCount(n)
            line(BracketMath.bracketSummary(n, strategy))
            Text((1...rounds).map { r in
                switch rounds - r {
                case 0: return "Final"
                case 1: return "Semifinals"
                case 2: return "Quarterfinals"
                default: return "Round \(r)"
                }
            }.joined(separator: "  \u{203A}  "))
                .font(.mlrScaled(12, weight: .semibold)).foregroundStyle(Color.mlrPrimary)
            if strategy == .byes {
                if byes > 0 {
                    let rested = (1...byes).map(String.init).joined(separator: ", ")
                    Label("Seed\(byes == 1 ? "" : "s") \(rested) skip\(byes == 1 ? "s" : "") round 1 (bye).", systemImage: "forward.end.fill")
                        .font(.mlrScaled(13, weight: .semibold)).foregroundStyle(Color.mlrWarning)
                }
                ForEach(0..<(size / 2), id: \.self) { i in
                    let s1 = order[2 * i], s2 = order[2 * i + 1]
                    gameRow(s1: s1, s2: s2, n: n)
                }
            } else {
                line("With play-ins, the extra players play off first so the main draw is a clean \(BracketMath.lowerPow2(n)).")
            }
        }
    }

    private func gameRow(s1: Int, s2: Int, n: Int) -> some View {
        func side(_ s: Int) -> some View {
            HStack(spacing: 6) {
                Text("\(s)").font(.mlrScaled(11, weight: .bold)).foregroundStyle(Color.mlrTextMuted).frame(width: 20)
                Text(s <= n ? names[s - 1] : "Bye")
                    .font(.mlrScaled(14, weight: s <= n ? .medium : .regular)).italic(s > n)
                    .foregroundStyle(s <= n ? Color.mlrText : Color.mlrTextSubtle)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        let isBye = s1 > n || s2 > n
        return VStack(spacing: 2) {
            side(s1)
            side(s2)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(isBye ? Color.mlrWarning.opacity(0.10) : Color.mlrPrimaryLight.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isBye
            ? "\(s1 <= n ? names[s1 - 1] : names[s2 - 1]) has a bye"
            : "\(names[s1 - 1]) versus \(names[s2 - 1])")
    }
}
