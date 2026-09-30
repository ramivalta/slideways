import Foundation
import SlicksCore

/// Drafting: flat out down a long straight, a car tucked in behind another should pull harder
/// than one in clean air, more so behind a line of cars, and not at all when alongside.
func slipstreamCheck() -> Int {
    var problems = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { print("  FAIL: \(what)"); problems += 1 }
    }
    // A long stadium: two straights joined by tight ends.
    let straight = stride(from: 100.0, through: 2100, by: 250)
    let pts = straight.map { Vec2($0, 150) } + [Vec2(2150, 300)] + straight.reversed().map { Vec2($0, 450) } + [Vec2(50, 300)]
    let def = TrackDefinition(id: "dragstrip", name: "Dragstrip", width: 2200, height: 600, roadWidth: 200,
                              controlPoints: pts, background: .asphalt, looseSand: false)
    let track = Track(definition: def)

    /// Lines cars up at the given offsets (along, across) from the last car, all rolling at the
    /// same speed, then runs them flat out. Returns the last car's speed and draft at the end.
    func run(_ offsets: [Vec2], seconds: Double = 1.5) -> (speed: Double, draft: Double) {
        let entrants = offsets.indices.map { Entrant(name: "P\($0)", colorIndex: $0, playerIndex: $0) }
        let race = Race(track: track, entrants: entrants, laps: 99, seed: 1)
        let dt = 1.0 / 120.0
        while race.phase == .countdown { race.step(dt: dt, humanInputs: []) }
        for (car, o) in zip(race.cars, offsets) {
            car.position = Vec2(500, 150) + o
            car.heading = 0
            car.velocity = Vec2(200, 0)
            car.angularVelocity = 0
        }
        let inputs = Array(repeating: CarInput(throttle: 1, brake: 0, steer: 0), count: offsets.count)
        var t = 0.0
        while t < seconds {
            race.step(dt: dt, humanInputs: inputs)
            t += dt
        }
        let last = race.cars[race.cars.count - 1]
        return (last.speed, last.slipstream)
    }

    print("== Slipstream")
    let solo = run([.zero])
    let pair = run([Vec2(60, 0), .zero])
    let train = run([Vec2(120, 0), Vec2(60, 0), .zero])
    let alongside = run([Vec2(10, 45), .zero])
    let far = run([Vec2(400, 0), .zero])
    print(String(format: "  after 1.5s flat out: solo %.1f, behind one car %.1f (draft %.2f), behind two %.1f (draft %.2f), alongside %.1f (draft %.2f), 400 back %.1f (draft %.2f)",
                 solo.speed, pair.speed, pair.draft, train.speed, train.draft, alongside.speed, alongside.draft, far.speed, far.draft))
    check(pair.speed > solo.speed + 2, "drafting behind a car gives a speed boost")
    check(train.speed > pair.speed, "drafting behind a line of cars gives more")
    check(alongside.draft == 0 && abs(alongside.speed - solo.speed) < 0.01, "no draft when alongside")
    check(far.draft == 0, "no draft from a car far ahead")
    check(train.draft <= 1.5, "draft is capped")
    return problems
}
