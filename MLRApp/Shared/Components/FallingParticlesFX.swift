import SwiftUI
import UIKit

// MARK: - Falling leaves / snow that land on the logo
//
// Live particle scene for the Home logo (fall = leaves, winter = snow).
// The logo artwork is the landscape: a height map built once from the
// artwork's alpha channel tells leaves where treetops, the cabin roof, the hill
// and the lettering are. Leaves rest only on gentle spots, slide off steep ones,
// and anything that misses the art drifts down and fades before the greeting.
// Two canvases (behind and in front of the artwork) share one fixed-step
// simulation (1/60 s) driven from the timeline date.

enum ParticleKind { case leaf, snow }
enum ParticleLayer { case back, front }

// MARK: Height map

/// Top silhouette of the logo artwork: for each of 96 columns, the normalised Y
/// (0 = top, 1 = bottom) of the topmost opaque pixel, NaN where the column is
/// empty. Built once from the asset's alpha channel and cached. Because it is
/// stored in normalised units, a size change never needs a rebuild.
enum LogoHeightMap {
    static let columns = 96
    static let top: [Double] = build()

    private static func build() -> [Double] {
        var out = [Double](repeating: .nan, count: columns)
        guard let cg = UIImage(named: "brand-logo-green")?.cgImage else { return out }
        let w = 384, h = 256
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return out }
        let per = w / columns
        for i in 0..<columns {
            rows: for r in 0..<h {
                for k in 0..<per where buf[(r * w + i * per + k) * 4 + 3] > 140 {
                    out[i] = Double(r) / Double(h)
                    break rows
                }
            }
        }
        return out
    }
}

/// Shares one simulation between the behind-logo and in-front-of-logo canvases.
final class ParticleStore {
    private var sims: [ParticleKind: ParticleSim] = [:]
    func sim(for kind: ParticleKind) -> ParticleSim {
        if let s = sims[kind] { return s }
        var ff = 0.0
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

    struct P {
        var phase = Phase.air
        var back = false
        var x0 = 0.0, y = 0.0              // air: base x (wind-integrated) and y
        var vTerm = 30.0, amp = 10.0, omega = 2.8, phi = 0.0
        var flutterW = 2.0, flutterPhi = 0.0
        var size = 14.0                    // points across (1x)
        var shape = 0, colorIdx = 0
        var alpha = 1.0
        var t = 0.0, life = 0.0
        var vx = 0.0, vyLift = 0.0         // decaying extra velocities (air)
        var spin = 0.0                     // extra rotation offset, decays in air
        var tumble = 0.0, tumbleDir = 1.0
        var flatBack = 0.0                 // 1 -> 0: easing from flattened back to full height
        var noRest = false
        var slideV = 0.0
        var landSX = 1.0, landSY = 1.0, restFrom = 0.0, restTo = 0.0
        var restFor = 14.0, meltLen = 2.5
        // current pose (written by step)
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
    private var hs: [Double] = []          // smoothed surface Y per column (NaN = none)
    private var slopeAbs: [Double] = []
    private var downDir: [Double] = []
    private var tangDeg: [Double] = []
    private var gentleCols: [Int] = []
    private var artMinX = 0.0, artMaxX = 1.0
    // snow accumulation (points of depth per column) and its cap
    private(set) var snowDepth: [Double] = []
    private var snowCap: [Double] = []
    private var snowTick = 0
    /// Columns carrying a visible snow cap: x, surface Y, depth.
    var capColumns: [(x: Double, base: Double, depth: Double)] {
        guard !snowDepth.isEmpty else { return [] }
        return (0..<LogoHeightMap.columns).map { i in (colX(i), hs[i], hs[i].isNaN ? 0 : snowDepth[i] * unit) }
    }

    /// Leaves rest below ~35 degrees; snow clings a little more readily (56).
    private var gentleTan: Double { tan((isLeaf ? 35.0 : 56.0) * .pi / 180) }
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
    private var maxRest: Int { isLeaf ? 6 : 12 }
    private var lift: Double { 0 }

    // MARK: Geometry

    /// Logo frame (origin + size) in canvas points; `endY` is where airborne
    /// particles have fully faded; `spawnLift` how far above the logo they appear.
    func configure(origin: CGPoint, size: CGSize, endY: Double, spawnLift: Double, unit: Double, reduceMotion: Bool) {
        let key = "\(origin.x),\(origin.y),\(size.width),\(size.height),\(endY),\(spawnLift),\(unit)"
        guard !configured || key != geoKey else { return }
        geoKey = key
        ox = Double(origin.x); oy = Double(origin.y); lw = Double(size.width); lh = Double(size.height)
        self.endY = endY; self.unit = unit; spawnY = oy - spawnLift * unit
        buildSurface()
        let first = !configured
        configured = true
        guard first else { return }
        if !isLeaf {
            for i in 0..<LogoHeightMap.columns where gentleCols.contains(i) { snowDepth[i] = snowCap[i] * (reduceMotion ? 0.6 : 0.5) }
            smoothSnow(passes: 3)
            if reduceMotion { return }
        }
        if reduceMotion {
            var xs: [Double] = []
            for _ in 0..<(isLeaf ? 5 : 8) {
                if var p = restingAtGentle(avoiding: xs, spacing: isLeaf ? 12 : 6) {
                    p.restFor = 1e9; p.t = 1; p.sy = isLeaf ? 0.6 : 0.5
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

    private func buildSurface() {
        let n = LogoHeightMap.columns
        let raw = LogoHeightMap.top.map { $0.isNaN ? Double.nan : oy + $0 * lh }
        var s = [Double](repeating: .nan, count: n)
        for i in 0..<n where !raw[i].isNaN {
            var sum = 0.0, c = 0.0
            for j in max(0, i - 2)...min(n - 1, i + 2) where !raw[j].isNaN { sum += raw[j]; c += 1 }
            s[i] = sum / c
        }
        hs = s
        let cw = lw / Double(n)
        slopeAbs = [Double](repeating: 99, count: n)
        downDir = [Double](repeating: 1, count: n)
        tangDeg = [Double](repeating: 0, count: n)
        gentleCols = []
        for i in 0..<n where !s[i].isNaN {
            func side(_ j: Int) -> Double? { (j >= 0 && j < n && !s[j].isNaN) ? (s[j] - s[i]) : nil }
            let l = side(i - 3), rr = side(i + 3)
            // A missing neighbour means the artwork ends (a cliff): steep.
            let sl = l.map { abs($0) / (3 * cw) } ?? 99
            let sr = rr.map { abs($0) / (3 * cw) } ?? 99
            slopeAbs[i] = max(sl, sr)
            let gl = l ?? 0, gr = rr ?? 0
            downDir[i] = gr >= gl ? 1 : -1
            if let a = side(i - 2), let b = side(i + 2) {
                tangDeg[i] = atan((b - a) / (4 * cw)) * 180 / .pi
            }
            if slopeAbs[i] < gentleTan { gentleCols.append(i) }
        }
        snowCap = (0..<n).map { i in
            guard !s[i].isNaN else { return 0 }
            let y = LogoHeightMap.top[i], x = (Double(i) + 0.5) / Double(n)
            let cabin = x > 0.39 && x < 0.60 && y < 0.62
            return (cabin || y >= 0.62) ? 3.0 : 1.8
        }
        if snowDepth.count != n { snowDepth = [Double](repeating: 0, count: n) }
        let valid = (0..<n).filter { !s[$0].isNaN }
        artMinX = ox + (Double(valid.first ?? 0)) * cw
        artMaxX = ox + (Double(valid.last ?? n - 1) + 1) * cw
    }

    private func colX(_ i: Int) -> Double { ox + (Double(i) + 0.5) * lw / Double(LogoHeightMap.columns) }
    private func nearestCol(_ x: Double) -> Int? {
        let n = LogoHeightMap.columns
        let i = Int(((x - ox) / lw * Double(n)).rounded(.down))
        return (i >= 0 && i < n && !hs[i].isNaN) ? i : nil
    }
    private func surfY(_ x: Double) -> Double? {
        let n = LogoHeightMap.columns
        let u = (x - ox) / lw * Double(n) - 0.5
        let i0 = Int(u.rounded(.down))
        guard i0 >= 0, i0 + 1 < n else { return nil }
        let a = hs[i0], b = hs[i0 + 1]
        guard !a.isNaN, !b.isNaN else { return nil }
        return a + (b - a) * (u - Double(i0))
    }
    private func isGentle(_ x: Double) -> Bool { nearestCol(x).map { slopeAbs[$0] < gentleTan } ?? false }

    // MARK: Spawn

    private func airParticle() -> P {
        var p = P()
        if isLeaf {
            p.back = chance(0.35)
            p.size = p.back ? r(11, 17) * 0.7 / 0.7 : r(11, 17)   // back layer scaled 0.7 at draw
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
        var cols = gentleCols.shuffled(using: &rng)
        cols.removeAll { c in xs.contains { abs($0 - colX(c)) < spacing * unit } }
        guard let c = cols.first, let sy = surfY(colX(c)) else { return nil }
        var p = airParticle()
        p.back = false
        p.alpha = 1
        p.px = colX(c) + r(-0.4, 0.4) * unit
        p.py = sy - lift
        p.phase = .rest
        p.sx = 1; p.sy = isLeaf ? 0.6 : 0.5
        p.restTo = tangDeg[c] + (chance(0.5) ? 90 : -90) + r(-12, 12)
        p.rot = p.restTo; p.restFrom = p.restTo
        p.restFor = isLeaf ? r(10, 18) : r(6, 9)
        p.t = 1
        return p
    }

    // MARK: Step

    func advance(to date: Date) {
        guard configured else { return }
        guard let last = lastDate else { lastDate = date; return }
        guard date > last else { return }          // two canvases share this: stay monotonic
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
                // contact with the artwork
                if !p.back, !p.noRest, let sy = surfY(p.px) {
                    let over = p.y - (sy - lift)
                    if over >= 0 && over < 4 * unit {
                        p.landSX = p.sx; p.landSY = p.sy
                        p.py = sy - lift
                        if isLeaf {
                            p.phase = .slide; p.t = 0
                            p.slideV = max(-12 * unit, min(12 * unit, (vlat + wind) * 0.25))
                        } else {
                            if isGentle(p.px), let c = nearestCol(p.px) { deposit(c) }
                            removeIdx.append(i); ps[i] = p; continue
                        }
                    }
                }
            case .slide:
                p.t += dt
                let x = p.px
                guard let sy = surfY(x), let ci = nearestCol(x) else { toAir(&p); ps[i] = p; continue }
                let gentle = slopeAbs[ci] < gentleTan
                var crowdDir = 0.0
                var crowd = 0
                for (j, q) in ps.enumerated() where j != i && q.phase == .rest && !q.back && abs(q.px - x) < 10 * unit {
                    crowd += 1; crowdDir = x >= q.px ? 1 : -1
                }
                let crowded = crowd >= 2
                if gentle && !crowded && p.t > 0.2 && abs(p.slideV) < 14 * unit {
                    p.phase = .rest; p.t = 0
                    p.slideV = 0
                    p.restFrom = p.rot
                    let base = tangDeg[ci] + (chance(0.5) ? 90 : -90) + r(-12, 12)
                    p.restTo = p.rot + shortest(p.rot, base)
                    p.restFor = r(10, 18)
                    p.landSY = p.sy; p.landSX = p.sx
                    p.px = x; p.py = sy - lift
                    ps[i] = p; continue
                }
                if gentle {
                    if crowded {
                        p.slideV = crowdDir * max(abs(p.slideV), 10 * unit)
                    } else {
                        p.slideV *= (1 - 2.5 * dt)
                    }
                } else {
                    p.slideV += downDir[ci] * 70 * unit * dt
                    p.slideV = max(-45 * unit, min(45 * unit, p.slideV))
                }
                let nx = x + p.slideV * dt
                guard let ny = surfY(nx), let nc = nearestCol(nx), ny - sy < 2.2 * unit else {
                    p.px = nx; toAir(&p); ps[i] = p; continue
                }
                p.px = nx; p.py = ny - lift
                let target = tangDeg[nc] + (p.slideV >= 0 ? 90 : -90) * 0 + p.rot.rounded(.towardZero) * 0
                _ = target
                // turn toward the surface while rolling a little
                let roll = p.slideV * 1.4
                p.rot += (tangDeg[nc] + 90 * (shortest(0, p.rot - tangDeg[nc]) >= 0 ? 1 : -1) - p.rot) * min(1, 3 * dt)
                p.rot += roll * dt
                let e = min(p.t / 0.3, 1)
                p.sx = p.landSX + (1 - p.landSX) * e
                p.sy = p.landSY + (0.6 - p.landSY) * e
            case .rest:
                p.t += dt
                if let sy = surfY(p.px) {
                    let u = min(p.t / 0.5, 1)
                    let bump = (isLeaf ? 0.9 : 0.4) * unit * sin(.pi * u)
                    p.py = sy - lift + bump
                }
                let e = 1 - pow(1 - min(p.t / 0.35, 1), 2)
                p.sx = p.landSX + (1 - p.landSX) * e
                let tgtSY = isLeaf ? 0.6 : 0.5
                p.sy = p.landSY + (tgtSY - p.landSY) * e
                p.rot = p.restFrom + shortest(p.restFrom, p.restTo) * e
                if !isLeaf, p.t >= p.restFor + p.meltLen { removeIdx.append(i) }
            }
            ps[i] = p
        }
        if !removeIdx.isEmpty {
            let s = Set(removeIdx)
            ps = ps.enumerated().filter { !s.contains($0.offset) }.map { $0.element }
        }

        if !isLeaf {
            for i in snowDepth.indices where snowDepth[i] > 0 { snowDepth[i] = max(0, snowDepth[i] - 0.009 * dt) }
            snowTick += 1
            if snowTick % 10 == 0 { smoothSnow(passes: 1) }
        }
        spawnIn -= dt
        if spawnIn <= 0 {
            let air = ps.filter { $0.phase == .air }.count
            let resting = ps.count - air
            if air < maxAir && resting < maxRest { ps.append(airParticle()) }
            spawnIn = isLeaf ? r(1.6, 3.2) : r(0.35, 0.8)
        }
    }

    private func deposit(_ c: Int) {
        let n = LogoHeightMap.columns
        for (d, w) in [(0, 1.0), (1, 0.6), (2, 0.35), (3, 0.15)] {
            for j in Set([c - d, c + d]) where j >= 0 && j < n && !hs[j].isNaN {
                snowDepth[j] = min(snowCap[j], snowDepth[j] + 0.5 * w)
            }
        }
    }

    private func smoothSnow(passes: Int) {
        let n = LogoHeightMap.columns
        for _ in 0..<passes {
            var o = snowDepth
            for i in 0..<n where !hs[i].isNaN {
                let l = i > 0 ? snowDepth[i - 1] : 0, rr = i < n - 1 ? snowDepth[i + 1] : 0
                o[i] = 0.5 * snowDepth[i] + 0.25 * (l + rr)
                let gentle = slopeAbs[i] < gentleTan
                o[i] = min(o[i], gentle ? snowCap[i] : 0.25)
            }
            snowDepth = o
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
        case .slide: return p.alpha
        case .rest:
            if isLeaf { return p.alpha }
            return p.alpha * max(0, 1 - max(0, p.t - p.restFor) / max(p.meltLen, 0.01))
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
                if kind == .snow && layer == .front { drawCap(sim, &c) }
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

    /// Thin snow cap hugging the silhouette top where snow has built up.
    private func drawCap(_ sim: ParticleSim, _ ctx: inout GraphicsContext) {
        let cols = sim.capColumns
        var run: [(x: Double, base: Double, depth: Double)] = []
        func flush() {
            guard run.count >= 2 else { run = []; return }
            var path = Path()
            path.move(to: CGPoint(x: run[0].x, y: run[0].base + 0.3))
            for c in run { path.addLine(to: CGPoint(x: c.x, y: c.base - c.depth)) }
            for c in run.reversed() { path.addLine(to: CGPoint(x: c.x, y: c.base + 0.3)) }
            path.closeSubpath()
            ctx.fill(path, with: .color(.white))
            ctx.stroke(path, with: .color(Self.cool.opacity(0.6)), style: StrokeStyle(lineWidth: 0.6, lineJoin: .round))
            run = []
        }
        for c in cols {
            if c.depth > 0.12 { run.append(c) } else { flush() }
        }
        flush()
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
