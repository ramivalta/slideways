import Foundation
import SlicksCore
import SlicksGame

/// Scripted weaving so human cars brake, slide and hit things instead of idling.
private func scriptedInputs(tick: Int, slots: Int) -> [CarInput] {
    (0..<slots).map { s in
        let phase = (tick + s * 97) % 300
        return CarInput(throttle: phase < 250 ? 1 : 0, brake: phase >= 270 ? 1 : 0, steer: phase < 150 ? 0.5 : -0.5)
    }
}

/// 1-based position of the first tick where two hash runs differ.
private func firstDivergence(_ a: [UInt64], _ b: [UInt64]) -> Int {
    (Array(zip(a, b)).firstIndex { $0 != $1 } ?? min(a.count, b.count)) + 1
}

/// Steps until the race ends (or `limit` ticks), returning the state hash after every tick.
private func run(_ race: Race, setup: RaceSetup, limit: Int) -> [UInt64] {
    var hashes: [UInt64] = []
    while race.phase != .finished && hashes.count < limit {
        race.step(dt: Race.tickDuration, humanInputs: scriptedInputs(tick: race.tick, slots: setup.inputSlotCount))
        _ = race.drainImpacts()
        hashes.append(race.stateHash)
    }
    return hashes
}

/// What online play relies on: setups and snapshots survive the wire, identical setups
/// replay identically, and restoring a snapshot continues exactly where it left off.
func netChecks() -> Int {
    var problems = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { print("  FAIL: \(what)"); problems += 1 }
    }
    print("== Online foundations")

    var settings = RaceSettings()
    settings.humanPlayers = 2
    settings.aiOpponents = 6
    settings.laps = 2
    let def = BuiltInTracks.all.first { $0.id == "twin-bridges" }!
    let setup = settings.raceSetup(track: def, seed: 0xC0FFEE)
    check(setup.inputSlotCount == 2, "two humans need two input slots (got \(setup.inputSlotCount))")

    // The setup the host sends must decode to the same race.
    let wire = try! JSONEncoder().encode(setup)
    let received = try! JSONDecoder().decode(RaceSetup.self, from: wire)
    check(received == setup, "race setup changes when encoded and decoded")
    let track = Track(definition: received.track)

    // Two machines with the same setup and inputs stay in lockstep.
    let a = run(Race(setup: setup, track: track), setup: setup, limit: 60 * Race.tickRate)
    let b = run(Race(setup: received, track: Track(definition: received.track)), setup: received, limit: 60 * Race.tickRate)
    check(a == b, "identical races diverge at tick \(firstDivergence(a, b))")

    var other = setup
    other.seed = 0xBEEF
    other.entrants = settings.entrants(seed: other.seed)
    let c = run(Race(setup: other, track: track), setup: other, limit: 10 * Race.tickRate)
    check(c.last != a[c.count - 1], "different seeds hash the same")

    // Snapshot mid-race, play on to the end, then rewind and replay: every tick must match.
    // The replay runs both in the same race and in a fresh one fed the snapshot over the wire.
    let race = Race(setup: setup, track: track)
    _ = run(race, setup: setup, limit: 900)
    let snap = race.snapshot()
    check(snap.tick == 900 && race.tick == 900, "tick counter (\(race.tick)) doesn't match steps taken")
    check(snap.phase == .racing, "snapshot should be taken while racing")
    let original = run(race, setup: setup, limit: .max)
    check(race.phase == .finished, "scripted race never finished")

    race.restore(snap)
    check(race.stateHash == snap.stateHash, "restore doesn't reproduce the snapshot")
    let rewound = run(race, setup: setup, limit: .max)
    check(rewound == original, "replay after restore diverges at tick \(900 + firstDivergence(original, rewound))")

    let decoded = try! JSONDecoder().decode(RaceSnapshot.self, from: JSONEncoder().encode(snap))
    check(decoded == snap, "snapshot changes when encoded and decoded")
    let fresh = Race(setup: setup, track: track)
    fresh.restore(decoded)
    let resumed = run(fresh, setup: setup, limit: .max)
    check(resumed == original, "fresh race resumed from a snapshot diverges")

    let finishers = race.cars.filter(\.isFinished).count
    print("  \(a.count) ticks in lockstep, replayed \(original.count) ticks from tick 900, \(finishers)/\(race.cars.count) finished, snapshot \(try! JSONEncoder().encode(snap).count) bytes JSON")
    if problems == 0 { print("  online foundations OK") }
    return problems
}

/// `SlicksSim --hash`: AI races on every built-in track, printing state hashes. Run it on two
/// machines (or `arch -x86_64` on Apple Silicon) and diff the output to check determinism.
func printDeterminismHashes() {
    for def in BuiltInTracks.all {
        let track = Track(definition: def)
        var geometry: UInt64 = 0xcbf2_9ce4_8422_2325
        for p in track.path {
            for bits in [p.x.bitPattern, p.y.bitPattern] { geometry = (geometry ^ bits) &* 0x0000_0100_0000_01B3 }
        }
        var s = RaceSettings()
        s.humanPlayers = 0
        s.aiOpponents = 8
        s.laps = 2
        let setup = s.raceSetup(track: def, seed: 99)
        let race = Race(setup: setup, track: track)
        var marks: [String] = []
        while race.phase != .finished && race.time < 300 {
            race.step(dt: Race.tickDuration, humanInputs: [])
            _ = race.drainImpacts()
            if race.tick % 400 == 0 { marks.append("\(race.tick):\(String(race.stateHash, radix: 16).prefix(8))") }
        }
        print(def.id, "geometry", String(geometry, radix: 16), "final", race.tick, String(race.stateHash, radix: 16))
        print("   ", marks.prefix(8).joined(separator: " "))
    }
}
