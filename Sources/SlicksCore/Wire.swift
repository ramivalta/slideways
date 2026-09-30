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
            w.u8((c.isBraking ? 1 : 0) | (c.isWheelspinning ? 2 : 0) | (c.inReverse ? 4 : 0))
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
                level: level, bridgeZone: zone < 0 ? nil : zone
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
    }
}
