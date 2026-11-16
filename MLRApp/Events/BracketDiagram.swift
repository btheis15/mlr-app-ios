import SwiftUI

// MARK: - BracketDiagram
//
// The big bracket: round columns left to right with titled headers (Quarterfinals,
// Semifinals, Final), elbow connectors, byes shown as byes, winners emphasised and
// losers dimmed, the viewer's own path highlighted, and a gold champion node.
// Pinch to zoom (with +/- buttons for one-handed or VoiceOver use), pan, double-tap
// a game to zoom onto it, and it opens scrolled to the current round.
//
// Positions come from `BracketLayout` (each game sits at the midpoint of its
// feeders), so connectors are drawn in a Canvas from the same numbers. UI only:
// bracket math stays in `BracketMath` / the server.

// MARK: Geometry

struct BracketMetrics {
    let compact: Bool
    var cellWidth: CGFloat { compact ? 132 : 200 }
    var cellHeight: CGFloat { compact ? 52 : 78 }
    var columnGap: CGFloat { compact ? 28 : 48 }
    var baseGap: CGFloat { compact ? 8 : 16 }
    /// Room above the first row for the round titles.
    var header: CGFloat { compact ? 0 : 34 }
}

struct BracketLayout {
    let metrics: BracketMetrics
    let shown: [TournamentMatch]
    let rounds: [Int]
    let centers: [UUID: CGPoint]
    let size: CGSize

    static func make(_ t: Tournament, stage: MatchStage?, compact: Bool) -> BracketLayout {
        let m = BracketMetrics(compact: compact)
        let shown = t.matches.filter { stage == nil || $0.stage == stage }
            .sorted { $0.round == $1.round ? $0.position < $1.position : $0.round < $1.round }
        let rounds = Array(Set(shown.map(\.round))).sorted()
        var centers: [UUID: CGPoint] = [:]
        for (idx, r) in rounds.enumerated() {
            let list = shown.filter { $0.round == r }
            let stride = (m.cellHeight + m.baseGap) * pow(2, CGFloat(idx))
            var lastY = -CGFloat.infinity
            for (i, match) in list.enumerated() {
                var y = m.header + stride * (CGFloat(i) + 0.5)
                if idx > 0 {
                    let feedYs = shown.filter { $0.nextMatchId == match.id }.compactMap { centers[$0.id]?.y }
                    if !feedYs.isEmpty { y = feedYs.reduce(0, +) / CGFloat(feedYs.count) }
                }
                let minY = lastY + m.cellHeight + m.baseGap
                if y < minY { y = minY }
                lastY = y
                centers[match.id] = CGPoint(x: CGFloat(idx) * (m.cellWidth + m.columnGap) + m.cellWidth / 2, y: y)
            }
        }
        let columns = CGFloat(rounds.count) + (compact ? 0 : 1)   // + champion column
        let width = max(columns, 1) * m.cellWidth + max(0, columns - 1) * m.columnGap
        let height = (centers.values.map(\.y).max() ?? 0) + m.cellHeight / 2 + m.baseGap
        return BracketLayout(metrics: m, shown: shown, rounds: rounds, centers: centers,
                             size: CGSize(width: width, height: max(height, m.cellHeight)))
    }

    func columnLeft(_ roundIndex: Int) -> CGFloat { CGFloat(roundIndex) * (metrics.cellWidth + metrics.columnGap) }

    /// The round the viewer should land on: their own playable game, else any playable
    /// game, else the last round when finished, else the first round.
    func focusMatch(_ t: Tournament, viewer: UUID?) -> TournamentMatch? {
        let ready = shown.filter(t.isReady)
        if let mine = ready.first(where: { t.involves($0, entrant: viewer) }) { return mine }
        if let any = ready.first { return any }
        if t.isFinished { return shown.last { $0.nextMatchId == nil } }
        return shown.first { $0.status != .complete }
    }
}

// MARK: The scrollable, zoomable diagram

struct BracketDiagram: View {
    let tournament: Tournament
    var stageFilter: MatchStage? = nil
    let canManage: Bool
    var rearranging: Bool = false
    var pickedUp: (matchId: UUID, slot: Int)? = nil
    var viewerEntrantId: UUID? = nil
    var onOpen: (TournamentMatch) -> Void = { _ in }
    var onSlotTap: (TournamentMatch, Int) -> Void = { _, _ in }
    /// Compact preview mode: smaller cells, no champion node, no zoom.
    var compact: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var position = ScrollPosition()
    @State private var viewport: CGSize = .zero
    @State private var didInitialScroll = false
    @State private var focusedId: UUID?

    private let minScale: CGFloat = 0.5
    private let maxScale: CGFloat = 2.5
    private let inset: CGFloat = 16

    var body: some View {
        let layout = BracketLayout.make(tournament, stage: stageFilter, compact: compact)
        if layout.rounds.isEmpty {
            ContentUnavailableView("No games yet", systemImage: "trophy",
                                   description: Text("The bracket appears once the tournament starts."))
        } else if compact {
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                tree(layout).padding(4)
            }
        } else {
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                tree(layout)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
                    .padding(inset)
            }
            .scrollPosition($position)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                viewport = size
                scrollToCurrent(layout)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { setScale(baseScale * $0.magnification) }
                    .onEnded { _ in baseScale = scale }
            )
            .overlay(alignment: .bottomTrailing) { zoomControls(layout) }
            .overlay(alignment: .bottom) { caption }
            .animation(reduceMotion ? nil : MLRMotion.spring, value: focusedId)
        }
    }

    private func tree(_ layout: BracketLayout) -> some View {
        BracketTree(
            tournament: tournament, layout: layout, compact: compact,
            canManage: canManage, rearranging: rearranging, pickedUp: pickedUp,
            viewerEntrantId: viewerEntrantId, isStatic: false,
            onOpen: onOpen, onSlotTap: onSlotTap,
            onInfo: { m in focusedId = focusedId == m.id ? nil : m.id },
            onZoom: { m in zoom(to: m, layout) })
    }

    // MARK: Zoom + scroll

    private func setScale(_ s: CGFloat) { scale = min(max(s, minScale), maxScale) }

    private func animated(_ body: () -> Void) {
        if reduceMotion { body() } else { withAnimation(MLRMotion.spring, body) }
    }

    private func zoom(to match: TournamentMatch, _ layout: BracketLayout) {
        guard let c = layout.centers[match.id] else { return }
        let target: CGFloat = scale < 1.4 ? 1.6 : 1.0
        Haptics.select()
        animated {
            scale = target; baseScale = target
            position.scrollTo(x: max(0, c.x * target + inset - viewport.width / 2),
                              y: max(0, c.y * target + inset - viewport.height / 2))
        }
    }

    private func step(_ factor: CGFloat) {
        Haptics.select()
        animated { setScale(scale * factor); baseScale = scale }
    }

    /// Open on the current round (once the viewport size is known).
    private func scrollToCurrent(_ layout: BracketLayout) {
        guard !didInitialScroll, viewport.width > 0, viewport.height > 0 else { return }
        didInitialScroll = true
        guard let m = layout.focusMatch(tournament, viewer: viewerEntrantId),
              let c = layout.centers[m.id] else { return }
        let x = max(0, (c.x - layout.metrics.cellWidth / 2) * scale + inset - 12)
        let y = max(0, c.y * scale + inset - viewport.height / 2)
        position.scrollTo(x: x, y: y)
    }

    // MARK: Chrome

    private func zoomControls(_ layout: BracketLayout) -> some View {
        HStack(spacing: 0) {
            Button { step(1 / 1.3) } label: { Image(systemName: "minus").frame(width: 44, height: 44) }
                .accessibilityLabel("Zoom out")
                .disabled(scale <= minScale + 0.01)
            Divider().frame(height: 22)
            Button { step(1.3) } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                .accessibilityLabel("Zoom in")
                .disabled(scale >= maxScale - 0.01)
        }
        .font(.mlrScaled(16, weight: .bold))
        .foregroundStyle(Color.mlrText)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mlrBorder, lineWidth: 1))
        .padding(10)
        .opacity(focusedId == nil ? 1 : 0)
    }

    /// Tap a game you can't score to read the full names.
    @ViewBuilder
    private var caption: some View {
        if let id = focusedId, let m = tournament.matches.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(tournament.gameLabel(m)).font(.mlrScaled(12, weight: .bold)).foregroundStyle(Color.mlrTextMuted)
                    Spacer()
                    Button { focusedId = nil } label: {
                        Image(systemName: "xmark.circle.fill").font(.mlrScaled(20)).foregroundStyle(Color.mlrTextSubtle)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close")
                }
                .padding(.bottom, -14)
                ForEach([1, 2], id: \.self) { slot in
                    let eid = slot == 1 ? m.slot1EntrantId : m.slot2EntrantId
                    let score = slot == 1 ? m.slot1Score : m.slot2Score
                    HStack {
                        Text(eid != nil ? tournament.entrantName(eid) : (tournament.slotPlaceholder(m, slot: slot) ?? "To be decided"))
                            .font(.mlrScaled(16, weight: eid != nil && eid == m.winnerEntrantId ? .bold : .medium))
                            .foregroundStyle(Color.mlrText)
                        Spacer()
                        if let score { Text("\(score)").font(.mlrScaled(16, weight: .bold)).monospacedDigit() }
                    }
                }
            }
            .padding(14)
            .background(Color.mlrCard, in: RoundedRectangle(cornerRadius: MLRRadius.card))
            .overlay(RoundedRectangle(cornerRadius: MLRRadius.card).strokeBorder(Color.mlrBorder, lineWidth: 1))
            .shadow(.medium)
            .padding(10)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tournament.a11yDescription(m))
        }
    }
}

// MARK: - BracketTree (the drawn bracket, no scrolling: also used to render the share image)

struct BracketTree: View {
    let tournament: Tournament
    let layout: BracketLayout
    var compact: Bool = false
    var canManage: Bool = false
    var rearranging: Bool = false
    var pickedUp: (matchId: UUID, slot: Int)? = nil
    var viewerEntrantId: UUID? = nil
    /// Static render (share image): no pulsing, no gestures.
    var isStatic: Bool = false
    var onOpen: (TournamentMatch) -> Void = { _ in }
    var onSlotTap: (TournamentMatch, Int) -> Void = { _, _ in }
    var onInfo: (TournamentMatch) -> Void = { _ in }
    var onZoom: (TournamentMatch) -> Void = { _ in }

    private var m: BracketMetrics { layout.metrics }

    var body: some View {
        ZStack(alignment: .topLeading) {
            connectorCanvas
            if !compact { roundHeaders }
            ForEach(layout.shown) { match in
                if let c = layout.centers[match.id] {
                    BracketCell(
                        tournament: tournament, match: match, compact: compact,
                        canManage: canManage, rearranging: rearranging, pickedUp: pickedUp,
                        viewerEntrantId: viewerEntrantId, isStatic: isStatic,
                        onOpen: { onOpen(match) }, onSlotTap: { onSlotTap(match, $0) },
                        onInfo: { onInfo(match) }, onZoom: { onZoom(match) })
                    .frame(width: m.cellWidth, height: m.cellHeight)
                    .position(c)
                }
            }
            if !compact { championNode }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    // MARK: Round titles

    private var roundHeaders: some View {
        ForEach(Array(layout.rounds.enumerated()), id: \.element) { idx, r in
            Text(tournament.roundTitle(round: r))
                .font(.mlrScaled(13, weight: .bold))
                .foregroundStyle(Color.mlrTextMuted)
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)
                .frame(width: m.cellWidth, height: 24)
                .position(x: layout.columnLeft(idx) + m.cellWidth / 2, y: 14)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Connectors

    private var connectorCanvas: some View {
        Canvas { ctx, _ in
            for match in layout.shown {
                guard let nextId = match.nextMatchId,
                      let parent = layout.shown.first(where: { $0.id == nextId }),
                      let from = layout.centers[match.id],
                      let to = layout.centers[parent.id]
                else { continue }
                // Elbow: out of the feeder's right edge, across to midway, vertical to
                // the parent's row, then into the parent's left edge.
                let startX = from.x + m.cellWidth / 2
                let endX = to.x - m.cellWidth / 2
                let midX = startX + (endX - startX) / 2
                var path = Path()
                path.move(to: CGPoint(x: startX, y: from.y))
                path.addLine(to: CGPoint(x: midX, y: from.y))
                path.addLine(to: CGPoint(x: midX, y: to.y))
                path.addLine(to: CGPoint(x: endX, y: to.y))
                let advanced = match.winnerEntrantId != nil
                let mine = advanced && match.winnerEntrantId == viewerEntrantId
                let color: Color = mine ? .mlrPrimary : (advanced ? Color.mlrText.opacity(0.55) : Color.mlrBorder)
                ctx.stroke(path, with: .color(color), lineWidth: mine ? 3.5 : (advanced ? 2 : 1.5))
            }
            // Final to champion stub.
            if !compact, let final = finalMatch, let from = layout.centers[final.id] {
                var path = Path()
                let startX = from.x + m.cellWidth / 2
                path.move(to: CGPoint(x: startX, y: from.y))
                path.addLine(to: CGPoint(x: startX + m.columnGap, y: from.y))
                ctx.stroke(path, with: .color(final.winnerEntrantId != nil ? Color.mlrFestGold : Color.mlrBorder), lineWidth: 2.5)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .allowsHitTesting(false)
    }

    private var finalMatch: TournamentMatch? {
        layout.shown.first { $0.nextMatchId == nil && $0.round == layout.rounds.last }
    }

    // MARK: Champion node

    @ViewBuilder
    private var championNode: some View {
        if let final = finalMatch, let c = layout.centers[final.id] {
            let champ = tournament.winnerEntrantId
            VStack(spacing: 4) {
                Image(systemName: "trophy.fill").font(.mlrScaled(24, weight: .bold))
                Text(champ != nil ? tournament.entrantName(champ) : "Champion")
                    .font(.mlrScaled(15, weight: .bold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .frame(width: m.cellWidth)
            .gradientCard(
                LinearGradient(colors: [.mlrFestGold, .mlrSun], startPoint: .topLeading, endPoint: .bottomTrailing),
                cornerRadius: MLRRadius.card, elevation: champ != nil ? .high : .low)
            .opacity(champ != nil ? 1 : 0.55)
            .position(x: c.x + m.cellWidth + m.columnGap, y: c.y)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(champ != nil ? "Champion: \(tournament.entrantName(champ))" : "Champion, to be decided")
        }
    }
}

// MARK: - BracketCell

/// One game in the diagram: two entrant rows with winner/loser emphasis, byes, and the viewer's path.
private struct BracketCell: View {
    let tournament: Tournament
    let match: TournamentMatch
    let compact: Bool
    let canManage: Bool
    let rearranging: Bool
    let pickedUp: (matchId: UUID, slot: Int)?
    let viewerEntrantId: UUID?
    let isStatic: Bool
    let onOpen: () -> Void
    let onSlotTap: (Int) -> Void
    let onInfo: () -> Void
    let onZoom: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var bothSet: Bool { match.slot1EntrantId != nil && match.slot2EntrantId != nil }
    private var bye: Bool { tournament.isBye(match) }
    private var tappable: Bool { !compact && !rearranging && canManage && (bothSet || match.status == .complete) && !bye }
    private var isLive: Bool { match.status == .ready || match.status == .in_progress }
    private var mine: Bool { tournament.involves(match, entrant: viewerEntrantId) }
    private var ready: Bool { tournament.isReady(match) }

    private var borderColor: Color {
        if rearranging { return Color.mlrPrimary.opacity(0.5) }
        if mine { return .mlrPrimary }
        if ready { return .mlrSuccess }
        return Color.mlrText.opacity(0.28)
    }
    private var borderWidth: CGFloat { (mine || ready) && !compact ? 2.5 : (compact ? 1 : 1.5) }

    var body: some View {
        let shell = VStack(spacing: 0) {
            row(entrantId: match.slot1EntrantId, score: match.slot1Score, slot: 1)
            Divider()
            row(entrantId: match.slot2EntrantId, score: match.slot2Score, slot: 2)
        }
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 12))
        .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 12).strokeBorder(borderColor, lineWidth: borderWidth))
        .overlay(alignment: .topTrailing) {
            if isLive && !compact && !isStatic {
                PulsingLiveDot(color: .mlrSuccess).scaleEffect(0.7).padding(6)
            }
        }
        .shadow(compact ? .none : .low)
        .opacity(bye ? 0.75 : 1)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : MLRMotion.spring, value: match)

        if isStatic || compact {
            shell
        } else if rearranging {
            shell.accessibilityElement(children: .contain)
        } else {
            // Double-tap zooms onto the game; a single tap scores it (managers) or
            // shows the full names (everyone else).
            shell
                .onTapGesture(count: 2) { onZoom() }
                .onTapGesture {
                    if tappable { Haptics.tap(); onOpen() } else { Haptics.select(); onInfo() }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tournament.a11yDescription(match))
                .accessibilityAddTraits(tappable ? .isButton : [])
                .accessibilityHint(tappable ? "Double tap to enter the result" : "Double tap to show the full names")
                .accessibilityAction { if tappable { onOpen() } else { onInfo() } }
        }
    }

    @ViewBuilder
    private func row(entrantId: UUID?, score: Int?, slot: Int) -> some View {
        let decided = match.winnerEntrantId != nil
        let isWinner = decided && entrantId == match.winnerEntrantId
        let isLoser = decided && entrantId != nil && !isWinner && !bye
        let isMe = entrantId != nil && entrantId == viewerEntrantId
        let isPicked = rearranging && pickedUp?.matchId == match.id && pickedUp?.slot == slot
        let seed = tournament.entrants.first { $0.id == entrantId }?.seed
        let placeholder = tournament.slotPlaceholder(match, slot: slot)
        let label = entrantId != nil ? tournament.entrantName(entrantId) : (bye ? "Bye" : (placeholder ?? "TBD"))

        HStack(spacing: 4) {
            // Gold accent bar on the winning row.
            Rectangle().fill(isWinner ? Color.mlrFestGold : Color.clear).frame(width: 4)
            if let seed, !compact {
                Text("\(seed)").font(.mlrScaled(10, weight: .bold)).foregroundStyle(Color.mlrTextMuted).frame(width: 16)
            }
            Text(label)
                .id(entrantId)   // a new entrant sliding in animates as an advance
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                .font(.mlrScaled(compact ? 11 : 14, weight: isWinner || isMe ? .bold : .medium))
                .italic(entrantId == nil)
                .foregroundStyle(entrantId == nil ? Color.mlrTextSubtle : (isLoser ? Color.mlrTextMuted : Color.mlrText))
                .strikethrough(false)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            if isMe && !compact {
                Image(systemName: "person.fill").font(.mlrScaled(9)).foregroundStyle(Color.mlrPrimary)
            }
            if isWinner && !compact {
                Image(systemName: "crown.fill").font(.mlrScaled(10)).foregroundStyle(Color.mlrFestGold)
            }
            if let score {
                Text("\(score)")
                    .font(.mlrScaled(compact ? 11 : 15, weight: .bold))
                    .foregroundStyle(isLoser ? Color.mlrTextMuted : Color.mlrText)
                    .monospacedDigit()
                    .numericTransition()
            }
        }
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
        .opacity(isLoser ? 0.62 : 1)
        .background(isPicked ? Color.mlrPrimary.opacity(0.2) : (isWinner ? Color.mlrPrimary.opacity(0.10) : (isMe ? Color.mlrPrimary.opacity(0.05) : Color.clear)))
        .animation(reduceMotion ? nil : MLRMotion.spring, value: entrantId)
        .contentShape(Rectangle())
        .modifier(SlotTap(enabled: rearranging && canManage) { Haptics.select(); onSlotTap(slot) })
    }
}

/// Attaches a tap only in rearrange mode, so the cell-level single/double taps stay
/// unobstructed the rest of the time.
private struct SlotTap: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        if enabled { content.onTapGesture(perform: action) } else { content }
    }
}
