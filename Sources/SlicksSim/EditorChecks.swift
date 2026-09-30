import Foundation
import SlicksCore

/// Exercises the editing operations the level editor relies on.
func editorChecks() -> Int {
    var problems = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { print("  FAIL: \(what)"); problems += 1 }
    }
    print("== Editor operations")

    // Start/reverse keep bridges on the same physical point.
    var d = BuiltInTracks.all.first { $0.id == "twin-bridges" }!
    let bridgePoints = d.bridges.map { d.controlPoints[$0.controlPoint] }
    d.makeStart(5)
    check(d.bridges.map { d.controlPoints[$0.controlPoint] } == bridgePoints, "makeStart moves bridges")
    d.reverseDirection()
    check(d.bridges.map { d.controlPoints[$0.controlPoint] } == bridgePoints, "reverse moves bridges")
    let before = d.controlPoints.count
    d.insertControlPoint(Vec2(1, 1), at: 1)
    check(d.bridges.map { d.controlPoints[$0.controlPoint] } == bridgePoints, "insert moves bridges")
    d.removeControlPoint(at: 1)
    check(d.controlPoints.count == before && d.bridges.map { d.controlPoints[$0.controlPoint] } == bridgePoints, "remove moves bridges")
    d.removeControlPoint(at: d.bridges[0].controlPoint)
    check(d.bridges.count == 1, "removing a bridge point removes the bridge")

    // Build a figure eight from scratch and bridge its crossing with the editor helpers.
    var f = TrackDefinition.blank(id: "custom-test")
    check(f.crossings().isEmpty, "blank oval has no crossings")
    f.controlPoints = [Vec2(480, 90), Vec2(700, 120), Vec2(860, 300), Vec2(700, 480), Vec2(480, 300),
                       Vec2(260, 120), Vec2(100, 300), Vec2(260, 480)]
    let xs = f.crossings()
    check(xs.count == 1, "figure eight has one crossing (found \(xs.count))")
    if let x = xs.first {
        let k = f.addBridge(at: x, over: x.passA)
        check(f.bridges.count == 1, "bridge added")
        let over1 = f.bridges[k].controlPoint
        let x2 = f.crossings().min { $0.point.distance(to: x.point) < $1.point.distance(to: x.point) }!
        f.flipBridge(k, at: x2)
        check(f.bridges[k].controlPoint != over1, "flip moves the bridge to the other pass")
        let t = Track(definition: f)
        check(t.bridges.count == 1 && t.bridges[0].deckEnd - t.bridges[0].deckStart > 40, "flipped bridge spans the lower road")
        print("  figure eight: \(f.controlPoints.count) points, issues \(t.issues().map(\.message))")
    }

    // Patches entirely off the map mustn't crash the rasterizer.
    var off = TrackDefinition.blank(id: "custom-off")
    off.patches = [Patch(.sand, .circle(center: Vec2(-500, -500), radius: 20)),
                   Patch(.wall, .rect(origin: Vec2(2000, 50), size: Vec2(10, 10)))]
    _ = Track(definition: off)

    // Shape conversions keep the center.
    for shape in [PatchShape.circle(center: Vec2(100, 100), radius: 30),
                  .rect(origin: Vec2(10, 20), size: Vec2(80, 40)),
                  .capsule(from: Vec2(0, 0), to: Vec2(100, 0), radius: 8)] {
        for kind in PatchShapeKind.allCases {
            check(shape.converted(to: kind).center.distance(to: shape.center) < 0.01, "convert \(shape.kind) to \(kind) keeps center")
        }
    }

    // Per-point widths follow their points through edits.
    var w = TrackDefinition.blank(id: "custom-widths")
    check(w.pointWidths.isEmpty && !w.hasPointWidths, "blank track has no point widths")
    w.setRoadWidth(120, atPoint: 3)
    check(w.pointWidths.count == w.controlPoints.count && w.roadWidth(atPoint: 3) == 120, "setRoadWidth")
    let wide = w.controlPoints[3]
    w.makeStart(2)
    check(w.roadWidth(atPoint: w.controlPoints.firstIndex(of: wide)!) == 120, "makeStart keeps widths on their points")
    w.reverseDirection()
    check(w.roadWidth(atPoint: w.controlPoints.firstIndex(of: wide)!) == 120, "reverse keeps widths on their points")
    let wi = w.controlPoints.firstIndex(of: wide)!
    w.setRoadWidth(60, atPoint: (wi + 1) % w.controlPoints.count)
    w.insertControlPoint(Vec2(1, 1), at: wi + 1)
    check(w.roadWidth(atPoint: wi + 1) == 90, "insert between custom widths takes their mean (got \(w.roadWidth(atPoint: wi + 1)))")
    w.removeControlPoint(at: wi + 1)
    check(w.pointWidths.count == w.controlPoints.count && w.roadWidth(atPoint: wi) == 120, "remove keeps widths aligned")
    w.setRoadWidth(nil, atPoint: wi)
    w.setRoadWidth(nil, atPoint: (wi + 1) % w.controlPoints.count)
    check(w.pointWidths.isEmpty, "clearing every width compacts the list")

    // The road really is as wide as asked at each point.
    var v = TrackDefinition.blank(id: "custom-v")
    v.setRoadWidth(140, atPoint: 2)
    v.setRoadWidth(50, atPoint: 7)
    let vt = Track(definition: v)
    for (i, target) in [(2, 140.0), (7, 50.0)] {
        let dense = Track.centerline(through: v.controlPoints)
        let di = i * Track.splineSteps
        let nrm = (dense[di + 1] - dense[di - 1]).normalized.perp
        let p = v.controlPoints[i]
        let inside = vt.surface(at: p + nrm * (target / 2 - 3)), outside = vt.surface(at: p + nrm * (target / 2 + 2))
        check(inside == .asphalt && outside == .curb, "width \(Int(target)) at point \(i): \(inside) inside, \(outside) at edge")
    }

    // Tracks saved before point widths existed still load.
    let legacy = #"{"id":"custom-old","name":"Old","width":960,"height":600,"roadWidth":80,"controlPoints":[{"x":100,"y":100},{"x":800,"y":100},{"x":450,"y":500}],"defaultLaps":3,"theme":"summer","background":2,"barrierThickness":7,"patches":[],"bridges":[]}"#
    if let old = try? JSONDecoder().decode(TrackDefinition.self, from: Data(legacy.utf8)) {
        check(old.pointWidths.isEmpty && old.roadWidth == 80, "legacy JSON decodes with default widths")
    } else {
        check(false, "legacy JSON decodes")
    }

    // Round trip through JSON.
    if let data = try? JSONEncoder().encode(BuiltInTracks.all),
       let back = try? JSONDecoder().decode([TrackDefinition].self, from: data) {
        check(back == BuiltInTracks.all, "JSON round trip")
    } else {
        check(false, "JSON round trip")
    }
    return problems
}

/// Built-in layouts with per-point widths, raced by the main loop like the built-ins.
func widthTestTracks() -> [TrackDefinition] {
    // Wide start straight pinching into a narrow hairpin section.
    var hairpin = BuiltInTracks.all.first { $0.id == "hairpin-valley" }!
    hairpin.id = "width-hairpin"
    hairpin.name = "Width test: hairpin"
    for (i, w) in [(0, 120.0), (1, 110), (4, 56), (5, 50), (6, 50), (7, 60), (11, 100), (13, 64)] {
        hairpin.setRoadWidth(w, atPoint: i)
    }

    // Narrow lower road under a wide bridge, with a very wide sweeper elsewhere.
    var overpass = BuiltInTracks.all.first { $0.id == "overpass" }!
    overpass.id = "width-overpass"
    overpass.name = "Width test: overpass"
    for (i, w) in [(7, 104.0), (15, 60), (3, 130), (11, 56)] {
        overpass.setRoadWidth(w, atPoint: i)
    }
    // Reported bug: one bridge's down-ramp runs out under the other bridge's deck, which used
    // to punch a hole in that deck.
    let pts: [(Double, Double)] = [
        (620, 548), (420, 552), (230, 540), (100, 490), (60, 370), (80, 230), (129, 82), (361, 68), (390, 190),
        (395.33580615411523, 241.89150527704987), (378, 411), (195, 393), (244, 190), (386, 309), (594, 236),
        (707, 203), (760, 295), (782, 355), (752, 420), (690, 442), (628, 420), (603, 350), (600, 260),
        (600, 150), (640, 75), (760, 55), (880, 90), (915, 230), (905, 400), (860, 510), (760, 550),
    ]
    let overlap = TrackDefinition(
        id: "overlapping-bridges", name: "Bug: overlapping bridges", controlPoints: pts.map { Vec2($0.0, $0.1) },
        defaultLaps: 4, barrierDistance: 20,
        patches: [Patch(.wall, .capsule(from: Vec2(560, 497), to: Vec2(800, 497), radius: 5))],
        bridges: [BridgeDefinition(controlPoint: 22), BridgeDefinition(controlPoint: 13)])
    return [hairpin, overpass, overlap]
}

/// Drifts one car in circles on a big asphalt pad with a band of sand across it, and checks
/// that sand gets thrown and tracked out onto the asphalt, repeatably.
func looseSandCheck() -> Int {
    var problems = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { print("  FAIL: \(what)"); problems += 1 }
    }
    let pts = (0..<12).map { k -> Vec2 in
        let a = Double(k) / 12 * 2 * .pi - .pi / 2
        return Vec2(480 + 300 * cos(a), 300 + 200 * sin(a))
    }
    let band = PatchShape.rect(origin: Vec2(320, 0), size: Vec2(50, 600))
    let def = TrackDefinition(id: "sandpad", name: "Sandpad", roadWidth: 380, controlPoints: pts, background: .asphalt,
                              patches: [Patch(.sand, band, coversRoad: true)])
    let track = Track(definition: def)
    func run() -> Race {
        let race = Race(track: track, entrants: [Entrant(name: "P1", colorIndex: 0, playerIndex: 0)], laps: 99, seed: 7)
        let dt = 1.0 / 120.0
        while race.phase == .countdown { race.step(dt: dt, humanInputs: []) }
        // Flat out toward the band, then throw it into a drift across it and keep circling.
        let car = race.cars[0]
        car.position = Vec2(200, 300)
        car.heading = 0
        car.velocity = Vec2(230, 0)
        var t = 0.0
        while t < 8 {
            race.step(dt: dt, humanInputs: [CarInput(throttle: 1, brake: 0, steer: car.position.x > 290 || t > 0.6 ? 1 : 0)])
            t += dt
        }
        return race
    }
    print("== Loose sand")
    let race = run()
    guard let sand = race.looseSand else {
        check(false, "sand pad has a loose sand layer")
        return problems
    }
    let totals = sand.totals()
    // How far from the band loose sand ended up.
    var farthest = 0.0
    for y in 0..<track.height {
        for x in 0..<track.width where sand.coverage(x: x, y: y) > 0.02 {
            farthest = max(farthest, band.distance(to: Vec2(Double(x) + 0.5, Double(y) + 0.5)))
        }
    }
    print(String(format: "  drifting through a sand band: %.1f cells of loose sand, %.1f on asphalt, reaching %.0f from the band",
                 totals.total, totals.onRoad, farthest))
    check(totals.total > 2, "drifting through sand spreads some")
    check(farthest > 12, "loose sand travels away from the trap")
    check(totals.total < 400, "loose sand stays bounded")
    let again = run()
    check(again.looseSand?.amount == sand.amount, "loose sand is deterministic")
    return problems
}
