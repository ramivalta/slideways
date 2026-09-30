import Foundation
import SlicksCore

/// Rubber build-up: tires lay rubber on the road (much more when marking it), only on road
/// surfaces, deterministically, and rubbered road grips harder in proportion to the rubber.
func rubberCheck() -> Int {
    var problems = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { print("  FAIL: \(what)"); problems += 1 }
    }
    let dt = 1.0 / 120.0
    let pts = (0..<12).map { k -> Vec2 in
        let a = Double(k) / 12 * 2 * .pi - .pi / 2
        return Vec2(480 + 300 * cos(a), 300 + 200 * sin(a))
    }
    let pad = Track(definition: TrackDefinition(id: "rubberpad", name: "Rubberpad", roadWidth: 380, controlPoints: pts,
                                                background: .asphalt, looseSand: false))
    let lawn = Track(definition: TrackDefinition(id: "lawn", name: "Lawn", roadWidth: 380, controlPoints: pts, background: .asphalt,
                                                 patches: [Patch(.grass, .rect(origin: .zero, size: Vec2(960, 600)), coversRoad: true)],
                                                 looseSand: false))

    func startedRace(on track: Track, rubber: Bool = true) -> Race {
        let race = Race(track: track, entrants: [Entrant(name: "P1", colorIndex: 0, playerIndex: 0)], laps: 99, seed: 7,
                        rubberBuildsUp: rubber)
        while race.phase == .countdown { race.step(dt: dt, humanInputs: []) }
        return race
    }
    func total(_ r: Rubber?) -> Double { r?.amount.reduce(0) { $0 + Double($1) } ?? 0 }

    /// Drives `seconds` from a set start, returning the race and the distance covered.
    func drive(on track: Track, from p: Vec2, velocity v: Vec2, seconds: Double, input: CarInput) -> (Race, Double) {
        let race = startedRace(on: track)
        let car = race.cars[0]
        car.position = p
        car.heading = v.angle
        car.velocity = v
        car.angularVelocity = 0
        var t = 0.0, dist = 0.0
        while t < seconds {
            race.step(dt: dt, humanInputs: [input])
            dist += car.speed * dt
            t += dt
        }
        return (race, dist)
    }

    print("== Rubber")
    // Cruising straight (no wheelspin) versus braking hard over the same kind of road.
    let (cruise, cruiseDist) = drive(on: pad, from: Vec2(120, 300), velocity: Vec2(200, 0), seconds: 3,
                                     input: CarInput(throttle: 0.6, brake: 0, steer: 0))
    let (braking, brakeDist) = drive(on: pad, from: Vec2(120, 300), velocity: Vec2(300, 0), seconds: 0.55,
                                     input: CarInput(throttle: 0, brake: 1, steer: 0))
    let rolling = total(cruise.rubber) / cruiseDist, locked = total(braking.rubber) / brakeDist
    print(String(format: "  rubber per 100 px: rolling %.3f, braking hard %.3f (%.1fx)", rolling * 100, locked * 100, locked / max(rolling, 1e-9)))
    check(rolling > 0, "rolling tires lay some rubber")
    check(locked > rolling * 4, "marking tires lay much more rubber than rolling ones")

    // Donuts: full lock and full throttle for a while.
    let donut = CarInput(throttle: 1, brake: 0, steer: 1)
    let (donuts, _) = drive(on: pad, from: Vec2(480, 300), velocity: Vec2(150, 0), seconds: 20, input: donut)
    let (grassDonuts, _) = drive(on: lawn, from: Vec2(480, 300), velocity: Vec2(150, 0), seconds: 20, input: donut)
    guard let rubber = donuts.rubber else {
        check(false, "races lay rubber by default")
        return problems
    }
    let totals = rubber.totals()
    print(String(format: "  20s of donuts: peak %.2f, mean %.2f where touched, %d cells over 0.25", totals.peak, totals.mean, totals.cellsAbove))
    check(totals.peak > 0.4 && totals.peak <= 1, "donuts rubber in the road, within bounds")
    check(total(grassDonuts.rubber) == 0, "grass takes no rubber")
    check(startedRace(on: pad, rubber: false).rubber == nil, "rubber can be turned off")
    let (again, _) = drive(on: pad, from: Vec2(480, 300), velocity: Vec2(150, 0), seconds: 20, input: donut)
    check(again.rubber?.amount == rubber.amount, "rubber is deterministic")

    // Grip: the same sideways slide, on the most rubbered spot and on clean asphalt.
    let best = rubber.amount.indices.max { rubber.amount[$0] < rubber.amount[$1] }!
    let s = Double(Rubber.cellSize)
    let spot = Vec2((Double(best % rubber.columns) + 0.5) * s, (Double(best / rubber.columns) + 0.5) * s)
    let level = rubber.level(at: spot)
    func lateralGripLoss(_ race: Race) -> Double {
        let car = race.cars[0]
        car.position = spot
        car.heading = 0
        car.angularVelocity = 0
        car.velocity = Vec2(150, 60)
        race.step(dt: dt, humanInputs: [.none])
        return 60 - car.velocity.dot(car.left)
    }
    let rubbered = lateralGripLoss(donuts), clean = lateralGripLoss(startedRace(on: pad, rubber: false))
    let ratio = rubbered / clean, expected = 1 + Rubber.gripGain * level
    print(String(format: "  sideways grip at %.2f rubber: %.3fx clean asphalt (expected %.3fx)", level, ratio, expected))
    check(abs(ratio - expected) < 0.01, "grip scales with rubber")
    check(ratio > 1.03, "rubbered road grips noticeably harder")
    let props = Ground.at(Vec2(480, 300), level: 1, track: pad, sand: nil, rubber: rubber).properties
    check(props.grip == Surface.asphalt.properties.grip, "bridge decks ignore ground rubber")
    return problems
}
