import Foundation
import SlicksCore

/// An AI car dropped in the fenced-off grass beside the hairpin (where cars used to get
/// knocked through the sand trap's gap in the tire wall and never get out) has to find its
/// way back to the road.
func fencedInCheck() -> Int {
    guard let def = widthTestTracks().first(where: { $0.id == "width-hairpin" }) else {
        print("  FAIL: no width-hairpin track"); return 1
    }
    let track = Track(definition: def)
    let dt = 1.0 / 120.0
    let limit = 20.0
    print("== Fenced in")
    var problems = 0
    func cell(_ p: Vec2) -> Int { Int(floor(p.y)) * track.width + Int(floor(p.x)) }
    func onRoad(_ p: Vec2) -> Bool { Double(track.distanceField[cell(p)]) <= track.halfRoad(atCell: cell(p)) }
    // Near the gap, along the dead-end strip between the hairpin's lower leg and the bottom
    // straight, right at its far end, and out in the big infield.
    for start in [Vec2(415, 359), Vec2(490, 431), Vec2(530, 448), Vec2(770, 462), Vec2(220, 250)] {
        guard track.surface(at: start) != .wall, !onRoad(start) else {
            print("  FAIL: start (\(start.x), \(start.y)) isn't open ground off the road"); problems += 1; continue
        }
        let race = Race(track: track, entrants: [Entrant(name: "AI", colorIndex: 0, playerIndex: nil)], laps: 99)
        while race.phase == .countdown { race.step(dt: dt, humanInputs: []) }
        let car = race.cars[0]
        car.position = start
        car.velocity = .zero
        car.heading = 0
        car.pathIndex = Int(track.nearestSample[cell(start)])
        var t = 0.0
        while t < limit, !onRoad(car.position) {
            race.step(dt: dt, humanInputs: [])
            t += dt
        }
        let back = onRoad(car.position)
        print(String(format: "  from (%.0f, %.0f): %@", start.x, start.y,
                     back ? String(format: "back on the road after %.1fs", t) : "still off the road after \(Int(limit))s"))
        if !back { print("  FAIL: AI stuck behind the tire wall"); problems += 1 }
    }
    return problems
}
