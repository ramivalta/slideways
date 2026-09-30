import Foundation

public struct Entrant: Sendable {
    public var name: String
    public var colorIndex: Int
    /// Local player slot (0-3) for humans, nil for computer drivers.
    public var playerIndex: Int?
    public var spec: CarSpec
    public var aiSkill: Double

    public init(name: String, colorIndex: Int, playerIndex: Int?, spec: CarSpec = CarSpec(), aiSkill: Double = 0.8) {
        self.name = name
        self.colorIndex = colorIndex
        self.playerIndex = playerIndex
        self.spec = spec
        self.aiSkill = aiSkill
    }
}

/// One race on one track. Runs on a fixed timestep; the view layer only reads from it.
public final class Race {
    public enum Phase: Equatable, Sendable {
        case countdown
        case racing
        case finished
    }

    public static let countdownDuration = 3.0
    /// After the leader finishes, the rest have this long before the race is called.
    public static let finishGrace = 25.0

    public let track: Track
    public let laps: Int
    public private(set) var cars: [Car]
    public private(set) var phase: Phase = .countdown
    /// Seconds since the green light. Negative during the countdown.
    public private(set) var time: Double = -Race.countdownDuration
    public private(set) var impacts: [ImpactEvent] = []
    /// Sand kicked out of the traps this race, if the track has sand and allows it to spread.
    public let looseSand: LooseSand?

    private var drivers: [Int: AIDriver] = [:]
    private var firstFinishTime: Double?
    private var allHumansDoneAt: Double?
    private var finishCounter = 0

    public init(track: Track, entrants: [Entrant], laps: Int, seed: UInt64 = 1) {
        self.track = track
        self.laps = max(1, laps)
        looseSand = track.definition.looseSand && track.surfaces.contains(.sand) ? LooseSand(track: track, seed: seed) : nil
        var rng = SplitMix64(seed: seed)
        let slots = track.gridSlots(count: entrants.count)
        let n = Double(track.sampleCount)
        cars = entrants.enumerated().map { i, e in
            let slot = slots[i]
            let behind = Double(track.indexDelta(from: 0, to: slot.index))
            return Car(
                id: i, name: e.name, colorIndex: e.colorIndex, isAI: e.playerIndex == nil,
                playerIndex: e.playerIndex, spec: e.spec,
                position: slot.position, heading: slot.heading,
                pathIndex: slot.index, progress: behind < 0 ? behind : behind - n
            )
        }
        for car in cars where car.isAI {
            let e = entrants[car.id]
            let lane = Double.random(in: -0.45...0.45, using: &rng)
            drivers[car.id] = AIDriver(skill: e.aiSkill, lane: lane)
        }
    }

    public var hasHumans: Bool { cars.contains { !$0.isAI } }

    /// Takes and clears the impact events produced since the last call.
    public func drainImpacts() -> [ImpactEvent] {
        defer { impacts.removeAll(keepingCapacity: true) }
        return impacts
    }

    /// Advances the simulation by one fixed step.
    /// - Parameter humanInputs: indexed by local player slot.
    public func step(dt: Double, humanInputs: [CarInput]) {
        guard phase != .finished else { return }
        time += dt
        if phase == .countdown && time >= 0 {
            phase = .racing
        }

        for car in cars {
            var input = CarInput.none
            if phase != .countdown {
                if var driver = drivers[car.id] {
                    input = driver.input(for: car, track: track, sand: looseSand, dt: dt, elapsed: time)
                    drivers[car.id] = driver
                } else if let p = car.playerIndex, p < humanInputs.count {
                    input = humanInputs[p]
                }
            }
            let before = car.position
            car.integrate(input: input, track: track, sand: looseSand, dt: dt)
            Jumps.update(car, from: before, track: track, dt: dt, events: &impacts)
            updateLevel(car)
            looseSand?.interact(with: car, dt: dt)
        }

        for i in 0..<cars.count {
            for j in (i + 1)..<cars.count {
                let a = cars[i], b = cars[j]
                // Cars on the deck and cars underneath pass through each other.
                if a.level != b.level, a.bridgeZone != nil || b.bridgeZone != nil { continue }
                // So do cars jumping over each other.
                if a.isAboveObstacles || b.isAboveObstacles, abs(a.height - b.height) > Jumps.clearance { continue }
                Collisions.resolve(a, b, events: &impacts)
            }
        }
        for car in cars {
            Collisions.resolveWalls(car, track: track, events: &impacts)
        }

        if phase == .racing {
            for car in cars { updateProgress(car) }
            checkRaceEnd()
        }
    }

    /// Assigns deck/ground level when a car enters a bridge zone: through an end means up on
    /// the deck, through a side means underneath. Leaving the zone puts it back on the ground.
    private func updateLevel(_ car: Car) {
        let zone = track.bridgeZone(containing: car.position)
        guard zone != car.bridgeZone else { return }
        car.bridgeZone = zone
        guard let zone else {
            car.level = 0
            return
        }
        let b = track.bridges[zone]
        guard let l = track.bridgeLocal(at: car.position) else { return }
        let endGap = min(l.along - (b.deckStart - b.zoneExtension), b.deckEnd + b.zoneExtension - l.along)
        let sideGap = b.halfWidth - l.lateral
        car.level = endGap < sideGap ? 1 : 0
    }

    private func updateProgress(_ car: Car) {
        let newIndex = track.nearestSample(to: car.position, near: car.pathIndex)
        let delta = track.indexDelta(from: car.pathIndex, to: newIndex)
        car.pathIndex = newIndex
        car.progress += Double(delta)

        guard !car.isFinished else { return }
        let completed = Int(floor(car.progress / Double(track.sampleCount)))
        if completed > car.lapsCompleted {
            car.lapsCompleted = completed
            car.lapTimes.append(time - car.lastLapMark)
            car.lastLapMark = time
            if completed >= laps {
                car.finishTime = time
                finishCounter += 1
                if firstFinishTime == nil { firstFinishTime = time }
            }
        }
    }

    private func checkRaceEnd() {
        if cars.allSatisfy(\.isFinished) {
            phase = .finished
            return
        }
        if hasHumans, cars.filter({ !$0.isAI }).allSatisfy(\.isFinished) {
            // Give the view a moment to show the last human crossing the line.
            if allHumansDoneAt == nil { allHumansDoneAt = time }
            if let t = allHumansDoneAt, time - t > 2 {
                phase = .finished
            }
        }
        if let first = firstFinishTime, time - first > Race.finishGrace {
            phase = .finished
        }
    }

    /// Cars ordered by race position: finishers by time, then by distance covered.
    public var standings: [Car] {
        cars.sorted { a, b in
            switch (a.finishTime, b.finishTime) {
            case let (ta?, tb?): return ta < tb
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.progress > b.progress
            }
        }
    }

    /// Current lap the car is on (1-based), capped at the race length.
    public func currentLap(of car: Car) -> Int {
        min(laps, car.lapsCompleted + 1)
    }
}
