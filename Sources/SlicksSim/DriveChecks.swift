import Foundation
import SlicksCore

/// Drives a car through shortcuts in the race simulation, on lines beside each one and on to
/// the finish line, to see whether lap tracking credits the lap. `cuts` are straight lines
/// "x1,y1,x2,y2" in map units, checked to count on every line and all in one lap; without
/// any, drives the shortcuts `Track.shortcuts()` finds and just reports.
func driveChecks(trackFile: String, cuts spec: [String]) -> Int {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: trackFile)),
          let def = try? JSONDecoder().decode(TrackDefinition.self, from: data) else {
        print("  FAIL: can't read \(trackFile)"); return 1
    }
    let track = Track(definition: def)
    let n = track.sampleCount
    let dt = 1.0 / 120.0
    func wrap(_ i: Int) -> Int { (i % n + n) % n }
    func sample(_ p: Vec2) -> Int { (0..<n).min { track.path[$0].distance(to: p) < track.path[$1].distance(to: p) }! }
    func thin(_ pts: [Vec2], every d: Double) -> [Vec2] {
        var out = [pts[0]]
        for p in pts where p.distance(to: out.last!) >= d { out.append(p) }
        return out + [pts.last!]
    }

    /// A car on the road at sample `start` with lap progress `progress`, steered through
    /// `waypoints` by simple pursuit. Nil if it doesn't get through in `limit` seconds.
    func drive(_ waypoints: [Vec2], start: Int, progress: Double, limit: Double) -> (car: Car, time: Double)? {
        let race = Race(track: track, entrants: [Entrant(name: "P", colorIndex: 0, playerIndex: 0)], laps: 99)
        while race.phase == .countdown { race.step(dt: dt, humanInputs: [CarInput()]) }
        let car = race.cars[0]
        car.position = track.path[start]
        car.heading = track.tangents[start].angle
        car.velocity = track.tangents[start] * 60
        car.pathIndex = start
        car.progress = progress
        car.lapsCompleted = 0
        var k = 0, t = 0.0
        while t < limit {
            while k < waypoints.count - 1, car.position.distance(to: waypoints[k]) < 16 { k += 1 }
            if k == waypoints.count - 1, car.position.distance(to: waypoints[k]) < 16 { return (car, t) }
            let diff = wrapAngle((waypoints[k] - car.position).angle - car.heading)
            let slow = abs(diff) > 0.6 && car.speed > 50
            race.step(dt: dt, humanInputs: [CarInput(throttle: slow ? 0 : 0.75, brake: slow ? 0.5 : 0, steer: max(-1, min(1, diff * 3)))])
            t += dt
        }
        return nil
    }

    var cuts: [[Vec2]] = []
    for s in spec {
        let v = s.split(separator: ",").compactMap { Double($0) }
        guard v.count == 4 else { print("  FAIL: cut \"\(s)\" isn't x1,y1,x2,y2"); return 1 }
        cuts.append([Vec2(v[0], v[1]), Vec2(v[2], v[3])])
    }
    let given = !cuts.isEmpty
    if !given { cuts = track.shortcuts().map(\.route) }
    print("== Drive: \(def.name), \(given ? "\(cuts.count) given" : "\(cuts.count) found") shortcut(s)")
    var problems = 0

    // Each cut on its own: from a little before it, through it, and on to the finish line.
    for (i, cut) in cuts.enumerated() {
        let a = sample(cut[0]), b = sample(cut[cut.count - 1])
        let start = wrap(a - 25), end = wrap(b + max(25, n - b + 5)), expected = wrap(end - start)
        let lead = thin((0...22).map { track.path[wrap(start + $0)] }, every: 8)
        let tail = thin((3...max(25, n - b + 5)).map { track.path[wrap(b + $0)] }, every: 8)
        let road = drive(thin((0...expected).map { track.path[wrap(start + $0)] }, every: 8), start: start, progress: Double(start), limit: 60)
        print(String(format: "  cut %d (%.0f,%.0f)->(%.0f,%.0f) skips %.0f of road; road takes %@", i + 1,
                     cut[0].x, cut[0].y, cut.last!.x, cut.last!.y, Double(track.indexDelta(from: a, to: b)) * track.spacing,
                     road.map { String(format: "%.2fs", $0.time) } ?? "too long"))
        let side = (cut.last! - cut[0]).normalized
        for o in stride(from: -12.0, through: 12, by: 4) {
            let shift = Vec2(-side.y, side.x) * o
            let line = String(format: "    line %+3.0f: ", o)
            guard let r = drive(lead + thin(cut, every: 6).map { $0 + shift } + tail, start: start, progress: Double(start), limit: 60) else {
                print(line + "didn't get through (the test driver hit something)"); continue
            }
            let gained = Int((r.car.progress - Double(start)).rounded())
            let counted = gained >= expected - 4
            var text = line + (counted ? "counted" : "LAP LOST") + ", progress \(gained) of \(expected)"
            text += String(format: ", %.2fs", r.time) + (road.map { String(format: " (saves %.2fs)", $0.time - r.time) } ?? "")
            print(text)
            if given && !counted { problems += 1 }
        }
    }

    // All the given cuts in one lap, on lines beside them too.
    guard given else { return 0 }
    let ends = cuts.map { (from: sample($0[0]), to: sample($0[$0.count - 1]), cut: $0) }
    for o in [-8.0, 0, 8] {
        var waypoints: [Vec2] = []
        var i = n - 20
        while i < 2 * n + 30 {
            if let c = ends.first(where: { $0.from == wrap(i) }) {
                let side = (c.cut.last! - c.cut[0]).normalized
                waypoints += thin(c.cut, every: 6).map { $0 + Vec2(-side.y, side.x) * o }
                i += track.indexDelta(from: c.from, to: c.to) + 3
            } else {
                if i % 2 == 0 { waypoints.append(track.path[wrap(i)]) }
                i += 1
            }
        }
        let line = String(format: "  full lap taking every cut, line %+.0f: ", o)
        guard let r = drive(waypoints, start: n - 20, progress: -20, limit: 120) else {
            print(line + "didn't get round (the test driver hit something)"); continue
        }
        print(line + (r.car.lapsCompleted == 1 ? "lap counted" : "LAP LOST") + String(format: " in %.2fs", r.time))
        if r.car.lapsCompleted != 1 { problems += 1 }
    }
    return problems
}
