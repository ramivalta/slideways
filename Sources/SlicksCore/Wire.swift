import Foundation
// Byte coding lives in its own module so the relay server can use it without the game.
@_exported import SlicksBytes

// MARK: Inputs

extension CarInput {
    /// Pedals in 1/255 steps, steering in 1/127 steps: what fits in three bytes. Online races
    /// quantize every input before simulating, so all machines step with the same values.
    public var quantized: CarInput {
        var w = ByteWriter(capacity: 3)
        write(to: &w)
        var r = ByteReader(w.bytes)
        return (try? CarInput(reading: &r)) ?? .none
    }

    public func write(to w: inout ByteWriter) {
        w.u8(UInt8((clamp(throttle, 0, 1) * 255).rounded()))
        w.u8(UInt8((clamp(brake, 0, 1) * 255).rounded()))
        w.i8(Int8((clamp(steer, -1, 1) * 127).rounded()))
    }

    public init(reading r: inout ByteReader) throws {
        let t = try r.u8(), b = try r.u8(), s = try r.i8()
        // -128 is outside the encoder's range; treat it as full lock rather than rejecting.
        self.init(throttle: Double(t) / 255, brake: Double(b) / 255, steer: Double(max(s, -127)) / 127)
    }
}

// MARK: Snapshots

extension RaceSnapshot {
    /// Binary form for the wire, about 1.2 KB for 8 cars. Car specs don't change during a
    /// race, so they're left out and filled back in from the receiving race.
    public func write(to w: inout ByteWriter) {
        w.u32(UInt32(clamping: tick))
        w.u8(UInt8(phase.rawValue))
        w.f64(time)
        w.optionalF64(firstFinishTime)
        w.optionalF64(allHumansDoneAt)
        w.u8(UInt8(clamping: finishCounter))
        w.u8(UInt8(clamping: cars.count))
        for c in cars {
            w.f64(c.position.x); w.f64(c.position.y)
            w.f64(c.velocity.x); w.f64(c.velocity.y)
            w.f64(c.heading); w.f64(c.angularVelocity)
            w.u16(UInt16(clamping: c.pathIndex))
            w.f64(c.progress)
            w.u8(UInt8(clamping: c.lapsCompleted))
            w.u8(UInt8(clamping: c.lapTimes.count))
            for t in c.lapTimes.prefix(255) { w.f64(t) }
            w.f64(c.lastLapMark)
            w.optionalF64(c.finishTime)
            w.f64(c.slip)
            w.u8((c.isBraking ? 1 : 0) | (c.isWheelspinning ? 2 : 0) | (c.inReverse ? 4 : 0) | (c.isAirborne ? 8 : 0))
            w.f64(c.height); w.f64(c.verticalSpeed); w.f64(c.sandOnTires)
            w.u16(UInt16(clamping: c.jumps))
            w.f64(c.slipstream)
            w.u8(c.surface.rawValue)
            w.u16(UInt16(clamping: c.wallHits))
            // Full precision: AI steering isn't quantized, and clients predict with these.
            w.f64(c.lastInput.throttle); w.f64(c.lastInput.brake); w.f64(c.lastInput.steer)
            w.u8(UInt8(clamping: c.level))
            w.i8(Int8(clamping: c.bridgeZone ?? -1))
        }
        let ids = drivers.keys.sorted()
        w.u8(UInt8(clamping: ids.count))
        for id in ids {
            let d = drivers[id]!
            w.u8(UInt8(clamping: id))
            w.f64(d.skill); w.f64(d.lane)
            w.f64(d.stuckTime); w.f64(d.reverseTime); w.f64(d.reverseSteer); w.f64(d.laneDrift)
        }
        // The sand grid travels separately (see `SandDelta`); only its fingerprint goes here.
        w.bool(sandChecksum != nil)
        if let sandChecksum, let sandRNG {
            w.u64(sandChecksum)
            w.u64(sandRNG)
        }
        // Rubber likewise has its own stream (see `RubberDelta`).
        w.bool(rubberChecksum != nil)
        if let rubberChecksum { w.u64(rubberChecksum) }
    }

    /// Reads a snapshot meant for `race`, rejecting anything that couldn't have come from a
    /// race with the same grid and track (so a bad peer can't crash or corrupt the simulation).
    public init(reading r: inout ByteReader, for race: Race) throws {
        func invalid(_ what: String) -> WireError { .invalid("snapshot \(what)") }
        tick = Int(try r.u32())
        guard let p = Race.Phase(rawValue: Int(try r.u8())) else { throw invalid("phase") }
        phase = p
        time = try r.finite()
        firstFinishTime = try r.optionalFinite()
        allHumansDoneAt = try r.optionalFinite()
        finishCounter = Int(try r.u8())
        let count = Int(try r.u8())
        guard count == race.cars.count else { throw invalid("car count") }
        let samples = race.track.sampleCount
        let bridges = race.track.bridges.count
        var cars: [CarState] = []
        cars.reserveCapacity(count)
        for car in race.cars {
            let position = Vec2(try r.finite(), try r.finite())
            let velocity = Vec2(try r.finite(), try r.finite())
            let heading = try r.finite(), angularVelocity = try r.finite()
            let pathIndex = Int(try r.u16())
            guard pathIndex < samples else { throw invalid("path index") }
            let progress = try r.finite()
            let lapsCompleted = Int(try r.u8())
            let lapCount = Int(try r.u8())
            var lapTimes: [Double] = []
            for _ in 0..<lapCount { lapTimes.append(try r.finite()) }
            let lastLapMark = try r.finite()
            let finishTime = try r.optionalFinite()
            let slip = try r.finite()
            let flags = try r.u8()
            let height = try r.finite(), verticalSpeed = try r.finite()
            let sandOnTires = clamp(try r.finite(), 0, LooseSand.tireCapacity)
            let jumps = Int(try r.u16())
            let slipstream = clamp(try r.finite(), 0, 2)
            guard abs(height) < 10_000, abs(verticalSpeed) < 100_000 else { throw invalid("height") }
            guard let surface = Surface(rawValue: try r.u8()) else { throw invalid("surface") }
            let wallHits = Int(try r.u16())
            let lastInput = CarInput(throttle: clamp(try r.finite(), 0, 1), brake: clamp(try r.finite(), 0, 1),
                                     steer: clamp(try r.finite(), -1, 1))
            let level = Int(try r.u8())
            guard level <= 1 else { throw invalid("level") }
            let zone = Int(try r.i8())
            guard zone >= -1, zone < bridges else { throw invalid("bridge zone") }
            cars.append(CarState(
                spec: car.spec, position: position, velocity: velocity, heading: heading,
                angularVelocity: angularVelocity, pathIndex: pathIndex, progress: progress,
                lapsCompleted: lapsCompleted, lapTimes: lapTimes, lastLapMark: lastLapMark,
                finishTime: finishTime, slip: slip, isBraking: flags & 1 != 0, isWheelspinning: flags & 2 != 0,
                inReverse: flags & 4 != 0, surface: surface, wallHits: wallHits, lastInput: lastInput,
                level: level, bridgeZone: zone < 0 ? nil : zone,
                height: height, verticalSpeed: verticalSpeed, isAirborne: flags & 8 != 0, sandOnTires: sandOnTires, jumps: jumps,
                slipstream: slipstream
            ))
        }
        self.cars = cars
        var drivers: [Int: AIDriver] = [:]
        let driverCount = Int(try r.u8())
        for _ in 0..<driverCount {
            let id = Int(try r.u8())
            guard id < count else { throw invalid("driver") }
            var d = AIDriver(skill: try r.finite(), lane: try r.finite())
            d.stuckTime = try r.finite()
            d.reverseTime = try r.finite()
            d.reverseSteer = try r.finite()
            d.laneDrift = try r.finite()
            drivers[id] = d
        }
        self.drivers = drivers
        if try r.bool() {
            guard race.looseSand != nil else { throw invalid("sand on a track without it") }
            sandChecksum = try r.u64()
            sandRNG = try r.u64()
        } else {
            sandChecksum = nil
            sandRNG = nil
        }
        sand = nil
        if try r.bool() {
            guard race.rubber != nil else { throw invalid("rubber on a race without it") }
            rubberChecksum = try r.u64()
        } else {
            rubberChecksum = nil
        }
        rubber = nil
    }
}

// MARK: Grid deltas

/// Cells as index gaps in varints (neighbouring cells change together, so gaps are small),
/// then the raw float bits: about 5 bytes a cell. `cells` must be in ascending index order.
private func writeCells(_ cells: [(index: Int, value: Float)], to w: inout ByteWriter) {
    w.u32(UInt32(cells.count))
    var previous = -1
    for c in cells {
        var gap = UInt64(c.index - previous - 1)
        previous = c.index
        repeat {
            let byte = UInt8(gap & 0x7F)
            gap >>= 7
            w.u8(gap == 0 ? byte : byte | 0x80)
        } while gap != 0
        w.u32(c.value.bitPattern)
    }
}

/// Reads cells written by `writeCells`, rejecting indices outside the grid and amounts
/// outside 0...1. `what` names the grid in errors.
private func readCells(_ r: inout ByteReader, cellCount: Int, maxCells: Int, what: String) throws -> [(index: Int, value: Float)] {
    let n = Int(try r.u32())
    guard n <= maxCells, n <= cellCount else { throw WireError.invalid("\(what) cell count") }
    var cells: [(index: Int, value: Float)] = []
    cells.reserveCapacity(n)
    var previous = -1
    for _ in 0..<n {
        var gap: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try r.u8()
            gap |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            guard shift < 35 else { throw WireError.invalid("\(what) index") }
        }
        let index = previous + 1 + Int(gap)
        guard index < cellCount else { throw WireError.invalid("\(what) index") }
        let value = Float(bitPattern: try r.u32())
        guard value.isFinite, value >= 0, value <= 1 else { throw WireError.invalid("\(what) amount") }
        cells.append((index, value))
        previous = index
    }
    return cells
}

private func sameCells(_ a: [(index: Int, value: Float)], _ b: [(index: Int, value: Float)]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { $0.index == $1.index && $0.value.bitPattern == $1.value.bitPattern }
}

// MARK: Loose sand

/// Loose sand cells that changed on the host since its last delta, with the sand's RNG.
/// Deltas go reliably and in order, so a player applying them all has the host's grid.
public struct SandDelta: Equatable, Sendable {
    public var tick: Int
    public var rngState: UInt64
    /// Ascending cell indices with their new amounts (exact, so machines stay bit-identical).
    public var cells: [(index: Int, value: Float)]

    public init(tick: Int, rngState: UInt64, cells: [(index: Int, value: Float)]) {
        self.tick = tick
        self.rngState = rngState
        self.cells = cells.sorted { $0.index < $1.index }
    }

    public static func == (a: SandDelta, b: SandDelta) -> Bool {
        a.tick == b.tick && a.rngState == b.rngState && sameCells(a.cells, b.cells)
    }

    /// Most cells in one message; a bigger change is split (about 700 KB each at worst).
    public static let maxCells = 120_000

    public func write(to w: inout ByteWriter) {
        w.u32(UInt32(clamping: tick))
        w.u64(rngState)
        writeCells(cells, to: &w)
    }

    /// - Parameter cellCount: cells in the receiving race's grid; anything outside is rejected.
    public init(reading r: inout ByteReader, cellCount: Int) throws {
        tick = Int(try r.u32())
        rngState = try r.u64()
        cells = try readCells(&r, cellCount: cellCount, maxCells: Self.maxCells, what: "sand")
    }
}

// MARK: Rubber

/// Rubber cells that changed on the host since its last delta. Like sand deltas they go
/// reliably and in order, so a player applying them all has the host's rubber.
public struct RubberDelta: Equatable, Sendable {
    public var tick: Int
    /// Ascending cell indices with their new amounts (exact, so machines stay bit-identical).
    public var cells: [(index: Int, value: Float)]

    public init(tick: Int, cells: [(index: Int, value: Float)]) {
        self.tick = tick
        self.cells = cells.sorted { $0.index < $1.index }
    }

    public static func == (a: RubberDelta, b: RubberDelta) -> Bool {
        a.tick == b.tick && sameCells(a.cells, b.cells)
    }

    /// Most cells in one message; a bigger change is split.
    public static let maxCells = 120_000

    public func write(to w: inout ByteWriter) {
        w.u32(UInt32(clamping: tick))
        writeCells(cells, to: &w)
    }

    /// - Parameter cellCount: cells in the receiving race's rubber grid.
    public init(reading r: inout ByteReader, cellCount: Int) throws {
        tick = Int(try r.u32())
        cells = try readCells(&r, cellCount: cellCount, maxCells: Self.maxCells, what: "rubber")
    }
}
