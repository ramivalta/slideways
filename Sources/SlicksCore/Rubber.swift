import Foundation

/// Tire rubber laid on the road during a race. Each race starts on a clean track.
///
/// Every tire rolling over asphalt or curbs leaves a trace of rubber, and sliding, locking up
/// or spinning the wheels leaves a lot more. The racing line gradually rubbers in, and the
/// more rubber there is, the more grip the road gives, up to `gripGain` more when fully rubbered.
///
/// Rubber is kept on a grid of `cellSize`-pixel cells, sampled smoothly between cell centres,
/// so a car's grip (looked up at its centre) sees the rubber its own tires lay either side.
/// It's all plain arithmetic on car state, so a race plays out the same way every time.
public final class Rubber {
    /// Track pixels per rubber cell, a little over half a car's width.
    public static let cellSize = 6
    /// Extra lateral grip on fully rubbered road: 1.12 × the surface's own.
    public static let gripGain = 0.12
    /// Extra engine and brake traction on fully rubbered road.
    public static let tractionGain = 0.06
    /// Sideways speed above which tires leave skid marks and heavy rubber.
    public static let markingSlip = 22.0

    /// Rubber a rolling tire leaves on each pass: the racing line rubbers in over many laps.
    static let rollingPerPass = 0.012
    /// Rubber a sliding, locked or spinning tire leaves on each pass.
    static let markingPerPass = 0.12
    /// Wheelspin scrubs the tire over the road faster than the car moves.
    static let wheelspinScrubSpeed = 120.0

    public let columns: Int
    public let rows: Int
    /// Rubber per cell: 0 = clean, 1 = fully rubbered. Row-major, row 0 at the bottom.
    public private(set) var amount: [Float]

    private let track: Track
    private var changedFlags: [Bool]
    private var changed: [Int] = []

    public init(track: Track) {
        self.track = track
        columns = (track.width + Self.cellSize - 1) / Self.cellSize
        rows = (track.height + Self.cellSize - 1) / Self.cellSize
        amount = [Float](repeating: 0, count: columns * rows)
        changedFlags = [Bool](repeating: false, count: columns * rows)
    }

    // MARK: Queries

    /// Whether a car's tires are marking the road: sliding, braking hard or spinning.
    /// Shared with the skid mark drawing so the two agree.
    public static func isMarking(_ car: Car) -> Bool {
        !car.isAirborne && (car.slip > markingSlip || (car.isBraking && car.speed > 70) || car.isWheelspinning)
    }

    /// Rubber at a point, blended between the surrounding cell centres.
    public func level(at p: Vec2) -> Double {
        let s = Double(Self.cellSize)
        let gx = p.x / s - 0.5, gy = p.y / s - 0.5
        let x0 = Int(floor(gx)), y0 = Int(floor(gy))
        let fx = gx - Double(x0), fy = gy - Double(y0)
        let bottom = cell(x0, y0) * (1 - fx) + cell(x0 + 1, y0) * fx
        let top = cell(x0, y0 + 1) * (1 - fx) + cell(x0 + 1, y0 + 1) * fx
        return bottom * (1 - fy) + top * fy
    }

    private func cell(_ x: Int, _ y: Int) -> Double {
        guard x >= 0, y >= 0, x < columns, y < rows else { return 0 }
        return Double(amount[y * columns + x])
    }

    /// Whether a surface takes rubber (and grips better for it).
    public static func holdsRubber(_ s: Surface) -> Bool { s == .asphalt || s == .curb }

    /// How a surface behaves with a given amount of rubber on it.
    public static func properties(base: Surface, rubber r: Double) -> SurfaceProperties {
        let b = base.properties
        guard r > 0, holdsRubber(base) else { return b }
        let t = clamp(r, 0, 1)
        return SurfaceProperties(grip: b.grip * (1 + gripGain * t), drag: b.drag,
                                 traction: b.traction * (1 + tractionGain * t))
    }

    /// Cells whose amount changed since the last call, for redrawing.
    public func drainChanges() -> [Int] {
        defer {
            for i in changed { changedFlags[i] = false }
            changed.removeAll(keepingCapacity: true)
        }
        return changed
    }

    /// Mean rubber over the cells that have any, the most on one cell, and how many cells
    /// carry at least `threshold`.
    public func totals(threshold: Float = 0.25) -> (mean: Double, peak: Double, cellsAbove: Int) {
        var sum = 0.0, touched = 0, peak: Float = 0, above = 0
        for a in amount where a > 0 {
            sum += Double(a)
            touched += 1
            peak = max(peak, a)
            if a >= threshold { above += 1 }
        }
        return (touched > 0 ? sum / Double(touched) : 0, Double(peak), above)
    }

    // MARK: Simulation

    /// Lays rubber under one car's rear tires for one step.
    func interact(with car: Car, dt: Double) {
        // Bridge decks and tires in the air don't collect rubber.
        guard car.level == 0, !car.isAirborne, car.speed > 8 else { return }
        let marking = Self.isMarking(car)
        let perPass: Double
        var scrubSpeed = car.speed
        if marking {
            // Harder slides lay more; spinning wheels scrub even when the car is barely moving.
            let slide = car.slip > Self.markingSlip ? clamp(car.slip / 80, 0.5, 1.5) : 1
            perPass = Self.markingPerPass * slide
            if car.isWheelspinning { scrubSpeed = max(scrubSpeed, Self.wheelspinScrubSpeed) }
        } else {
            perPass = Self.rollingPerPass
        }
        // A tire crosses a cell in about cellSize / distance steps, so this adds up to
        // roughly `perPass` for each pass over a cell.
        let k = perPass * scrubSpeed * dt / Double(Self.cellSize)
        let fwd = car.forward, left = car.left
        for side in [1.0, -1.0] {
            // Rear tire contact patches, as for loose sand and skid marks.
            let tire = car.position - fwd * 6.9 + left * (3.8 * side)
            guard Self.holdsRubber(track.surface(at: tire)) else { continue }
            lay(at: tire, k)
        }
    }

    /// Adds rubber at a point, shared between the four nearest cells. Each cell fills up
    /// toward 1 with diminishing returns.
    private func lay(at p: Vec2, _ k: Double) {
        let s = Double(Self.cellSize)
        let gx = p.x / s - 0.5, gy = p.y / s - 0.5
        let x0 = Int(floor(gx)), y0 = Int(floor(gy))
        let fx = gx - Double(x0), fy = gy - Double(y0)
        add(x0, y0, k * (1 - fx) * (1 - fy))
        add(x0 + 1, y0, k * fx * (1 - fy))
        add(x0, y0 + 1, k * (1 - fx) * fy)
        add(x0 + 1, y0 + 1, k * fx * fy)
    }

    private func add(_ x: Int, _ y: Int, _ k: Double) {
        guard k > 0, x >= 0, y >= 0, x < columns, y < rows else { return }
        let i = y * columns + x
        store(i, amount[i] + (1 - amount[i]) * Float(min(1, k)), journal: true)
    }

    /// Writes one cell, keeping the checksum and change lists up to date.
    private func store(_ i: Int, _ value: Float, journal: Bool) {
        let old = amount[i]
        guard value.bitPattern != old.bitPattern else { return }
        checksum = checksum &- LooseSand.contribution(i, old) &+ LooseSand.contribution(i, value)
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
    /// hashes can include the rubber without scanning the grid.
    public private(set) var checksum: UInt64 = 0

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

    /// Takes cell values from elsewhere (the host). Cells are redrawn but not journaled:
    /// this isn't the simulation's doing.
    public func apply(cells: [(index: Int, value: Float)]) {
        for c in cells where amount.indices.contains(c.index) { store(c.index, c.value, journal: false) }
    }

    /// Everything about the rubber that changes during a race.
    public struct State: Codable, Sendable, Equatable {
        public var amount: [Float]
    }

    /// A copy for snapshots. Cheap to take (the array is shared until one side changes).
    public var state: State { State(amount: amount) }

    /// Puts the rubber back as it was in `s`, redrawing the cells that differ.
    public func restore(_ s: State) {
        guard s.amount.count == amount.count else { return }
        for i in amount.indices where amount[i].bitPattern != s.amount[i].bitPattern {
            store(i, s.amount[i], journal: true)
        }
    }
}
