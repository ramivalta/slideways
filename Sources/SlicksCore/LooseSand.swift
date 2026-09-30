import Foundation

/// Sand kicked out of sand traps during a race. Each race has its own layer on top of the
/// track's fixed surfaces, starting empty.
///
/// Sand gets out three ways: sliding or spinning tires throw it off the edge of a trap, tires
/// that drove through sand shed what they picked up over the next stretch of road, and tires
/// rolling over loose sand drag it along. Rolling over loose sand also sweeps it away over time,
/// so the racing line cleans itself up. Loose sand makes a surface feel partly like sand,
/// in proportion to how much is lying there.
///
/// Everything runs off the race's seed, so a race plays out the same way every time.
public final class LooseSand {
    public let width: Int
    public let height: Int
    /// Loose sand per cell: 0 = none, 1 = as thick as a sand trap.
    public private(set) var amount: [Float]

    /// Most of sand's effect that a full cell of loose sand has on the surface beneath.
    public static let fullEffect = 0.85
    /// Coverage above which a car counts as driving on sand (skid mark color, sounds).
    public static let feelsLikeSand = 0.35

    private let track: Track
    private var rng: SplitMix64
    private var changedFlags: [Bool]
    private var changed: [Int] = []

    public init(track: Track, seed: UInt64) {
        self.track = track
        width = track.width
        height = track.height
        amount = [Float](repeating: 0, count: track.width * track.height)
        changedFlags = [Bool](repeating: false, count: track.width * track.height)
        rng = SplitMix64(seed: seed ^ 0x5A4D_5A4D)
    }

    // MARK: Queries

    public func coverage(x: Int, y: Int) -> Double {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return Double(amount[y * width + x])
    }

    public func coverage(at p: Vec2) -> Double {
        coverage(x: Int(floor(p.x)), y: Int(floor(p.y)))
    }

    /// How a surface behaves with a given amount of loose sand on it. A dusting on hard ground
    /// mostly costs grip; it takes a thick layer to bog a car down like a real trap.
    public static func properties(base: Surface, coverage: Double) -> SurfaceProperties {
        guard coverage > 0, base != .sand, base != .wall else { return base.properties }
        let t = clamp(coverage, 0, 1) * fullEffect
        let b = base.properties, s = Surface.sand.properties
        return SurfaceProperties(grip: b.grip + (s.grip - b.grip) * t,
                                 drag: b.drag + (s.drag - b.drag) * t * t,
                                 traction: b.traction + (s.traction - b.traction) * t)
    }

    /// Surface and handling at a point for a car on `level`, loose sand included.
    /// Bridge decks never get sand on them.
    public static func surface(track: Track, sand: LooseSand?, at p: Vec2, level: Int) -> (surface: Surface, properties: SurfaceProperties) {
        let base = track.surface(at: p, level: level)
        guard level == 0, let sand else { return (base, base.properties) }
        let c = sand.coverage(at: p)
        let feel = c > feelsLikeSand && base != .wall ? Surface.sand : base
        return (feel, properties(base: base, coverage: c))
    }

    /// Cells whose amount changed since the last call, for redrawing.
    public func drainChanges() -> [Int] {
        defer {
            for i in changed { changedFlags[i] = false }
            changed.removeAll(keepingCapacity: true)
        }
        return changed
    }

    /// Total loose sand, in full cells, and how much of it lies on the road.
    public func totals() -> (total: Double, onRoad: Double, roadCellsCovered: Int) {
        var total = 0.0, road = 0.0, covered = 0
        for i in 0..<amount.count where amount[i] > 0 {
            total += Double(amount[i])
            let s = track.surfaces[i]
            if s == .asphalt || s == .curb {
                road += Double(amount[i])
                if amount[i] >= 0.2 { covered += 1 }
            }
        }
        return (total, road, covered)
    }

    // MARK: Simulation

    /// Most sand a car's rear tires carry, in cells' worth.
    public static let tireCapacity = 24.0
    /// Sand picked up per second while driving through a trap at speed, in cells.
    static let pickUpRate = 60.0
    /// Fraction of carried sand shed per second at speed: at racing speed most of it is gone
    /// within a few car lengths.
    static let shedRate = 2.6
    /// Fraction of loose sand under a rolling tire swept away per second at speed.
    static let sweepRate = 1.2
    /// Of the sand a tire sweeps up, how much it carries on and drops further along.
    static let sweepCarry = 0.5
    /// Sand thrown per second by a hard slide at speed, in cells.
    static let sprayRate = 90.0

    /// Moves sand around under one car's rear tires for one step.
    func interact(with car: Car, dt: Double) {
        // Tires in the air (off a jump ramp) don't touch the ground.
        guard car.level == 0, !car.isAirborne, car.speed > 8 else { return }
        let fwd = car.forward, left = car.left
        let pace = clamp(car.speed / 200, 0, 1.5)
        let sliding = car.slip > car.spec.slideThreshold
        let lateral = car.velocity.dot(left)

        for side in [1.0, -1.0] {
            let tire = car.position - fwd * 6.9 + left * (3.8 * side)
            let base = track.surface(at: tire)
            if base == .sand {
                car.sandOnTires = min(Self.tireCapacity, car.sandOnTires + dt * Self.pickUpRate * pace * 0.5)
                guard sliding || car.isWheelspinning else { continue }
                // Sand flies the way the tire scrubs across the ground: out of the slide, and
                // backward when the wheels spin.
                var dir = left * (lateral >= 0 ? 1 : -1) * min(1, abs(lateral) / 60)
                if car.isWheelspinning { dir -= fwd * 1.2 }
                dir = dir.normalized
                guard dir.lengthSquared > 0 else { continue }
                let strength = car.isWheelspinning ? 0.6 : clamp((car.slip - car.spec.slideThreshold) / 110, 0.15, 1)
                spray(from: tire, direction: dir, mass: dt * Self.sprayRate * strength * pace)
            } else if base != .wall {
                // Tires shed what they carried out of the trap...
                if car.sandOnTires > 0.01 {
                    // Each rear tire sheds half of the car's share this step.
                    let drop = car.sandOnTires * min(1, dt * Self.shedRate * pace) * 0.5
                    car.sandOnTires -= drop
                    deposit(at: tire, mass: drop, radius: 1.8)
                }
                // ...and sweep up loose sand they roll over, carrying some of it along.
                let x = Int(floor(tire.x)), y = Int(floor(tire.y))
                for dy in -1...1 {
                    for dx in -1...1 {
                        let cx = x + dx, cy = y + dy
                        guard cx >= 0, cy >= 0, cx < width, cy < height else { continue }
                        let i = cy * width + cx
                        guard amount[i] > 0 else { continue }
                        let rate = Self.sweepRate * (sliding ? 2.2 : 1)
                        let take = amount[i] * Float(min(1, dt * rate * pace))
                        set(i, amount[i] - take)
                        car.sandOnTires = min(Self.tireCapacity, car.sandOnTires + Double(take) * Self.sweepCarry)
                    }
                }
            }
        }
    }

    /// Throws grains from a tire, landing a short way off in `direction`.
    private func spray(from p: Vec2, direction dir: Vec2, mass: Double) {
        guard mass > 0 else { return }
        // Enough grains to look scattered, each carrying an equal share.
        var count = Int(mass * 60)
        if Double.random(in: 0..<1, using: &rng) < mass * 60 - Double(count) { count += 1 }
        guard count > 0 else { return }
        let grain = mass / Double(count)
        let across = dir.perp
        for _ in 0..<count {
            let dist = Double.random(in: 5...24, using: &rng)
            let spread = Double.random(in: -0.45...0.45, using: &rng) * dist
            let q = p + dir * dist + across * spread
            deposit(at: q, mass: grain, radius: 0.8)
        }
    }

    /// Adds sand around a point, onto ground that can hold loose sand.
    private func deposit(at p: Vec2, mass: Double, radius r: Double) {
        let x0 = Int(floor(p.x - r)), x1 = Int(floor(p.x + r))
        let y0 = Int(floor(p.y - r)), y1 = Int(floor(p.y + r))
        var cells: [Int] = []
        for y in y0...y1 {
            for x in x0...x1 {
                guard x >= 0, y >= 0, x < width, y < height else { continue }
                let d = Vec2(Double(x) + 0.5, Double(y) + 0.5) - p
                guard d.lengthSquared <= max(r * r, 0.5) else { continue }
                let s = track.surfaces[y * width + x]
                // Sand traps are already sand; walls, bridge decks and water don't hold it.
                guard s != .sand, s != .wall, s != .water, track.deck(x: x, y: y) == nil else { continue }
                cells.append(y * width + x)
            }
        }
        guard !cells.isEmpty else { return }
        let share = Float(mass / Double(cells.count))
        for i in cells { set(i, min(1, amount[i] + share)) }
    }

    private func set(_ i: Int, _ value: Float) {
        // Sweeping leaves specks that would never quite reach zero; tidy those away.
        store(i, value < amount[i] && value < 0.002 ? 0 : value, journal: true)
    }

    /// Writes one cell, keeping the checksum and change lists up to date.
    private func store(_ i: Int, _ value: Float, journal: Bool) {
        let old = amount[i]
        guard value.bitPattern != old.bitPattern else { return }
        checksum = checksum &- Self.contribution(i, old) &+ Self.contribution(i, value)
        amount[i] = value
        if !changedFlags[i] {
            changedFlags[i] = true
            changed.append(i)
        }
        if journal, keepsJournal, !journalFlags[i] {
            journalFlags[i] = true
            journaled.append(i)
        }
    }

    // MARK: Online play

    /// Order-independent fingerprint of every cell, kept current as cells change, so state
    /// hashes can include the sand without scanning 576,000 cells.
    public private(set) var checksum: UInt64 = 0

    /// The random numbers spraying uses; part of the state that has to match between machines.
    public var rngState: UInt64 { rng.state }

    /// Record which cells change (separately from rendering's list), for sending to other
    /// machines or for undoing a prediction. Off by default: offline races don't need it.
    public var keepsJournal = false {
        didSet {
            if keepsJournal, journalFlags.isEmpty { journalFlags = [Bool](repeating: false, count: amount.count) }
        }
    }

    private var journalFlags: [Bool] = []
    private var journaled: [Int] = []

    /// Cells changed by the simulation since the last call (needs `keepsJournal`).
    public func drainJournal() -> [Int] {
        defer {
            for i in journaled { journalFlags[i] = false }
            journaled.removeAll(keepingCapacity: true)
        }
        return journaled
    }

    /// Takes cell values and the RNG from elsewhere (the host). Cells are redrawn but not
    /// journaled: this isn't the simulation's doing.
    public func apply(cells: [(index: Int, value: Float)], rngState: UInt64) {
        for c in cells where amount.indices.contains(c.index) { store(c.index, c.value, journal: false) }
        rng = SplitMix64(seed: rngState)
    }

    /// Everything about the sand that changes during a race.
    public struct State: Codable, Sendable, Equatable {
        public var amount: [Float]
        public var rngState: UInt64
    }

    /// A copy for snapshots. Cheap to take (the array is shared until one side changes).
    public var state: State { State(amount: amount, rngState: rng.state) }

    /// Puts the sand back as it was in `s`, redrawing the cells that differ.
    public func restore(_ s: State) {
        guard s.amount.count == amount.count else { return }
        for i in amount.indices where amount[i].bitPattern != s.amount[i].bitPattern {
            store(i, s.amount[i], journal: true)
        }
        rng = SplitMix64(seed: s.rngState)
    }

    /// A cell's share of the checksum: zero for empty cells, so all-empty sums to zero.
    static func contribution(_ i: Int, _ value: Float) -> UInt64 {
        guard value != 0 else { return 0 }
        var z = UInt64(truncatingIfNeeded: i) << 32 | UInt64(value.bitPattern)
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SurfaceProperties {
    /// Blend toward another surface's handling.
    public func mixed(with o: SurfaceProperties, _ t: Double) -> SurfaceProperties {
        SurfaceProperties(grip: grip + (o.grip - grip) * t, drag: drag + (o.drag - drag) * t,
                          traction: traction + (o.traction - traction) * t)
    }
}
