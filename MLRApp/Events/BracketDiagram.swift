import SwiftUI

// MARK: - BracketDiagram (UI/UX overhaul Phase 2.4)
//
// The BIG bracket: a 2-D scrollable, connected tournament tree — round columns
// left→right, elbow connectors between feeders and their parent, and a gold
// champion node at the far right. Positions are computed deterministically from
// `round`/`position` (the tree is regular: `bracketSize` is a power of two), so
// connectors are drawn in a `Canvas` from the same math — no preference plumbing.
// Winner-path segments stroke in `mlrPrimary`; the rest in `mlrBorder`.
//
// UI only — bracket math stays in `BracketMath` / the server.

struct BracketDiagram: View {
    let tournament: Tournament
    var stageFilter: MatchStage? = nil
    let canManage: Bool
    var rearranging: Bool = false
    var pickedUp: (matchId: UUID, slot: Int)? = nil
    var onOpen: (TournamentMatch) -> Void = { _ in }
    var onSlotTap: (TournamentMatch, Int) -> Void = { _, _ in }
    /// Compact preview mode (setup sheet): smaller cells, no champion node.
    var compact: Bool = false

    // Cell geometry.
    private var cellWidth: CGFloat { compact ? 132 : 172 }
    private var cellHeight: CGFloat { compact ? 52 : 72 }
    private var columnGap: CGFloat { compact ? 28 : 44 }
    private var baseGap: CGFloat { compact ? 8 : 14 }

    private var shown: [TournamentMatch] {
        tournament.matches
            .filter { stageFilter == nil || $0.stage == stageFilter }
            .sorted { $0.round == $1.round ? $0.position < $1.position : $0.round < $1.round }
    }
    private var rounds: [Int] { Array(Set(shown.map(\.round))).sorted() }
    private func matches(in round: Int) -> [TournamentMatch] {
        shown.filter { $0.round == round }.sorted { $0.position < $1.position }
    }

    /// Row stride for a round column: doubles each round so every match sits at
    /// the midpoint of its two feeders.
    private func stride(forRoundIndex idx: Int) -> CGFloat {
        (cellHeight + baseGap) * pow(2, CGFloat(idx))
    }
    /// Center-y of match `i` in round column `idx`.
    private func centerY(roundIndex idx: Int, matchIndex i: Int) -> CGFloat {
        stride(forRoundIndex: idx) * (CGFloat(i) + 0.5)
    }
    private var totalHeight: CGFloat {
        let first = rounds.first.map { matches(in: $0).count } ?? 1
        return max(CGFloat(first), 1) * stride(forRoundIndex: 0)
    }
    private var totalWidth: CGFloat {
        let columns = CGFloat(rounds.count) + (compact ? 0 : 1)   // + champion column
        return columns * cellWidth + max(0, columns - 1) * columnGap
    }

    private func centerPoint(of match: TournamentMatch) -> CGPoint? {
        guard let idx = rounds.firstIndex(of: match.round),
              let i = matches(in: match.round).firstIndex(where: { $0.id == match.id })
        else { return nil }
        let x = CGFloat(idx) * (cellWidth + columnGap) + cellWidth / 2
        return CGPoint(x: x, y: centerY(roundIndex: idx, matchIndex: i))
    }

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: !compact) {
            ZStack(alignment: .topLeading) {
                connectorCanvas
                ForEach(shown) { match in
                    if let c = centerPoint(of: match) {
                        BracketCell(
                            tournament: tournament, match: match, compact: compact,
                            canManage: canManage, rearranging: rearranging, pickedUp: pickedUp,
                            onOpen: { onOpen(match) }, onSlotTap: { onSlotTap(match, $0) })
                        .frame(width: cellWidth, height: cellHeight)
                        .position(c)
                    }
                }
                if !compact { championNode }
            }
            .frame(width: totalWidth, height: totalHeight)
            .padding(compact ? 4 : 16)
        }
    }

    // MARK: Connectors

    private var connectorCanvas: some View {
        Canvas { ctx, _ in
            for match in shown {
                guard let nextId = match.nextMatchId,
                      let parent = shown.first(where: { $0.id == nextId }),
                      let from = centerPoint(of: match),
                      let to = centerPoint(of: parent)
                else { continue }
                // Elbow: out from the feeder's right edge, across to midway,
                // vertical to the parent's row, then into the parent's left edge.
                let startX = from.x + cellWidth / 2
                let endX = to.x - cellWidth / 2
                let midX = startX + (endX - startX) / 2
                var path = Path()
                path.move(to: CGPoint(x: startX, y: from.y))
                path.addLine(to: CGPoint(x: midX, y: from.y))
                path.addLine(to: CGPoint(x: midX, y: to.y))
                path.addLine(to: CGPoint(x: endX, y: to.y))
                // The winner's onward path glows in brand green.
                let isWinnerPath = match.winnerEntrantId != nil
                ctx.stroke(path,
                           with: .color(isWinnerPath ? Color.mlrPrimary : Color.mlrBorder),
                           lineWidth: isWinnerPath ? 2 : 1.5)
            }
            // Final → champion node stub.
            if let final = shown.first(where: { $0.nextMatchId == nil && rounds.last == $0.round }),
               let from = centerPoint(of: final) {
                var path = Path()
                let startX = from.x + cellWidth / 2
                path.move(to: CGPoint(x: startX, y: from.y))
                path.addLine(to: CGPoint(x: startX + columnGap, y: from.y))
                ctx.stroke(path,
                           with: .color(final.winnerEntrantId != nil ? Color.mlrFestGold : Color.mlrBorder),
                           lineWidth: 2)
            }
        }
        .frame(width: totalWidth, height: totalHeight)
        .allowsHitTesting(false)
    }

    // MARK: Champion node

    @ViewBuilder
    private var championNode: some View {
        if let lastRound = rounds.last, let idx = rounds.firstIndex(of: lastRound) {
            let champ = tournament.winnerEntrantId
            let x = CGFloat(idx + 1) * (cellWidth + columnGap) + cellWidth / 2
            let y = centerY(roundIndex: idx, matchIndex: 0)
            VStack(spacing: 4) {
                Image(systemName: "trophy.fill")
                    .font(.mlrScaled(22, weight: .bold))
                Text(champ != nil ? tournament.entrantName(champ) : "Champion")
                    .font(.mlrScaled(14, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .frame(width: cellWidth)
            .gradientCard(
                LinearGradient(colors: [.mlrFestGold, .mlrSun],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                cornerRadius: MLRRadius.card,
                elevation: champ != nil ? .high : .low)
            .opacity(champ != nil ? 1 : 0.55)
            .position(x: x, y: y)
            .accessibilityLabel(champ != nil ? "Champion: \(tournament.entrantName(champ))" : "Champion — to be decided")
        }
    }
}

// MARK: - BracketCell

/// One match in the diagram: two entrant rows + status footer accents.
private struct BracketCell: View {
    let tournament: Tournament
    let match: TournamentMatch
    let compact: Bool
    let canManage: Bool
    let rearranging: Bool
    let pickedUp: (matchId: UUID, slot: Int)?
    let onOpen: () -> Void
    let onSlotTap: (Int) -> Void

    private var bothSet: Bool { match.slot1EntrantId != nil && match.slot2EntrantId != nil }
    private var bye: Bool { (match.slot1EntrantId != nil) != (match.slot2EntrantId != nil) && match.status == .complete }
    private var tappable: Bool { !compact && !rearranging && canManage && (bothSet || match.status == .complete) && !bye }
    private var isLive: Bool { match.status == .ready || match.status == .in_progress }

    var body: some View {
        VStack(spacing: 0) {
            row(entrantId: match.slot1EntrantId, score: match.slot1Score, slot: 1)
            Divider()
            row(entrantId: match.slot2EntrantId, score: match.slot2Score, slot: 2)
        }
        .background(Color.mlrCard)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 12))
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 8 : 12)
                .strokeBorder(rearranging ? Color.mlrPrimary.opacity(0.45) : Color.mlrBorder, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if isLive && !compact {
                PulsingLiveDot(color: .mlrSuccess)
                    .scaleEffect(0.7)
                    .padding(6)
                    .accessibilityLabel("Match live")
            }
        }
        .shadow(compact ? .none : .low)
        .opacity(bye ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if tappable { Haptics.tap(); onOpen() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    @ViewBuilder
    private func row(entrantId: UUID?, score: Int?, slot: Int) -> some View {
        let isWinner = match.winnerEntrantId != nil && entrantId == match.winnerEntrantId
        let isPicked = rearranging && pickedUp?.matchId == match.id && pickedUp?.slot == slot
        let seed = tournament.entrants.first { $0.id == entrantId }?.seed
        let label = entrantId != nil
            ? tournament.entrantName(entrantId)
            : (match.status == .complete ? "Bye" : "TBD")

        HStack(spacing: 4) {
            // Gold accent bar on the winning row.
            Rectangle()
                .fill(isWinner ? Color.mlrFestGold : Color.clear)
                .frame(width: 3)
            if let seed, !compact {
                Text("\(seed)")
                    .font(.mlrScaled(9, weight: .bold))
                    .foregroundStyle(Color.mlrTextSubtle)
                    .frame(width: 14)
            }
            Text(label)
                .font(.mlrScaled(compact ? 11 : 12, weight: isWinner ? .bold : .regular))
                .foregroundStyle(entrantId != nil ? Color.mlrText : Color.mlrTextSubtle)
                .lineLimit(1)
            Spacer(minLength: 2)
            if isWinner && !compact {
                Image(systemName: "crown.fill")
                    .font(.mlrScaled(8))
                    .foregroundStyle(Color.mlrFestGold)
            }
            if let score {
                Text("\(score)")
                    .font(.mlrScaled(compact ? 11 : 12, weight: .bold))
                    .monospacedDigit()
                    .numericTransition()
            }
        }
        .padding(.trailing, 6)
        .frame(maxHeight: .infinity)
        .background(isPicked ? Color.mlrPrimary.opacity(0.2) : (isWinner ? Color.mlrPrimary.opacity(0.06) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if rearranging && canManage { onSlotTap(slot) }
            else if tappable { Haptics.tap(); onOpen() }
        }
    }

    private var a11yLabel: String {
        let n1 = match.slot1EntrantId != nil ? tournament.entrantName(match.slot1EntrantId) : "TBD"
        let n2 = match.slot2EntrantId != nil ? tournament.entrantName(match.slot2EntrantId) : "TBD"
        if let w = match.winnerEntrantId {
            return "\(n1) versus \(n2). Winner: \(tournament.entrantName(w))"
        }
        return "\(n1) versus \(n2)\(isLive ? ", live" : "")"
    }
}
