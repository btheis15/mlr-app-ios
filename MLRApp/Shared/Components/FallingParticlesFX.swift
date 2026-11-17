import SwiftUI

// MARK: - Falling leaves / snow that land
//
// Live particle scene for the Home logo (fall = leaves, winter = snow).
// One TimelineView + Canvas; a fixed-step simulation (1/60 s) driven from the
// timeline date with dt capped so a pause never teleports particles.
// Geometry (ground Y, horizontal bounds, spawn height) comes from the layout.

enum ParticleKind { case leaf, snow }

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
    enum Phase { case air, land, rest, fade }

    struct P {
        var phase = Phase.air
        var x0 = 0.0, y = 0.0          // air: base x (wind-integrated) and y
        var vTerm = 36.0, amp = 12.0, omega = 2.8, phi = 0.0
        var flutterW = 2.0, flutterPhi = 0.0
        var size = 1.0, alpha = 1.0, color: UInt32 = 0xd9531e
        var groundOff = 0.0
        var t = 0.0                    // time in current phase
        var life = 0.0                 // air time
        // landing
        var landX = 0.0, slide = 0.0, landRot = 0.0, restRot = 0.0, landSX = 1.0
        var restFor = 9.0
        var nudgeFrom = 0.0, nudgeTo = 0.0, nudgeT = 99.0
        // current pose (written by step)
        var px = 0.0, py = 0.0, rot = 0.0, sx = 1.0, sy = 1.0
    }

    let kind: ParticleKind
    private(set) var ps: [P] = []
    private var rng: SplitMix
    private var minX = 0.0, maxX = 0.0, top = 0.0, ground = 0.0, unit = 1.0
    private var configured = false
    private var lastDate: Date?
    private var acc = 0.0
    private var simT = 0.0
    private var spawnIn = 1.5
    private var gustAt = 7.0, gustLen = 2.2, gustV = 0.0
    private var fastForward: Double
    static let dt = 1.0 / 60
    private static let palette: [UInt32] = [0xd9531e, 0xe8a317, 0xb5341c, 0xc9771a, 0xe8a317, 0xd9531e]

    init(kind: ParticleKind, fastForward: Double = 0, seed: UInt64) {
        self.kind = kind
        self.fastForward = fastForward
        self.rng = SplitMix(s: seed)
    }

    private func r(_ a: Double, _ b: Double) -> Double { Double.random(in: a...b, using: &rng) }
    private var maxAir: Int { kind == .leaf ? 5 : 7 }
    private var maxRest: Int { kind == .leaf ? 7 : 12 }

    /// bounds in canvas points: x range, spawn top, ground line.
    func configure(minX: Double, maxX: Double, top: Double, ground: Double, unit: Double, reduceMotion: Bool) {
        let changed = minX != self.minX || maxX != self.maxX || top != self.top || ground != self.ground
        guard !configured || changed else { return }
        let first = !configured
        self.minX = minX; self.maxX = maxX; self.top = top; self.ground = ground; self.unit = unit
        configured = true
        guard first else { return }
        if reduceMotion {
            for _ in 0..<(kind == .leaf ? 5 : 8) { ps.append(restingParticle(life: 99)) }
            return
        }
        for _ in 0..<(kind == .leaf ? Int.random(in: 2...3, using: &rng) : 4) {
            var p = restingParticle(life: 0)
            p.t = r(0.5, 4)
            ps.append(p)
        }
        for _ in 0..<2 {
            var p = airParticle()
            p.y = top + (ground - top) * r(0.25, 0.65)
            ps.append(p)
        }
        spawnIn = r(1.2, 2.6)
        gustAt = r(6, 10)
        if fastForward > 0 {
            let n = Int(fastForward / Self.dt)
            for _ in 0..<n { step() }
            fastForward = 0
        }
    }

    // MARK: Spawn

    private func airParticle() -> P {
        var p = P()
        let sizeIdx = Int.random(in: 0...2, using: &rng)
        let sizeNorm = Double(sizeIdx) / 2
        if kind == .leaf {
            p.size = [0.7, 1.0, 1.3][sizeIdx]
            p.alpha = [0.78, 0.9, 1.0][sizeIdx]
            p.vTerm = 28 + 17 * (0.5 * r(0, 1) + 0.5 * sizeNorm)
            p.amp = r(8, 18)
            p.omega = 2 * .pi / r(1.6, 2.6)
            p.color = Self.palette[Int.random(in: 0..<Self.palette.count, using: &rng)]
        } else {
            p.size = [0.7, 1.0, 1.3][sizeIdx]
            p.alpha = [0.8, 0.92, 1.0][sizeIdx]
            p.vTerm = 17 + 12 * (0.5 * r(0, 1) + 0.5 * sizeNorm)
            p.amp = r(4, 9)
            p.omega = 2 * .pi / r(2.2, 3.4)
        }
        p.phi = r(0, 2 * .pi)
        p.flutterW = 2 * .pi / r(2.4, 4.0)
        p.flutterPhi = r(0, 2 * .pi)
        p.groundOff = kind == .leaf ? r(0, 5) : r(0, 3)
        p.x0 = r(minX + p.amp, max(minX + p.amp + 1, maxX - p.amp))
        p.y = top - 6 * unit
        return p
    }

    private func restingParticle(life: Double) -> P {
        var p = airParticle()
        p.phase = .rest
        p.x0 = r(minX, maxX)
        p.landX = p.x0
        p.restRot = restAngle()
        p.landRot = p.restRot
        p.t = life
        p.restFor = restDuration()
        p.landSX = 1
        return p
    }

    private func restAngle() -> Double {
        kind == .snow ? 0 : (Bool.random(using: &rng) ? 0 : 180) + r(-18, 18)
    }
    private func restDuration() -> Double { kind == .leaf ? r(7, 12) : r(6, 9) }
    private var fadeLen: Double { kind == .leaf ? 1.5 : 2.5 }

    // MARK: Step

    func advance(to date: Date) {
        guard configured else { return }
        defer { lastDate = date }
        guard let last = lastDate else { return }
        acc += min(max(date.timeIntervalSince(last), 0), 0.25)
        while acc >= Self.dt { acc -= Self.dt; step() }
    }

    private func step() {
        let dt = Self.dt
        simT += dt
        // Shared wind: gentle bell-shaped drift for ~2 s every 6-10 s.
        var wind = 0.0
        if simT >= gustAt {
            let u = (simT - gustAt) / gustLen
            if u <= 1 {
                if gustV == 0 {
                    gustV = (Bool.random(using: &rng) ? 1 : -1) * r(9, 16) * unit
                    for i in ps.indices where ps[i].phase == .rest && Double.random(in: 0...1, using: &rng) < 0.35 {
                        ps[i].nudgeFrom = ps[i].px
                        ps[i].nudgeTo = ps[i].px + (gustV > 0 ? 1 : -1) * r(2, 4) * unit
                        ps[i].nudgeT = 0
                    }
                }
                wind = gustV * sin(.pi * u)
            } else {
                gustV = 0
                gustAt = simT + r(6, 10)
                gustLen = r(1.8, 2.4)
            }
        }
        let tiltMax = 35.0
        for i in ps.indices {
            var p = ps[i]
            switch p.phase {
            case .air:
                p.life += dt
                let a = p.omega * p.life + p.phi
                p.x0 += wind * dt
                let lat = p.amp * unit * sin(a)
                let vx = p.amp * unit * p.omega * cos(a)
                p.px = min(max(p.x0 + lat, minX - 4 * unit), maxX + 4 * unit)
                let speed = p.vTerm * unit * (0.75 + 0.25 * abs(cos(a)))
                p.y += speed * dt
                p.rot = (kind == .leaf ? tiltMax * cos(a) : 0)
                p.sx = kind == .leaf ? 0.675 + 0.325 * sin(p.flutterW * p.life + p.flutterPhi) : 1
                p.sy = 1
                p.py = p.y
                let gy = ground + p.groundOff * unit
                if p.y >= gy {
                    p.phase = .land; p.t = 0
                    p.landX = p.px
                    p.landRot = p.rot
                    p.landSX = p.sx
                    p.restRot = restAngle()
                    let dir: Double = vx >= 0 ? 1 : -1
                    p.slide = kind == .leaf ? dir * r(3, 8) * unit : 0
                    // keep the slide inside the bounds
                    if p.landX + p.slide < minX || p.landX + p.slide > maxX { p.slide = -p.slide }
                    p.restFor = restDuration()
                    p.py = gy
                }
            case .land, .rest, .fade:
                p.t += dt
                let gy = ground + p.groundOff * unit
                if p.phase == .land {
                    let u = min(p.t / 0.5, 1)
                    let e = 1 - pow(1 - u, 3)
                    p.px = p.landX + p.slide * e
                    p.rot = p.landRot + shortest(p.landRot, p.restRot) * e
                    let flat = min(p.t / 0.45, 1)
                    p.sx = p.landSX + (1 - p.landSX) * flat
                    p.sy = 1 - (kind == .leaf ? 0.45 : 0.5) * (1 - pow(1 - flat, 2))
                    // one tiny settle: dip below the line then return
                    let su = max(0, min((p.t - 0.25) / 0.5, 1))
                    let bump = (kind == .leaf ? 1.5 : 0.8) * unit * sin(.pi * su)
                    p.py = gy + bump
                    if p.t >= 0.9 { p.phase = .rest; p.t = 0; p.landX = p.px; p.landRot = p.rot; p.restRot = p.rot }
                } else {
                    p.sx = 1; p.sy = kind == .leaf ? 0.55 : 0.5
                    p.py = gy
                    if p.nudgeT < 0.6 {
                        p.nudgeT += dt
                        let u = min(p.nudgeT / 0.6, 1)
                        p.px = p.nudgeFrom + (p.nudgeTo - p.nudgeFrom) * (1 - pow(1 - u, 3))
                        p.px = min(max(p.px, minX - 4 * unit), maxX + 4 * unit)
                    } else if p.nudgeT < 90 {
                        p.landX = p.px
                    } else {
                        p.px = p.landX
                    }
                    p.rot = p.restRot
                    if p.phase == .rest, p.t >= p.restFor { p.phase = .fade; p.t = 0 }
                }
            }
            ps[i] = p
        }
        ps.removeAll { $0.phase == .fade && $0.t >= fadeLen }

        spawnIn -= dt
        if spawnIn <= 0 {
            let air = ps.filter { $0.phase == .air }.count
            let resting = ps.count - air
            if air < maxAir && resting < maxRest { ps.append(airParticle()) }
            spawnIn = r(1.2, 2.6)
        }
    }

    private func shortest(_ from: Double, _ to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }

    func opacity(of p: P) -> Double {
        switch p.phase {
        case .fade: return p.alpha * max(0, 1 - p.t / fadeLen)
        case .air:
            // fade in just above the artwork
            return p.alpha * min(1, max(0, (p.y - (top - 6 * unit)) / (4 * unit) + 0.3))
        default: return p.alpha
        }
    }
}

struct FallingParticlesFX: View {
    let kind: ParticleKind
    /// Extra distance the ground sits below the logo frame (dark plaque inner edge).
    var groundInset: CGFloat = 0
    /// Horizontal inset of the playable area from the logo frame edges.
    var sideInset: CGFloat = 4

    private static let extend: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            ParticleScene(kind: kind, logoSize: geo.size, groundInset: groundInset,
                          sideInset: sideInset, extend: Self.extend)
                .frame(width: geo.size.width + 2 * Self.extend, height: geo.size.height + 2 * Self.extend)
                .offset(x: -Self.extend, y: -Self.extend)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ParticleScene: View {
    let kind: ParticleKind
    let logoSize: CGSize
    let groundInset: CGFloat
    let sideInset: CGFloat
    let extend: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = true
    @State private var sim: ParticleSim

    init(kind: ParticleKind, logoSize: CGSize, groundInset: CGFloat, sideInset: CGFloat, extend: CGFloat) {
        self.kind = kind; self.logoSize = logoSize; self.groundInset = groundInset
        self.sideInset = sideInset; self.extend = extend
        var ff = 0.0
        var seed = UInt64.random(in: 1...UInt64.max)
        #if DEBUG
        if let v = UserDefaults.standard.object(forKey: "leafTime") as? NSNumber ?? (UserDefaults.standard.string(forKey: "leafTime").flatMap { Double($0) as NSNumber? }) {
            ff = v.doubleValue; seed = 42
        }
        #endif
        _sim = State(initialValue: ParticleSim(kind: kind, fastForward: ff, seed: seed))
    }

    var body: some View {
        let active = scenePhase == .active && onScreen && !reduceMotion
        TimelineView(.animation(paused: !active)) { tl in
            Canvas { ctx, size in
                let w = Double(logoSize.width)
                let unit = max(0.5, w / 104)
                sim.configure(minX: Double(extend + sideInset), maxX: Double(extend + logoSize.width - sideInset),
                              top: Double(extend), ground: Double(extend + logoSize.height + groundInset),
                              unit: unit, reduceMotion: reduceMotion)
                if !reduceMotion { sim.advance(to: tl.date) }
                let k = w / 1340 * 1.35
                for p in sim.ps { draw(p, &ctx, k) }
            }
        }
        .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
    }

    private func draw(_ p: ParticleSim.P, _ ctx: inout GraphicsContext, _ k: Double) {
        var g = ctx
        g.opacity = sim.opacity(of: p)
        g.translateBy(x: p.px, y: p.py)
        if kind == .leaf {
            g.scaleBy(x: 1, y: p.sy)
            g.rotate(by: .degrees(p.rot))
            g.scaleBy(x: p.sx * k * p.size, y: k * p.size)
            g.fill(Self.leafPath, with: .color(Self.rgb(p.color)))
            g.stroke(Self.leafVein, with: .color(.black.opacity(0.2)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        } else {
            let r = 1.7 * p.size
            let melt = p.phase == .fade ? max(0.2, 1 - p.t / 2.5) : 1
            let rect = CGRect(x: -r * (p.phase == .air ? 1 : 1.5) * melt, y: -r * p.sy * melt,
                              width: 2 * r * (p.phase == .air ? 1 : 1.5) * melt, height: 2 * r * p.sy * melt)
            g.fill(Path(ellipseIn: rect), with: .color(.white))
            g.stroke(Path(ellipseIn: rect), with: .color(Color(red: 0xa9 / 255, green: 0xc4 / 255, blue: 0xda / 255)), lineWidth: 0.6)
        }
    }

    private static let leafPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -34))
        p.addCurve(to: CGPoint(x: 0, y: 34), control1: CGPoint(x: 24, y: -24), control2: CGPoint(x: 28, y: 10))
        p.addCurve(to: CGPoint(x: 0, y: -34), control1: CGPoint(x: -28, y: 10), control2: CGPoint(x: -24, y: -24))
        return p
    }()
    private static let leafVein: Path = {
        var p = Path(); p.move(to: CGPoint(x: 0, y: -30)); p.addLine(to: CGPoint(x: 0, y: 40)); return p
    }()
    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}
