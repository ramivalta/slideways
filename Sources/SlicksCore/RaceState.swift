import Foundation

/// Everything needed to start the same race on every machine. For online play the host picks
/// it and sends it to the others: the full track travels along, since custom tracks and the
/// order of the track list differ between machines.
public struct RaceSetup: Codable, Sendable, Equatable {
    public var track: TrackDefinition
    public var entrants: [Entrant]
    public var laps: Int
    public var seed: UInt64

    public init(track: TrackDefinition, entrants: [Entrant], laps: Int, seed: UInt64) {
        self.track = track
        self.entrants = entrants
        self.laps = laps
        self.seed = seed
    }

    /// Length `Race.step(humanInputs:)` needs so every human's slot has an entry.
    public var inputSlotCount: Int {
        (entrants.compactMap(\.playerIndex).max() ?? -1) + 1
    }

    public static func randomSeed() -> UInt64 {
        UInt64.random(in: 1...UInt64.max)
    }
}

/// The parts of a car that change during a race. Identity and livery stay on `Car`.
public struct CarState: Codable, Sendable, Equatable {
    public var spec: CarSpec
    public var position: Vec2
    public var velocity: Vec2
    public var heading: Double
    public var angularVelocity: Double
    public var pathIndex: Int
    public var progress: Double
    public var lapsCompleted: Int
    public var lapTimes: [Double]
    public var lastLapMark: Double
    public var finishTime: Double?
    public var slip: Double
    public var isBraking: Bool
    public var isWheelspinning: Bool
    public var inReverse: Bool
    public var surface: Surface
    public var wallHits: Int
    public var lastInput: CarInput
    public var level: Int
    public var bridgeZone: Int?
    // Jumps and loose sand.
    public var height: Double
    public var verticalSpeed: Double
    public var isAirborne: Bool
    public var sandOnTires: Double
    public var jumps: Int
    /// Drafting behind other cars (smoothed over time, so it's state, not derivable).
    public var slipstream: Double
}

/// A complete copy of a race's changing state at one tick. Restoring it into a race built
/// from the same setup continues exactly as the original would have (on the same CPU
/// architecture: floating-point results differ between arm64 and x86_64).
public struct RaceSnapshot: Codable, Sendable, Equatable {
    public var tick: Int
    public var phase: Race.Phase
    public var time: Double
    public var cars: [CarState]
    var drivers: [Int: AIDriver]
    var firstFinishTime: Double?
    var allHumansDoneAt: Double?
    var finishCounter: Int
    /// Fingerprint of the loose sand (checksum and RNG), when the track has it. Always
    /// present, even when the sand itself isn't, so hashes cover it cheaply.
    public var sandChecksum: UInt64?
    public var sandRNG: UInt64?
    /// The loose sand itself. Left out of snapshots sent over the network (the sand has its
    /// own change stream) and when only a hash is wanted; `restore` then keeps the race's sand.
    public var sand: LooseSand.State?

    /// 64-bit FNV-1a over the exact bit patterns of the state. Peers compare these per tick to
    /// catch desyncs; it doesn't depend on dictionary order or the Swift hash seed.
    public var stateHash: UInt64 {
        var h = StateHasher()
        h.add(tick)
        h.add(Int(phase.rawValue))
        h.add(time)
        h.add(firstFinishTime)
        h.add(allHumansDoneAt)
        h.add(finishCounter)
        for c in cars {
            h.add(c.position.x); h.add(c.position.y)
            h.add(c.velocity.x); h.add(c.velocity.y)
            h.add(c.heading); h.add(c.angularVelocity)
            h.add(c.pathIndex); h.add(c.progress)
            h.add(c.lapsCompleted); h.add(c.lapTimes.count)
            for t in c.lapTimes { h.add(t) }
            h.add(c.lastLapMark); h.add(c.finishTime)
            h.add(c.slip); h.add(c.isBraking); h.add(c.isWheelspinning); h.add(c.inReverse)
            h.add(Int(c.surface.rawValue)); h.add(c.wallHits)
            h.add(c.lastInput.throttle); h.add(c.lastInput.brake); h.add(c.lastInput.steer)
            h.add(c.level); h.add(c.bridgeZone ?? -1)
            h.add(c.height); h.add(c.verticalSpeed); h.add(c.isAirborne); h.add(c.sandOnTires); h.add(c.jumps)
            h.add(c.slipstream)
        }
        h.add(sandChecksum ?? 0)
        h.add(sandRNG ?? 0)
        for id in drivers.keys.sorted() {
            let d = drivers[id]!
            h.add(id)
            h.add(d.skill); h.add(d.lane)
            h.add(d.stuckTime); h.add(d.reverseTime); h.add(d.reverseSteer); h.add(d.laneDrift)
            h.add(d.routeBest); h.add(d.routeStall)
        }
        return h.value
    }
}

struct StateHasher {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func add(_ bits: UInt64) {
        // Byte-wise FNV-1a, little-endian regardless of platform.
        for shift in stride(from: 0, to: 64, by: 8) {
            value = (value ^ ((bits >> UInt64(shift)) & 0xFF)) &* 0x0000_0100_0000_01B3
        }
    }

    mutating func add(_ d: Double) { add(d.bitPattern) }
    mutating func add(_ i: Int) { add(UInt64(bitPattern: Int64(i))) }
    mutating func add(_ b: Bool) { add(b ? 1 as UInt64 : 0) }
    mutating func add(_ d: Double?) {
        add(d != nil)
        if let d { add(d) }
    }
}
