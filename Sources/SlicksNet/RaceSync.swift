import Foundation
import SlicksCore

/// Drives a race for the race screen. Local races just step; online, the host steps the
/// authoritative race and clients predict it (see `ClientRaceController`).
public protocol RaceController: AnyObject {
    var race: Race { get }
    /// `localSlots[p]` is the input slot local player p drives.
    var localSlots: [Int] { get }
    /// Inputs by slot used for the newest tick, e.g. so players can rev on the grid.
    var slotInputs: [CarInput] { get }
    /// The results are final and can be shown.
    var isFinished: Bool { get }
    /// Advances by one rendered frame and returns collisions from newly simulated ticks.
    /// - Parameter localInputs: one per local player, in keyboard/controller order.
    func advance(frameDt: Double, localInputs: [CarInput]) -> [ImpactEvent]
    /// Added to a car's drawn position and heading, easing out corrections from the host.
    func displayOffset(carID: Int) -> (position: Vec2, heading: Double)
}

extension RaceController {
    public func displayOffset(carID: Int) -> (position: Vec2, heading: Double) { (.zero, 0) }

    /// Car driven by an input slot.
    func car(forSlot slot: Int) -> Car? {
        race.cars.first { $0.playerIndex == slot }
    }
}

/// Spreads local players' inputs into a slot-indexed array.
func slotArray(count: Int, localSlots: [Int], localInputs: [CarInput]) -> [CarInput] {
    var out = [CarInput](repeating: .none, count: count)
    for (p, slot) in localSlots.enumerated() where p < localInputs.count && out.indices.contains(slot) {
        out[slot] = localInputs[p]
    }
    return out
}

extension Race {
    /// Length of `step(humanInputs:)` covering every human's slot.
    var inputSlotCount: Int { (cars.compactMap(\.playerIndex).max() ?? -1) + 1 }
}

// MARK: Local

/// Everyone is at this machine.
public final class LocalRaceController: RaceController {
    public let race: Race
    public let localSlots: [Int]
    public private(set) var slotInputs: [CarInput] = []
    private var accumulator = 0.0

    public init(race: Race, localSlots: [Int]) {
        self.race = race
        self.localSlots = localSlots
    }

    public var isFinished: Bool { race.phase == .finished }

    public func advance(frameDt: Double, localInputs: [CarInput]) -> [ImpactEvent] {
        slotInputs = slotArray(count: race.inputSlotCount, localSlots: localSlots, localInputs: localInputs)
        guard !isFinished else { return [] }
        accumulator += frameDt
        while accumulator >= Race.tickDuration {
            race.step(dt: Race.tickDuration, humanInputs: slotInputs)
            accumulator -= Race.tickDuration
        }
        return race.drainImpacts()
    }
}

// MARK: Host

/// Runs the real race: local players plus each client's newest input, with the state sent
/// to clients 30 times a second. Players who drop out are handed to the AI.
public final class HostRaceController: RaceController {
    public let race: Race
    public let localSlots: [Int]
    public let host: NetHost
    public private(set) var slotInputs: [CarInput] = []

    /// Ticks between snapshots: 120 Hz / 4 = 30 per second.
    public static let snapshotInterval = 4
    /// Once the race is over, keep re-sending the final state this often.
    static let finishedResend = 0.25

    private let remoteSlots: [Int]
    private var accumulator = 0.0
    private var ticksSinceSnapshot = 0
    private var sinceFinishedSend = Double.infinity

    public init(race: Race, host: NetHost, localSlots: [Int]) {
        self.race = race
        self.host = host
        self.localSlots = localSlots
        remoteSlots = race.cars.compactMap(\.playerIndex).filter { !localSlots.contains($0) }
    }

    public var isFinished: Bool { race.phase == .finished }

    public func advance(frameDt: Double, localInputs: [CarInput]) -> [ImpactEvent] {
        var inputs = slotArray(count: race.inputSlotCount, localSlots: localSlots, localInputs: localInputs.map(\.quantized))
        for client in host.clients {
            for (i, slot) in client.slots.enumerated() where i < client.inputs.count && inputs.indices.contains(slot) {
                inputs[slot] = client.inputs[i]
            }
        }
        slotInputs = inputs

        // Anyone whose slots no longer belong to a connected client has left.
        let connected = Set(host.clients.flatMap(\.slots))
        for slot in remoteSlots where !connected.contains(slot) {
            if let car = car(forSlot: slot), !race.isComputerDriven(car) { race.handOverToAI(carID: car.id) }
        }

        accumulator += frameDt
        while accumulator >= Race.tickDuration {
            accumulator -= Race.tickDuration
            let wasFinished = isFinished
            race.step(dt: Race.tickDuration, humanInputs: inputs)
            ticksSinceSnapshot += 1
            if ticksSinceSnapshot >= Self.snapshotInterval || (isFinished && !wasFinished) {
                sendSnapshot()
            }
        }
        if isFinished {
            sinceFinishedSend += frameDt
            if sinceFinishedSend >= Self.finishedResend { sendSnapshot() }
        }
        return race.drainImpacts()
    }

    private func sendSnapshot() {
        var w = ByteWriter(capacity: 1600)
        race.snapshot().write(to: &w)
        host.sendSnapshot(w.bytes)
        ticksSinceSnapshot = 0
        sinceFinishedSend = 0
    }
}

// MARK: Client

/// Shows the race as it will be once the host has this machine's inputs: every snapshot from
/// the host is restored, then the local inputs the host hasn't seen yet are replayed on top.
/// Other humans are assumed to hold their last known input. Visible jumps from corrections
/// are eased out over a few frames.
public final class ClientRaceController: RaceController {
    public let race: Race
    public let localSlots: [Int]
    public let raceID: UInt32
    public private(set) var slotInputs: [CarInput] = []
    /// Phase according to the host. Results show only once the host says it's over.
    public private(set) var authoritativePhase: Race.Phase = .countdown
    /// Set if the host sent state that doesn't fit this race.
    public private(set) var error: String?
    /// Largest jump (in track pixels) a correction caused on a local player's car, for tuning.
    public private(set) var lastOwnCorrection = 0.0
    public private(set) var snapshotsApplied = 0

    /// Replay at most this many ticks (0.75 s). Beyond that the connection is too slow to hide.
    static let maxReplay: UInt32 = 90
    /// How quickly drawn cars catch up with corrected positions (1/s).
    static let smoothingRate = 12.0
    /// Corrections bigger than this snap instead of gliding.
    static let snapDistance = 80.0

    private let send: (UInt32, [CarInput]) -> Void
    private var seq: UInt32 = 0
    private var history: [UInt32: [CarInput]] = [:]
    private var pending: (ack: UInt32, state: [UInt8])?
    private var remoteInputs: [Int: CarInput] = [:]
    private var offsets: [(position: Vec2, heading: Double)]
    private var accumulator = 0.0

    /// - Parameter send: delivers this machine's newest inputs to the host.
    public init(race: Race, raceID: UInt32, localSlots: [Int], send: @escaping (_ seq: UInt32, _ inputs: [CarInput]) -> Void) {
        self.race = race
        self.raceID = raceID
        self.localSlots = localSlots
        self.send = send
        offsets = Array(repeating: (.zero, 0), count: race.cars.count)
    }

    public convenience init(race: Race, raceID: UInt32, localSlots: [Int], client: NetClient) {
        self.init(race: race, raceID: raceID, localSlots: localSlots) { [weak client] seq, inputs in
            client?.sendInput(seq: seq, inputs: inputs)
        }
    }

    public var isFinished: Bool { authoritativePhase == .finished }

    /// Queues state from the host. Only the newest one matters; it's applied on the next frame.
    public func receive(ack: UInt32, state: [UInt8]) {
        pending = (ack, state)
    }

    public func advance(frameDt: Double, localInputs: [CarInput]) -> [ImpactEvent] {
        let local = localSlots.indices.map { $0 < localInputs.count ? localInputs[$0].quantized : .none }
        if let p = pending {
            pending = nil
            reconcile(ack: p.ack, state: p.state)
        }
        decayOffsets(frameDt)
        guard !isFinished, error == nil else { return [] }

        var impacts: [ImpactEvent] = []
        accumulator += frameDt
        while accumulator >= Race.tickDuration {
            accumulator -= Race.tickDuration
            seq &+= 1
            history[seq] = local
            slotInputs = inputs(local: local)
            race.step(dt: Race.tickDuration, humanInputs: slotInputs)
            impacts += race.drainImpacts()
        }
        if seq > 0 { send(seq, local) }
        return impacts
    }

    public func displayOffset(carID: Int) -> (position: Vec2, heading: Double) {
        offsets.indices.contains(carID) ? offsets[carID] : (.zero, 0)
    }

    private func inputs(local: [CarInput]) -> [CarInput] {
        var out = slotArray(count: race.inputSlotCount, localSlots: localSlots, localInputs: local)
        for (slot, input) in remoteInputs where out.indices.contains(slot) && !localSlots.contains(slot) {
            out[slot] = input
        }
        return out
    }

    private func reconcile(ack: UInt32, state: [UInt8]) {
        var reader = ByteReader(state)
        let snapshot: RaceSnapshot
        do {
            snapshot = try RaceSnapshot(reading: &reader, for: race)
        } catch {
            self.error = "the host sent race state this game can't use (\(error))"
            return
        }
        let drawn = race.cars.map { ($0.position + offsets[$0.id].position, $0.heading + offsets[$0.id].heading) }

        race.restore(snapshot)
        authoritativePhase = snapshot.phase
        snapshotsApplied += 1
        for car in race.cars {
            if let slot = car.playerIndex, !localSlots.contains(slot) { remoteInputs[slot] = car.lastInput }
        }
        history = history.filter { $0.key > ack }

        if snapshot.phase != .finished, seq > ack {
            let first = max(ack &+ 1, seq > Self.maxReplay ? seq - Self.maxReplay + 1 : 1)
            var last = history[first] ?? []
            for s in first...seq {
                if let h = history[s] { last = h }
                race.step(dt: Race.tickDuration, humanInputs: inputs(local: last))
            }
            // These collisions were already shown (or never happened); don't spark twice.
            _ = race.drainImpacts()
        }

        lastOwnCorrection = 0
        for car in race.cars {
            let (p, h) = drawn[car.id]
            var offset = (position: p - car.position, heading: wrapAngle(h - car.heading))
            if offset.position.length > Self.snapDistance { offset = (.zero, 0) }
            offsets[car.id] = offset
            if let slot = car.playerIndex, localSlots.contains(slot) {
                lastOwnCorrection = max(lastOwnCorrection, offset.position.length)
            }
        }
    }

    private func decayOffsets(_ dt: Double) {
        let k = exp(-Self.smoothingRate * dt)
        for i in offsets.indices {
            offsets[i].position *= k
            offsets[i].heading *= k
        }
    }
}
