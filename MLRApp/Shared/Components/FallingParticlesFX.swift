import SwiftUI
import UIKit

// MARK: - Falling leaves / snow that land on the logo
//
// Live particle scene for the Home logo (fall = leaves, winter = snow).
// The logo artwork is the landscape. A 2D mask built once from the artwork's
// alpha channel yields every UPWARD-FACING EDGE (an opaque cell with clear
// space above it): treetops, the cabin roof, the tops of each letter, the hill.
// Edges are grouped into segments that never bridge gaps. Leaves rest only on
// gentle, supported segments and slide off steep ones; snow is absorbed by an
// edge and grows a small cap on gentle segments. Anything that misses the art
// drifts down and fades before the greeting. Two canvases (behind and in front
// of the artwork) share one fixed-step simulation (1/60 s).

enum ParticleKind { case leaf, snow }
enum ParticleLayer { case back, front }

// MARK: Mask

/// The logo artwork's alpha channel at 416x278, built once and cached.
final class LogoMask {
    static let shared = LogoMask()
    let w = 416, h = 278
    private(set) var alpha: [UInt8]

    private init() {
        alpha = [UInt8](repeating: 0, count: 416 * 278)
        guard let cg = UIImage(named: "brand-logo-green")?.cgImage else { return }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let width = w, height = h
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return }
        for i in 0..<(w * h) { alpha[i] = buf[i * 4 + 3] }
    }
}

/// Shares one simulation between the behind-logo and in-front-of-logo canvases.
final class ParticleStore {
    private var sims: [ParticleKind: ParticleSim] = [:]
    /// Seconds of simulation to pre-run so the effect is already alive on frame one.
    private let warmStart: Double
    init(warmStart: Double = 0) { self.warmStart = warmStart }
    func sim(for kind: ParticleKind) -> ParticleSim {
        if let s = sims[kind] { return s }
        var ff = warmStart
        var seed = UInt64.random(in: 1...UInt64.max)
        #if DEBUG
        if let v = UserDefaults.standard.object(forKey: "leafTime") as? NSNumber ?? (UserDefaults.standard.string(forKey: "leafTime").flatMap { Double($0) as NSNumber? }) {
            ff = v.doubleValue; seed = 42
        }
        #endif
        let s = ParticleSim(kind: kind, fastForward: ff, seed: seed)
        sims[kind] = s
        return s
    }
}

private struct SplitMix: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class ParticleSim {
    enum Phase { case air, slide, rest }

    /// One upward-facing edge cell of the artwork (canvas points).
    struct Edge {
        var y: Double
        var slope: Double      // |dy/dx| of the smoothed segment around it
        var down: Double       // +1: downhill toward +x, -1: toward -x
        var tang: Double       // surface angle in degrees
        var supported: Bool    // segment long enough to hold a leaf
        var cap: Int           // snow cap index, -1 when too steep / short
    }
    /// A small snow cap: points along the surface and its full depth.
    struct Cap { var pts: [CGPoint]; var maxD: Double }

    struct P {
        var phase = Phase.air
        var back = false
        var x0 = 0.0, y = 0.0
        var vTerm = 30.0, amp = 10.0, omega = 2.8, phi = 0.0
        var flutterW = 2.0, flutterPhi = 0.0
        var size = 12.0
        var shape = 0, colorIdx = 0
        var alpha = 1.0
        var t = 0.0, life = 0.0
        var vx = 0.0, vyLift = 0.0
        var spin = 0.0
        var tumble = 0.0, tumbleDir = 1.0
        var flatBack = 0.0
        var noRest = false
        var slideV = 0.0
        var surfY = 0.0
        var landSX = 1.0, landSY = 1.0, restFrom = 0.0, restTo = 0.0
        var restFor = 14.0
        var px = 0.0, py = 0.0, rot = 0.0, sx = 1.0, sy = 1.0
    }

    let kind: ParticleKind
    private(set) var ps: [P] = []
    private var rng: SplitMix
    private var configured = false
    private var lastDate: Date?
    private var acc = 0.0
    private var simT = 0.0
    private var spawnIn = 1.5
    private var gustAt = 8.0, gustLen = 2.2, gustV = 0.0
    private var fastForward: Double
    static let dt = 1.0 / 60

    // geometry (canvas points)
    private var ox = 0.0, oy = 0.0, lw = 1.0, lh = 1.0
    private var endY = 0.0, spawnY = 0.0, unit = 1.0
    private var geoKey = ""
    private let cols = 208
    private var rows = 139
    private var edgesByCol: [[Edge]] = []
    private var gentleSpots: [(x: Double, e: Edge)] = []
    private(set) var caps: [Cap] = []
    private(set) var capLevel: [Double] = []
    private var artMinX = 0.0, artMaxX = 1.0

    private var gentleTan: Double { tan(35.0 * .pi / 180) }
    private static let capTan = tan(40.0 * .pi / 180)
    static let palette: [UInt32] = [0xB5482A, 0xD98A1F, 0xE3B23C, 0x9C2F2F, 0x8A6A2B]

    init(kind: ParticleKind, fastForward: Double = 0, seed: UInt64) {
        self.kind = kind
        self.fastForward = fastForward
        self.rng = SplitMix(s: seed)
    }

    private func r(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b, using: &rng) }
    private func chance(_ p: Double) -> Bool { Double.random(in: 0...1, using: &rng) < p }
    private var isLeaf: Bool { kind == .leaf }
    private var maxAir: Int { isLeaf ? 4 : 12 }
    private var maxRest: Int { 6 }

    // MARK: Geometry

    func configure(origin: CGPoint, size: CGSize, endY: Double, spawnLift: Double, unit: Double, reduceMotion: Bool) {
        let key = "\(origin.x),\(origin.y),\(size.width),\(size.height),\(endY),\(spawnLift),\(unit)"
        guard !configured || key != geoKey else { return }
        geoKey = key
        ox = Double(origin.x); oy = Double(origin.y); lw = Double(size.width); lh = Double(size.height)
        self.endY = endY; self.unit = unit; spawnY = oy - spawnLift * unit
        let hadCaps = caps.count
        buildSurface()
        if capLevel.count != caps.count { capLevel = [Double](repeating: 0.5, count: caps.count) }
        _ = hadCaps
        let first = !configured
        configured = true
        guard first else { return }
        if reduceMotion {
            if !isLeaf { capLevel = [Double](repeating: 0.65, count: caps.count); return }
            var xs: [Double] = []
            for _ in 0..<5 {
                if var p = restingAtGentle(avoiding: xs, spacing: 12) {
                    p.restFor = 1e9; p.t = 1; p.sy = 0.6
                    xs.append(p.px); ps.append(p)
                }
            }
            return
        }
        var xs: [Double] = []
        for _ in 0..<(isLeaf ? Int.random(in: 2...3, using: &rng) : 0) {
            if var p = restingAtGentle(avoiding: xs, spacing: 14) {
                p.t = r(0.5, 5); xs.append(p.px); ps.append(p)
            }
        }
        for _ in 0..<(isLeaf ? 2 : 5) {
            var p = airParticle()
            p.y = spawnY + (endY - 22 * unit - spawnY) * r(0.1, 0.7)
            ps.append(p)
        }
        spawnIn = r(1.0, 2.0)
        gustAt = r(5, 8)
        if fastForward > 0 {
            let n = Int(fastForward / Self.dt)
            for _ in 0..<n { step() }
            fastForward = 0
        }
    }

    /// Edges from the 2D mask: opaque cells with >= 3 pt of clear space above,
    /// grouped into segments (broken at gaps / height jumps > 1.5 pt).
    private func buildSurface() {
        let mask = LogoMask.shared
        rows = max(1, Int((Double(cols) * Double(mask.h) / Double(mask.w)).rounded()))
        func opaque(_ c: Int, _ rr: Int) -> Bool {
            guard c >= 0, c < cols, rr >= 0, rr < rows else { return false }
            let sx = min(mask.w - 1, Int((Double(c) + 0.5) / Double(cols) * Double(mask.w)))
            let sy = min(mask.h - 1, Int((Double(rr) + 0.5) / Double(rows) * Double(mask.h)))
            return mask.alpha[sy * mask.w + sx] > 110
        }
        let clear = 6          // 3 design pt
        // edge rows per column
        var colEdges = [[Int]](repeating: [], count: cols)
        var minC = cols, maxC = 0
        for c in 0..<cols {
            for rr in 0..<rows where opaque(c, rr) {
                minC = min(minC, c); maxC = max(maxC, c)
                guard rr == 0 || !opaque(c, rr - 1) else { continue }
                var ok = true
                for k in 1...clear where opaque(c, rr - k) { ok = false; break }
                if ok { colEdges[c].append(rr) }
            }
        }
        artMinX = ox + Double(minC) / Double(cols) * lw
        artMaxX = ox + Double(maxC + 1) / Double(cols) * lw
        // group into segments
        struct Seg { var cs: [Int] = []; var rs: [Int] = [] }
        var segs: [Seg] = []
        var open: [Int] = []                  // segment ids continuing from previous column
        for c in 0..<cols {
            var next: [Int] = []
            var used = Set<Int>()
            for rr in colEdges[c] {
                var best: Int?
                var bd = 99
                for id in open where !used.contains(id) {
                    let d = abs(segs[id].rs.last! - rr)
                    if d <= 3 && d < bd { best = id; bd = d }
                }
                if let b = best { used.insert(b); segs[b].cs.append(c); segs[b].rs.append(rr); next.append(b) }
                else { segs.append(Seg(cs: [c], rs: [rr])); next.append(segs.count - 1) }
            }
            open = next
        }
        // per-segment smoothing, slope, caps
        edgesByCol = [[Edge]](repeating: [], count: cols)
        gentleSpots = []
        caps = []
        let cw = lw / Double(cols), chh = lh / Double(rows)
        for sgm in segs {
            let n = sgm.cs.count
            guard n >= 2 else { continue }
            let rs = sgm.rs.map(Double.init)
            var sm = [Double](repeating: 0, count: n)
            for j in 0..<n {
                let a = max(0, j - 3), b = min(n - 1, j + 3)
                sm[j] = rs[a...b].reduce(0, +) / Double(b - a + 1)
            }
            let supported = n >= 6
            var tans = [Double](repeating: 0, count: n)
            var downs = [Double](repeating: 1, count: n)
            var tangs = [Double](repeating: 0, count: n)
            for j in 0..<n {
                let a = max(0, j - 3), b = min(n - 1, j + 3)
                let dc = Double(sgm.cs[b] - sgm.cs[a])
                let dr = sm[b] - sm[a]
                tans[j] = dc > 0 ? abs(dr / dc) : 99
                downs[j] = dr >= 0 ? 1 : -1
                tangs[j] = dc > 0 ? atan(dr / dc * chh / cw) * 180 / .pi : 0
            }
            // cap runs: consecutive gentle points
            var capIdx = [Int](repeating: -1, count: n)
            var j = 0
            while j < n {
                guard tans[j] * chh / cw <= Self.capTan else { j += 1; continue }
                var k = j
                while k + 1 < n && tans[k + 1] * chh / cw <= Self.capTan { k += 1 }
                if k - j + 1 >= 6 {
                    let mid = (j + k) / 2
                    let nx = Double(sgm.cs[mid]) / Double(cols), ny = sm[mid] / Double(rows)
                    var d: Double
                    if ny >= 0.60 { d = 2.5 }
                    else if nx >= 0.38 && nx <= 0.61 && ny >= 0.36 && ny <= 0.57 { d = 2.5 }
                    else if nx < 0.33 || nx > 0.68 || ny < 0.26 { d = 1.0 }
                    else { d = 1.2 }
                    var pts: [CGPoint] = []
                    for q in j...k { pts.append(CGPoint(x: ox + (Double(sgm.cs[q]) + 0.5) * cw, y: oy + sm[q] * chh)) }
                    caps.append(Cap(pts: pts, maxD: d))
                    for q in j...k { capIdx[q] = caps.count - 1 }
                }
                j = k + 1
            }
            for q in 0..<n {
                let e = Edge(y: oy + sm[q] * chh, slope: tans[q] * chh / cw, down: downs[q], tang: tangs[q],
                             supported: supported, cap: capIdx[q])
                edgesByCol[sgm.cs[q]].append(e)
                if supported && e.slope < gentleTan && q >= 2 && q < n - 2 {
                    gentleSpots.append((ox + (Double(sgm.cs[q]) + 0.5) * cw, e))
                }
            }
        }
        for c in 0..<cols { edgesByCol[c].sort { $0.y < $1.y } }
    }

    private func colOf(_ x: Double) -> Int? {
        let c = Int(((x - ox) / lw * Double(cols)).rounded(.down))
        return (c >= 0 && c < cols) ? c : nil
    }
    /// First upward edge crossed when moving from yPrev to yNow at x.
    private func edgeCross(_ x: Double, _ yPrev: Double, _ yNow: Double) -> Edge? {
        guard let c = colOf(x) else { return nil }
        for e in edgesByCol[c] where e.y > yPrev && e.y <= yNow { return e }
        return nil
    }
    /// The edge at x closest to height y (within a small tolerance), for sliding.
    private func edgeNear(_ x: Double, _ y: Double, tol: Double) -> Edge? {
        guard let c = colOf(x) else { return nil }
        var best: Edge?
        var bd = tol
        for e in edgesByCol[c] where abs(e.y - y) <= bd { best = e; bd = abs(e.y - y) }
        return best
    }

    // MARK: Spawn

    private func airParticle() -> P {
        var p = P()
        if isLeaf {
            p.back = chance(0.35)
            p.size = r(9.5, 14.5)
            p.shape = [0, 0, 0, 1, 1, 2, 2][Int.random(in: 0..<7, using: &rng)]
            p.colorIdx = Int.random(in: 0..<Self.palette.count, using: &rng)
            p.vTerm = r(22, 38)
            p.amp = r(6, 14)
            p.omega = 2 * .pi / r(1.9, 3.0)
            p.alpha = p.back ? 0.8 : 1
        } else {
            p.back = chance(0.3)
            p.size = p.back ? r(0.5, 0.7) : [0.9, 1.15, 1.45][Int.random(in: 0...2, using: &rng)] * r(0.9, 1.1)
            p.alpha = p.back ? 0.5 : r(0.8, 1.0)
            p.vTerm = r(18, 34)
            p.amp = r(4, 9)
            p.omega = 2 * .pi / r(2.2, 3.4)
        }
        p.phi = r(0, 2 * .pi)
        p.flutterW = 2 * .pi / r(2.4, 4.0)
        p.flutterPhi = r(0, 2 * .pi)
        let pad = 0.06 * lw
        p.x0 = r(artMinX - pad, artMaxX + pad)
        p.y = spawnY
        return p
    }

    private func restingAtGentle(avoiding xs: [Double], spacing: Double) -> P? {
        var spots = gentleSpots.shuffled(using: &rng)
        spots.removeAll { s in xs.contains { abs($0 - s.x) < spacing * unit } }
        guard let s = spots.first else { return nil }
        var p = airParticle()
        p.back = false
        p.alpha = 1
        p.px = s.x
        p.surfY = s.e.y
        p.py = s.e.y
        p.phase = .rest
        p.sx = 1; p.sy = 0.6
        p.restTo = s.e.tang + (chance(0.5) ? 90 : -90) + r(-12, 12)
        p.rot = p.restTo; p.restFrom = p.restTo
        p.restFor = r(10, 18)
        p.t = 1
        return p
    }

    // MARK: Step

    func advance(to date: Date) {
        guard configured else { return }
        guard let last = lastDate else { lastDate = date; return }
        guard date > last else { return }
        lastDate = date
        acc += min(date.timeIntervalSince(last), 0.25)
        while acc >= Self.dt { acc -= Self.dt; step() }
    }

    private func gust() {
        gustV = (chance(0.5) ? 1 : -1) * r(10, 18) * unit
        guard isLeaf else { return }
        let resting = ps.indices.filter { ps[$0].phase == .rest && !ps[$0].back }
        var take = resting.filter { ps[$0].t >= ps[$0].restFor }
        if take.isEmpty, !resting.isEmpty {
            take = Array(resting.shuffled(using: &rng).prefix(Int.random(in: 1...2, using: &rng)))
        }
        for i in take.prefix(3) {
            var p = ps[i]
            p.phase = .air
            p.x0 = p.px; p.y = p.py; p.life = 0; p.phi = 0
            p.vx = gustV * 0.5 + r(-4, 4) * unit
            p.vyLift = -r(20, 34) * unit
            p.tumble = 0.8; p.tumbleDir = chance(0.5) ? 1 : -1
            p.noRest = true
            p.flatBack = 1
            p.spin = p.rot - 35
            ps[i] = p
        }
    }

    private func toAir(_ p: inout P) {
        p.phase = .air
        p.x0 = p.px; p.y = p.py; p.life = 0; p.phi = 0
        p.vx = p.slideV
        p.vyLift = 0
        p.flatBack = 1
        p.spin = p.rot - 35
    }

    private func step() {
        let dt = Self.dt
        simT += dt
        var wind = 0.0
        if simT >= gustAt {
            let u = (simT - gustAt) / gustLen
            if u <= 1 {
                if gustV == 0 { gust() }
                wind = gustV * sin(.pi * u)
            } else {
                gustV = 0
                gustAt = simT + r(9, 14)
                gustLen = r(1.8, 2.4)
            }
        }
        let tiltMax = 35.0
        var removeIdx: [Int] = []
        for i in ps.indices {
            var p = ps[i]
            switch p.phase {
            case .air:
                let yOld = p.y
                p.life += dt
                let a = p.omega * p.life + p.phi
                p.x0 += (wind + p.vx) * dt
                p.vx *= exp(-1.4 * dt)
                let lat = p.amp * unit * sin(a)
                let vlat = p.amp * unit * p.omega * cos(a)
                p.px = p.x0 + lat
                let speed = p.vTerm * unit * (0.75 + 0.25 * abs(cos(a)))
                p.y += (speed + p.vyLift) * dt
                p.vyLift *= exp(-2.6 * dt)
                p.spin *= exp(-2.2 * dt)
                p.flatBack = max(0, p.flatBack - dt / 0.3)
                var tilt = isLeaf ? tiltMax * cos(a) : 0
                if p.tumble > 0 {
                    p.tumble -= dt
                    p.spin += p.tumbleDir * 520 * dt
                    p.sx = cos((p.flutterW * 3.5 * p.life + p.flutterPhi))
                    if abs(p.sx) < 0.25 { p.sx = p.sx < 0 ? -0.25 : 0.25 }
                    tilt *= 0.3
                } else if isLeaf {
                    p.sx = 0.675 + 0.325 * sin(p.flutterW * p.life + p.flutterPhi)
                } else { p.sx = 1 }
                p.rot = tilt + p.spin
                p.sy = 1 - 0.4 * p.flatBack
                p.py = p.y
                if p.y >= endY { removeIdx.append(i); ps[i] = p; continue }
                if !p.back, !p.noRest, p.y > yOld, let e = edgeCross(p.px, yOld, p.y) {
                    if isLeaf {
                        p.landSX = p.sx; p.landSY = p.sy
                        p.py = e.y; p.surfY = e.y
                        p.phase = .slide; p.t = 0
                        p.slideV = max(-12 * unit, min(12 * unit, (vlat + wind) * 0.25))
                    } else {
                        // a flake is absorbed by the edge; gentle segments gain depth
                        if e.cap >= 0 { capLevel[e.cap] = min(1, capLevel[e.cap] + 0.12) }
                        removeIdx.append(i); ps[i] = p; continue
                    }
                }
            case .slide:
                p.t += dt
                let x = p.px
                guard let e = edgeNear(x, p.surfY, tol: 2.2 * unit) else { toAir(&p); ps[i] = p; continue }
                let gentle = e.slope < gentleTan && e.supported
                var crowdDir = 0.0
                var crowd = 0
                for (j, q) in ps.enumerated() where j != i && q.phase == .rest && !q.back
                    && abs(q.px - x) < 10 * unit && abs(q.surfY - p.surfY) < 8 * unit {
                    crowd += 1; crowdDir = x >= q.px ? 1 : -1
                }
                let crowded = crowd >= 2
                if gentle && !crowded && p.t > 0.2 && abs(p.slideV) < 14 * unit {
                    p.phase = .rest; p.t = 0
                    p.slideV = 0
                    p.restFrom = p.rot
                    let base = e.tang + (chance(0.5) ? 90 : -90) + r(-12, 12)
                    p.restTo = p.rot + shortest(p.rot, base)
                    p.restFor = r(10, 18)
                    p.landSY = p.sy; p.landSX = p.sx
                    p.py = e.y; p.surfY = e.y
                    ps[i] = p; continue
                }
                if gentle {
                    if crowded { p.slideV = crowdDir * max(abs(p.slideV), 10 * unit) }
                    else { p.slideV *= (1 - 2.5 * dt) }
                } else {
                    p.slideV += e.down * 70 * unit * dt
                    p.slideV = max(-45 * unit, min(45 * unit, p.slideV))
                }
                let nx = x + p.slideV * dt
                guard let ne = edgeNear(nx, e.y, tol: 2.2 * unit) else { p.px = nx; toAir(&p); ps[i] = p; continue }
                p.px = nx; p.py = ne.y; p.surfY = ne.y
                let roll = p.slideV * 1.4
                p.rot += (ne.tang + 90 * (shortest(0, p.rot - ne.tang) >= 0 ? 1 : -1) - p.rot) * min(1, 3 * dt)
                p.rot += roll * dt
                let k = min(p.t / 0.3, 1)
                p.sx = p.landSX + (1 - p.landSX) * k
                p.sy = p.landSY + (0.6 - p.landSY) * k
            case .rest:
                p.t += dt
                let u = min(p.t / 0.5, 1)
                p.py = p.surfY + 0.9 * unit * sin(.pi * u)
                let k = 1 - pow(1 - min(p.t / 0.35, 1), 2)
                p.sx = p.landSX + (1 - p.landSX) * k
                p.sy = p.landSY + (0.6 - p.landSY) * k
                p.rot = p.restFrom + shortest(p.restFrom, p.restTo) * k
            }
            ps[i] = p
        }
        if !removeIdx.isEmpty {
            let s = Set(removeIdx)
            ps = ps.enumerated().filter { !s.contains($0.offset) }.map { $0.element }
        }
        if !isLeaf {
            for i in capLevel.indices { capLevel[i] = max(0, capLevel[i] - 0.002 * dt) }
        }
        spawnIn -= dt
        if spawnIn <= 0 {
            let air = ps.filter { $0.phase == .air }.count
            let resting = ps.count - air
            if air < maxAir && resting < maxRest { ps.append(airParticle()) }
            spawnIn = isLeaf ? r(1.6, 3.2) : r(0.35, 0.8)
        }
    }

    private func shortest(_ from: Double, _ to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }

    func opacity(of p: P) -> Double {
        switch p.phase {
        case .air:
            let fin = min(1, max(0, (p.y - spawnY) / (5 * unit) + 0.1))
            let fout = min(1, max(0, (endY - p.y) / (14 * unit)))
            return p.alpha * fin * fout
        default: return p.alpha
        }
    }
}

// MARK: - View

struct FallingParticlesFX: View {
    let kind: ParticleKind
    var layer: ParticleLayer = .front
    let store: ParticleStore
    /// Dark mode: the cream plaque around the logo (12 pt sides, 10 pt top/bottom).
    /// Nothing draws outside it and particles fade out before its bottom inner edge.
    var plaque = false

    private static let extend: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            ParticleScene(kind: kind, layer: layer, store: store, logoSize: geo.size,
                          plaque: plaque, extend: Self.extend)
                .frame(width: geo.size.width + 2 * Self.extend, height: geo.size.height + 2 * Self.extend)
                .offset(x: -Self.extend, y: -Self.extend)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ParticleScene: View {
    let kind: ParticleKind
    let layer: ParticleLayer
    let store: ParticleStore
    let logoSize: CGSize
    let plaque: Bool
    let extend: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = true

    var body: some View {
        let sim = store.sim(for: kind)
        let active = scenePhase == .active && onScreen && !reduceMotion
        TimelineView(.animation(paused: !active)) { tl in
            Canvas { ctx, size in
                let w = Double(logoSize.width)
                let unit = max(0.5, w / 104)
                let ext = Double(extend)
                // light: gone before the greeting (just under the logo frame);
                // dark: gone before the plaque's bottom inner edge.
                let endY = ext + Double(logoSize.height) + (plaque ? 8 : 1) * unit
                sim.configure(origin: CGPoint(x: extend, y: extend), size: logoSize, endY: endY,
                              spawnLift: plaque ? 7 : 6, unit: unit, reduceMotion: reduceMotion)
                if !reduceMotion { sim.advance(to: tl.date) }
                var c = ctx
                if plaque {
                    let rect = CGRect(x: ext - 12 + 1.5, y: ext - 10 + 1.5, width: w + 24 - 3,
                                      height: Double(logoSize.height) + 20 - 3)
                    c.clip(to: Path(roundedRect: rect, cornerRadius: 16))
                }
                for p in sim.ps where (layer == .back) == p.back { draw(p, sim, &c, unit) }
                if kind == .snow && layer == .front { drawCap(sim, &c, unit) }
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
    }

    private func draw(_ p: ParticleSim.P, _ sim: ParticleSim, _ ctx: inout GraphicsContext, _ unit: Double) {
        var g = ctx
        g.opacity = sim.opacity(of: p)
        if kind == .leaf {
            if p.phase != .air && !p.back {
                g.addFilter(.shadow(color: .black.opacity(0.12), radius: 1.5, x: 0, y: 0.8))
            }
            g.translateBy(x: p.px, y: p.py)
            g.scaleBy(x: 1, y: p.sy)
            g.rotate(by: .degrees(p.rot))
            let s = p.size * unit / 100 * (p.back ? 0.7 : 1)
            g.scaleBy(x: p.sx * s, y: s)
            let base = ParticleSim.palette[p.colorIdx]
            var c1 = Self.mix(base, 0xFFFFFF, 0.14), c2 = Self.mix(base, 0x000000, 0.14)
            var rib = Self.mix(base, 0x000000, 0.42)
            if p.back {
                c1 = Self.mix(c1, 0x7A705C, 0.3); c2 = Self.mix(c2, 0x7A705C, 0.3); rib = Self.mix(rib, 0x7A705C, 0.3)
            }
            let shape = Self.shapes[p.shape]
            g.fill(shape.body, with: .linearGradient(Gradient(colors: [c1, c2]),
                                                      startPoint: CGPoint(x: -20, y: -48), endPoint: CGPoint(x: 20, y: 30)))
            g.stroke(shape.body, with: .color(rib.opacity(0.35)), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            g.stroke(shape.rib, with: .color(rib), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            g.stroke(shape.stem, with: .color(rib), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
        } else {
            let r = 1.7 * p.size * unit
            let rect = CGRect(x: p.px - r, y: p.py - r, width: 2 * r, height: 2 * r)
            g.addFilter(.shadow(color: Self.cool.opacity(0.35), radius: 0.8, x: 0, y: 0.3))
            g.fill(Path(ellipseIn: rect), with: .color(.white))
            g.stroke(Path(ellipseIn: rect), with: .color(Self.cool.opacity(0.35)), lineWidth: 0.6)
        }
    }

    private static let cool = Color(red: 0x9F / 255, green: 0xB4 / 255, blue: 0xC4 / 255)

    /// Small snow caps sitting on the gentle upward edges: domed, tapering to
    /// nothing at both ends, with a faint cool underside line.
    private func drawCap(_ sim: ParticleSim, _ ctx: inout GraphicsContext, _ unit: Double) {
        for (i, cap) in sim.caps.enumerated() {
            let d = cap.maxD * sim.capLevel[i] * unit
            guard d > 0.15, cap.pts.count >= 2 else { continue }
            let n = cap.pts.count
            var top = Path(), under = Path(), shape = Path()
            for (j, pt) in cap.pts.enumerated() {
                let t = Double(j) / Double(n - 1)
                let h = d * pow(sin(.pi * t), 0.6)
                let tp = CGPoint(x: pt.x, y: pt.y - h)
                if j == 0 { top.move(to: tp); under.move(to: CGPoint(x: pt.x, y: pt.y + 0.3)) }
                else { top.addLine(to: tp); under.addLine(to: CGPoint(x: pt.x, y: pt.y + 0.3)) }
            }
            shape.addPath(top)
            for pt in cap.pts.reversed() { shape.addLine(to: CGPoint(x: pt.x, y: pt.y + 0.3)) }
            shape.closeSubpath()
            var g = ctx
            g.addFilter(.shadow(color: .black.opacity(0.12), radius: 0.8, x: 0, y: 0.5))
            g.fill(shape, with: .color(.white))
            ctx.stroke(under, with: .color(Color(red: 0x8F / 255, green: 0xA6 / 255, blue: 0xB8 / 255).opacity(0.45)),
                       style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
        }
    }

    // MARK: Leaf silhouettes (100-unit box, tip up, stem down)

    private struct LeafShape { let body: Path; let rib: Path; let stem: Path }

    private static func mirrored(_ half: [CGPoint]) -> [CGPoint] {
        half + half.dropFirst().dropLast().reversed().map { CGPoint(x: -$0.x, y: $0.y) }
    }
    private static func polygon(_ pts: [CGPoint]) -> Path {
        var p = Path(); p.addLines(pts); p.closeSubpath(); return p
    }
    private static func line(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path(); p.move(to: a); p.addLine(to: b); return p
    }

    private static let shapes: [LeafShape] = [maple, oak, birch]

    private static let maple: LeafShape = {
        let half: [CGPoint] = [(0, -48), (8, -26), (14, -36), (40, -36), (22, -14), (46, 6), (24, 8), (14, 22), (3, 24), (0, 24)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        var rib = Path()
        rib.move(to: CGPoint(x: 0, y: 24)); rib.addLine(to: CGPoint(x: 0, y: -38))
        rib.move(to: CGPoint(x: 0, y: 8)); rib.addLine(to: CGPoint(x: 30, y: -2))
        rib.move(to: CGPoint(x: 0, y: 8)); rib.addLine(to: CGPoint(x: -30, y: -2))
        rib.move(to: CGPoint(x: 0, y: -8)); rib.addLine(to: CGPoint(x: 28, y: -28))
        rib.move(to: CGPoint(x: 0, y: -8)); rib.addLine(to: CGPoint(x: -28, y: -28))
        return LeafShape(body: polygon(mirrored(half)), rib: rib,
                         stem: line(CGPoint(x: 0, y: 24), CGPoint(x: 1, y: 44)))
    }()

    private static let oak: LeafShape = {
        var half: [CGPoint] = []
        let steps = 48
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let y = -46 + 74 * u
            let env = 38 * sqrt(max(0, 1 - pow((y + 8) / 38, 2)))
            let w = env * (0.62 + 0.38 * abs(sin(.pi * u * 4.0 + 0.35)))
            half.append(CGPoint(x: w, y: y))
        }
        var pts = half
        pts += half.dropFirst().dropLast().reversed().map { CGPoint(x: -$0.x, y: $0.y) }
        var rib = Path()
        rib.move(to: CGPoint(x: 0, y: 28)); rib.addLine(to: CGPoint(x: 0, y: -38))
        return LeafShape(body: polygon(pts), rib: rib, stem: line(CGPoint(x: 0, y: 28), CGPoint(x: 1, y: 46)))
    }()

    private static let birch: LeafShape = {
        var half: [CGPoint] = []
        let steps = 18
        for i in 0...steps {
            let u = Double(i) / Double(steps)
            let y = -50 + 78 * u
            var w = 27 * pow(sin(.pi * pow(u, 0.72)), 0.9)
            if i > 0 && i < steps { w *= (i % 2 == 0 ? 1.0 : 0.86) }
            half.append(CGPoint(x: w, y: y))
        }
        var pts = half
        pts += half.dropFirst().dropLast().reversed().map { CGPoint(x: -$0.x, y: $0.y) }
        var rib = Path()
        rib.move(to: CGPoint(x: 0, y: 28)); rib.addLine(to: CGPoint(x: 0, y: -42))
        return LeafShape(body: polygon(pts), rib: rib, stem: line(CGPoint(x: 0, y: 28), CGPoint(x: 0, y: 46)))
    }()

    private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
        func ch(_ s: UInt32) -> Double { Double(s & 0xff) / 255 }
        let r = ch(a >> 16) * (1 - t) + ch(b >> 16) * t
        let g = ch(a >> 8) * (1 - t) + ch(b >> 8) * t
        let bl = ch(a) * (1 - t) + ch(b) * t
        return Color(red: r, green: g, blue: bl)
    }
    private static func mix(_ c: Color, _ b: UInt32, _ t: Double) -> Color {
        let u = UIColor(c); var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
        u.getRed(&r, green: &g, blue: &bl, alpha: &a)
        func ch(_ s: UInt32) -> Double { Double(s & 0xff) / 255 }
        return Color(red: r * (1 - t) + ch(b >> 16) * t, green: g * (1 - t) + ch(b >> 8) * t, blue: bl * (1 - t) + ch(b) * t)
    }
}
