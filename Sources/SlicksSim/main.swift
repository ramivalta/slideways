import CoreGraphics
import Foundation
import ImageIO
import SlicksCore
import SlicksGame
import UniformTypeIdentifiers

// Headless checks for tracks, physics and AI.
// Usage: swift run -c release SlicksSim [outputDir] [trackId]

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "/tmp/slideways-sim")
let onlyTrack = args.count > 2 ? args[2] : nil
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

/// Pairs of centerline samples that are close in space but far apart along the track.
func overlaps(_ track: Track) -> [(Int, Int, Double)] {
    let n = track.sampleCount
    let minGap = track.definition.roadWidth + Track.curbWidth * 2 + 8
    let skip = Int((track.definition.roadWidth * 2.5) / track.spacing)
    var found: [(Int, Int, Double)] = []
    var i = 0
    while i < n {
        var j = i + skip
        while j < n {
            if abs(track.indexDelta(from: i, to: j)) > skip {
                let d = track.path[i].distance(to: track.path[j])
                if d < minGap { found.append((i, j, d)); j += skip; continue }
            }
            j += 1
        }
        i += 4
    }
    return found
}

var failures = 0
let dt = 1.0 / 120.0

/// Skidpad: a huge open circle. Floor it, then hold full left lock like a player would,
/// and report how far the car slides (drift angle = heading vs direction of travel).
func skidpad() {
    let pts = (0..<12).map { k -> Vec2 in
        let a = Double(k) / 12 * 2 * .pi - .pi / 2
        return Vec2(480 + 300 * cos(a), 300 + 200 * sin(a))
    }
    let def = TrackDefinition(id: "skidpad", name: "Skidpad", roadWidth: 380, controlPoints: pts, background: .asphalt)
    let track = Track(definition: def)
    let race = Race(track: track, entrants: [Entrant(name: "P1", colorIndex: 0, playerIndex: 0)], laps: 99)
    let car = race.cars[0]
    var maxDrift = 0.0, driftTime = 0.0, speedAtTurn = 0.0, minSpeed = Double.infinity
    var t = 0.0
    while t < Race.countdownDuration + 4.0 {
        let racing = t >= Race.countdownDuration
        let tr = t - Race.countdownDuration
        let turning = racing && tr >= 1.5
        if racing && tr < 1.5 { speedAtTurn = car.speed }
        race.step(dt: dt, humanInputs: [CarInput(throttle: 1, brake: 0, steer: turning ? 1 : 0)])
        if turning {
            let drift = abs(wrapAngle(car.velocity.angle - car.heading)) * 180 / .pi
            if car.speed > 30 { maxDrift = max(maxDrift, drift) }
            if drift > 12 { driftTime += dt }
            minSpeed = min(minSpeed, car.speed)
        }
        t += dt
    }
    print(String(format: "== Skidpad: speed at turn-in %.0f, max drift angle %.0f°, drifting %.1fs of 2.5s, min speed in turn %.0f",
                 speedAtTurn, maxDrift, driftTime, minSpeed))
}
skidpad()
failures += editorChecks()

/// Crash test: floor it head-on into a wall like a player would, keep the throttle pinned and
/// steer left after the hit. The car should drive away forward and turn left, with no lingering
/// effect beyond the bounce itself.
func crashTest() {
    let pts = (0..<12).map { k -> Vec2 in
        let a = Double(k) / 12 * 2 * .pi - .pi / 2
        return Vec2(480 + 300 * cos(a), 300 + 200 * sin(a))
    }
    var def = TrackDefinition(id: "crash", name: "Crash", roadWidth: 380, controlPoints: pts, background: .asphalt)
    let probe = Track(definition: def)
    let n = probe.sampleCount
    let wallAt = probe.path[n - 6] + probe.tangents[n - 6] * 230
    def.patches = [Patch(.wall, .rect(origin: wallAt - Vec2(12, 150), size: Vec2(24, 300)), coversRoad: true)]
    let track = Track(definition: def)
    let race = Race(track: track, entrants: [Entrant(name: "P1", colorIndex: 0, playerIndex: 0)], laps: 99)
    let car = race.cars[0]
    var t = 0.0, hitAt: Double?, impactSpeed = 0.0, reboundSpeed = 0.0, forwardAgainAt: Double?, headingAtHit = 0.0
    while t < Race.countdownDuration + 6 {
        let steer = hitAt != nil && t - hitAt! > 0.05 ? 1.0 : 0.0
        let before = car.speed
        race.step(dt: dt, humanInputs: [CarInput(throttle: 1, brake: 0, steer: steer)])
        if hitAt == nil, car.wallHits > 0 { hitAt = t; impactSpeed = before; headingAtHit = car.heading }
        if let h = hitAt {
            reboundSpeed = min(reboundSpeed, car.forwardSpeed)
            if forwardAgainAt == nil, t - h > 0.02, car.forwardSpeed > 0 { forwardAgainAt = t - h }
            if t - h > 0.6 { break }
        }
        t += dt
    }
    guard hitAt != nil else { print("== Crash test: FAIL, never hit the wall"); failures += 1; return }
    let turned = wrapAngle(car.heading - headingAtHit) * 180 / .pi
    let recovery = forwardAgainAt ?? .infinity
    print(String(format: "== Crash test: hit at %.0f, rebound %.0f, rolling forward again after %.2fs, steering left turned %+.0f° in 0.6s",
                 impactSpeed, reboundSpeed, recovery, turned))
    if recovery > 0.4 || turned < 20 { print("  FAIL: crash recovery"); failures += 1 }
}
crashTest()

/// All liveries, straight and steering, blown up for inspection.
func kartSheet() {
    let cellW = 300, cellH = 170
    let ctx = CGContext(data: nil, width: cellW * 4, height: cellH * 2, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.33, green: 0.34, blue: 0.36, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: cellW * 4, height: cellH * 2))
    ctx.interpolationQuality = .high
    for i in 0..<8 {
        let img = CarArt.previewImage(colorIndex: i, steer: i % 2 == 0 ? 0 : 0.45)
        let w = CGFloat(img.width) * 2.6, h = CGFloat(img.height) * 2.6
        let x = CGFloat(i % 4 * cellW) + (CGFloat(cellW) - w) / 2
        let y = CGFloat(i / 4 * cellH) + (CGFloat(cellH) - h) / 2
        ctx.draw(img, in: CGRect(x: x, y: y, width: w, height: h))
    }
    writePNG(ctx.makeImage()!, to: outDir.appendingPathComponent("karts.png"))
}
kartSheet()

for def in BuiltInTracks.all + widthTestTracks() where onlyTrack == nil || def.id == onlyTrack {
    let t0 = Date()
    let track = Track(definition: def)
    let buildMs = Date().timeIntervalSince(t0) * 1000
    print("== \(def.name) [\(def.id)] length \(Int(track.length)) samples \(track.sampleCount) built in \(Int(buildMs)) ms")

    // Path must stay on road and within the screen.
    var offRoad = 0
    for (i, p) in track.path.enumerated() {
        let s = track.surface(at: p, level: Int(track.sampleLevels[i]))
        if s != .asphalt && s != .ice && s != .sand {
            offRoad += 1
            print("   undrivable sample \(i) at \(Int(p.x)),\(Int(p.y)) level \(track.sampleLevels[i]) surface \(s)")
        }
    }
    for (bi, b) in track.bridges.enumerated() {
        let deckSamples = track.sampleLevels.filter { $0 == 1 }.count
        let c = track.path[b.centerSample]
        print(String(format: "  bridge %d: deck %.0f long (%.0f back, %.0f ahead) x %.0f at (%.0f, %.0f), %d deck samples total",
                     bi, b.deckEnd - b.deckStart, -b.deckStart, b.deckEnd, b.halfWidth * 2, c.x, c.y, deckSamples))
    }
    if offRoad > 0 { print("  WARN: \(offRoad) centerline samples not drivable"); failures += 1 }
    let crossings = def.crossings()
    let bridged = crossings.filter { def.bridgeIndex(at: $0) != nil }.count
    print("  editor: \(crossings.count) crossing(s), \(bridged) bridged, issues: \(track.issues().map(\.message))")
    if bridged != def.bridges.count { print("  FAIL: editor doesn't find every bridge on a crossing"); failures += 1 }
    let ov = overlaps(track)
    if !ov.isEmpty {
        let sample = ov.prefix(3).map { "(\($0.0),\($0.1)) d=\(Int($0.2)) at \(Int(track.path[$0.0].x)),\(Int(track.path[$0.0].y))" }
        print("  NOTE: \(ov.count) close pairs (crossing or tight legs): \(sample.joined(separator: " "))")
    }
    for slot in track.gridSlots(count: 8) where track.surface(at: slot.position) != .asphalt {
        print("  WARN: grid slot off asphalt at \(slot.position)"); failures += 1
    }

    // AI-only race.
    let entrants = (0..<8).map { Entrant(name: "AI\($0)", colorIndex: $0, playerIndex: nil, aiSkill: 0.55 + Double($0) * 0.06) }
    let race = Race(track: track, entrants: entrants, laps: def.defaultLaps, seed: 42)
    var trails: [[Vec2]] = Array(repeating: [], count: 8)
    var steps = 0
    var impacts = 0
    var maxOff = 0.0
    var offRoadTime = [Double](repeating: 0, count: 8)
    var slideSteps = 0, carSteps = 0, speedSum = 0.0, maxSlip = 0.0
    var levelMismatch = 0, deckEntries = 0, underEntries = 0
    var lastZone = [Int?](repeating: nil, count: 8)
    while race.phase != .finished && race.time < 400 {
        race.step(dt: dt, humanInputs: [])
        impacts += race.drainImpacts().count
        steps += 1
        if race.phase == .racing {
            for c in race.cars {
                // A car in a bridge zone must be on the level its stretch of road is on.
                // Allow a few samples of slack at the zone edges.
                if c.bridgeZone != nil {
                    let n = track.sampleCount
                    let ok = (-4...4).contains { k in Int(track.sampleLevels[((c.pathIndex + k) % n + n) % n]) == c.level }
                    if !ok { levelMismatch += 1; if levelMismatch <= 3 { print("   level mismatch: car \(c.id) level \(c.level) idx \(c.pathIndex) pos \(Int(c.position.x)),\(Int(c.position.y)) t=\(String(format: "%.2f", race.time))") } }
                }
                if c.bridgeZone != nil, lastZone[c.id] == nil { if c.level == 1 { deckEntries += 1 } else { underEntries += 1 } }
                lastZone[c.id] = c.bridgeZone
            }
            for c in race.cars where !c.isFinished {
                carSteps += 1
                if c.slip > 22 { slideSteps += 1 }
                speedSum += c.speed
                maxSlip = max(maxSlip, c.slip)
            }
        }
        if steps % 6 == 0 {
            for c in race.cars {
                trails[c.id].append(c.position)
                let d = c.position.distance(to: track.path[c.pathIndex])
                maxOff = max(maxOff, d)
                let s = track.surface(at: c.position)
                if s == .grass || s == .sand { offRoadTime[c.id] += dt * 6 }
            }
        }
    }
    let finished = race.cars.filter(\.isFinished).count
    print(String(format: "  race: %d/%d finished in %.1fs sim, impacts %d, max dist from centerline %.0f", finished, race.cars.count, race.time, impacts, maxOff))
    print(String(format: "  handling: sliding %.0f%% of the time, avg speed %.0f, max slip %.0f",
                 100 * Double(slideSteps) / Double(max(carSteps, 1)), speedSum / Double(max(carSteps, 1)), maxSlip))
    for car in race.standings {
        let best = car.bestLap.map { String(format: "%.2f", $0) } ?? "-"
        let total = car.finishTime.map { String(format: "%.2f", $0) } ?? "DNF"
        print(String(format: "   %@ total %@ best %@ laps %d wallHits %d offroad %.1fs", car.name, total, best, car.lapsCompleted, car.wallHits, offRoadTime[car.id]))
    }
    if finished < race.cars.count { failures += 1; print("  FAIL: not all AI finished") }
    if !track.bridges.isEmpty {
        print("  bridges: \(deckEntries) entries over, \(underEntries) under, \(levelMismatch) wrong-level car-steps")
        if levelMismatch > 0 || deckEntries == 0 || underEntries == 0 { failures += 1; print("  FAIL: bridge levels") }
    }

    // Picture of the track with AI trails for eyeballing.
    let r0 = Date()
    let base = TrackRenderer.makeCompositeImage(for: track)
    writePNG(base, to: outDir.appendingPathComponent("\(def.id)-clean.png"))
    print("  rendered image in \(Int(Date().timeIntervalSince(r0) * 1000)) ms")
    let ctx = CGContext(data: nil, width: track.width, height: track.height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(base, in: CGRect(x: 0, y: 0, width: track.width, height: track.height))
    for (i, trail) in trails.enumerated() where i == 0 || i == 7 {
        ctx.setStrokeColor(i == 0 ? CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 0.6) : CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 0.6))
        ctx.setLineWidth(1)
        guard let first = trail.first else { continue }
        ctx.move(to: CGPoint(x: first.x, y: first.y))
        for p in trail.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
        ctx.strokePath()
    }
    writePNG(ctx.makeImage()!, to: outDir.appendingPathComponent("\(def.id).png"))
}

print(failures == 0 ? "ALL OK" : "\(failures) problem(s)")
exit(failures == 0 ? 0 : 1)
