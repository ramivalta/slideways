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
failures += looseSandCheck()

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

/// 16-bit stereo WAV.
func writeWAV(_ left: [Float], _ right: [Float], sampleRate: Int, to url: URL) {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(left.count * 4)
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2)
    u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(bytes)
    for i in left.indices {
        for s in [left[i], right[i]] {
            u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767)))
        }
    }
    try? data.write(to: url)
}

/// Offline sound check: renders each effect and a full AI race mix to WAV files (for listening)
/// and checks the output is audible, finite and not overdriven.
func soundCheck() {
    let rate = 48_000
    var problems: [String] = []
    func check(_ name: String, _ out: (left: [Float], right: [Float]), minRMS: Float = 0.01) {
        let all = out.left + out.right
        let finite = all.allSatisfy(\.isFinite)
        let peak = all.map(abs).max() ?? 0
        let rms = (all.reduce(0) { $0 + $1 * $1 } / Float(max(all.count, 1))).squareRoot()
        let hot = Float(all.filter { abs($0) > 0.72 }.count) / Float(max(all.count, 1))
        print(String(format: "   %@: peak %.2f, rms %.3f, %.2f%% near the limiter", name, peak, rms, hot * 100))
        if !finite { problems.append("\(name) has NaN/inf") }
        if rms < minRMS { problems.append("\(name) is silent") }
        if hot > 0.01 { problems.append("\(name) is overdriven") }
        writeWAV(out.left, out.right, sampleRate: rate, to: outDir.appendingPathComponent("sound-\(name).wav"))
    }
    print("== Sound check (WAVs in \(outDir.path))")

    // Engine: idle, rev up flat out, lift off, back to idle.
    do {
        let synth = Synth(sampleRate: Double(rate))
        var l: [Float] = [], r: [Float] = []
        for step in 0..<(5 * 60) {
            let t = Double(step) / 60
            var s = CarSound()
            s.engineGain = 1
            s.throttle = t > 0.5 && t < 3.5 ? 1 : 0
            s.rpm = t < 0.5 ? 0 : t < 3.5 ? min(1, (t - 0.5) / 2.5) : max(0, 1 - (t - 3.5) / 1.2)
            synth.setCars([s])
            let block = synth.render(seconds: 1.0 / 60)
            l += block.left; r += block.right
        }
        check("engine", (l, r))
    }
    // Tires: squeal building up on asphalt, then on ice, then grass rumble.
    do {
        let synth = Synth(sampleRate: Double(rate))
        var l: [Float] = [], r: [Float] = []
        for step in 0..<(4 * 60) {
            let t = Double(step) / 60
            var s = CarSound()
            s.tireGain = 1
            if t < 1.6 { s.screech = min(1, t / 1.2) } else if t < 2.8 { s.screech = 0.7; s.screechPitch = 0.62 } else { s.rumble = 0.8 }
            synth.setCars([s])
            let block = synth.render(seconds: 1.0 / 60)
            l += block.left; r += block.right
        }
        check("tires", (l, r))
    }
    // One-shots, spaced out.
    do {
        let synth = Synth(sampleRate: Double(rate))
        let shots: [SoundEffect] = [.countdown, .countdown, .countdown, .go, .wallHit(strength: 0.3, pan: -0.6),
                                    .wallHit(strength: 1, pan: 0.6), .carHit(strength: 0.4, pan: 0), .carHit(strength: 1, pan: 0),
                                    .lap, .finish, .menuMove, .menuSelect]
        var l: [Float] = [], r: [Float] = []
        for e in shots {
            synth.trigger(e)
            let block = synth.render(seconds: e == .finish ? 1.3 : 0.6)
            l += block.left; r += block.right
        }
        check("effects", (l, r))
    }
    // A whole AI race through RaceAudio, as the game would play it: 8 karts, impacts and all.
    do {
        let track = Track(definition: BuiltInTracks.all[0])
        var settings = RaceSettings()
        settings.humanPlayers = 0
        settings.aiOpponents = 8
        let race = Race(track: track, entrants: settings.entrants(seed: 7), laps: 1, seed: 7)
        let audio = RaceAudio(race: race)
        let synth = Synth(sampleRate: Double(rate))
        var l: [Float] = [], r: [Float] = []
        var hits = 0
        for _ in 0..<(22 * 60) {
            for _ in 0..<2 { race.step(dt: 1.0 / 120, humanInputs: []) }
            let out = audio.update(race: race, impacts: race.drainImpacts(), humanInputs: [], paused: false)
            synth.setCars(out.cars)
            for e in out.effects {
                if case .wallHit = e { hits += 1 } else if case .carHit = e { hits += 1 }
                synth.trigger(e)
            }
            let block = synth.render(seconds: 1.0 / 60)
            l += block.left; r += block.right
        }
        check("race", (l, r))
        print("   race: \(hits) impact sounds in 22s")
    }

    // Results screen: once the race is over the karts must fade to silence.
    do {
        let track = Track(definition: BuiltInTracks.all[0])
        var settings = RaceSettings()
        settings.humanPlayers = 0
        settings.aiOpponents = 4
        let race = Race(track: track, entrants: settings.entrants(seed: 3), laps: 1, seed: 3)
        let audio = RaceAudio(race: race)
        while race.phase != .finished && race.time < 200 {
            race.step(dt: 1.0 / 120, humanInputs: [])
            _ = race.drainImpacts()
        }
        let synth = Synth(sampleRate: Double(rate))
        var tail: (left: [Float], right: [Float]) = ([], [])
        for frame in 0..<(3 * 60) {
            let out = audio.update(race: race, impacts: [], humanInputs: [], paused: false, dt: 1.0 / 60)
            synth.setCars(out.cars)
            let block = synth.render(seconds: 1.0 / 60)
            // Keep the last second: well past the fade.
            if frame >= 2 * 60 { tail.left += block.left; tail.right += block.right }
        }
        let peak = (tail.left + tail.right).map(abs).max() ?? 0
        print(String(format: "   results screen: peak %.5f one second after the fade", peak))
        if race.phase != .finished { problems.append("results test race never finished") }
        if peak > 0.001 { problems.append("karts still audible on the results screen") }
    }

    if problems.isEmpty { print("  sound OK") } else { for p in problems { print("  FAIL: \(p)") }; failures += problems.count }
}
soundCheck()

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

/// A track JSON file given in place of a track id is raced on its own.
let fileTrack: TrackDefinition? = onlyTrack.flatMap { path in
    guard path.hasSuffix(".json") else { return nil }
    guard let data = FileManager.default.contents(atPath: path),
          let def = try? JSONDecoder().decode(TrackDefinition.self, from: data) else {
        print("Can't read track file \(path)")
        exit(2)
    }
    return def
}
let simTracks = fileTrack.map { [$0] } ?? (BuiltInTracks.all + widthTestTracks()).filter { onlyTrack == nil || $0.id == onlyTrack }

for def in simTracks {
    let t0 = Date()
    let track = Track(definition: def)
    let buildMs = Date().timeIntervalSince(t0) * 1000
    print("== \(def.name) [\(def.id)] length \(Int(track.length)) samples \(track.sampleCount) built in \(Int(buildMs)) ms")

    // Path must stay on road and within the screen.
    var offRoad = 0
    for (i, p) in track.path.enumerated() {
        let s = track.surface(at: p, level: Int(track.sampleLevels[i]))
        if ![.asphalt, .ice, .sand, .water, .mud].contains(s) {
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
    // Every cell a deck image covers must count as that deck for physics, or cars fall through.
    for (bi, b) in track.bridges.enumerated() {
        let r = b.deckBounds
        var holes = 0, stolen = 0, first: (Int, Int)?
        for y in r.minY..<r.maxY {
            for x in r.minX..<r.maxX {
                let p = Vec2(Double(x) + 0.5, Double(y) + 0.5)
                let l = track.upperRoadLocal(bridge: b, point: p)
                // Stay a cell inside the edges, where both measures agree.
                guard l.along > b.deckStart + 1, l.along < b.deckEnd - 1, l.lateral < b.driveHalfWidth - 1 else { continue }
                switch track.deck(x: x, y: y) {
                case bi?: continue
                case nil: holes += 1
                default: stolen += 1
                }
                if first == nil { first = (x, y) }
            }
        }
        if holes + stolen > 0 {
            print("  FAIL: bridge \(bi) deck has \(holes) cells cars fall through and \(stolen) claimed by another bridge, first at \(first!)")
            failures += 1
        }
    }
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
    if let sand = race.looseSand {
        let t = sand.totals()
        // Same race without spreading, to see what the loose sand costs in lap time.
        var still = def
        still.looseSand = false
        let calm = Race(track: Track(definition: still), entrants: entrants, laps: def.defaultLaps, seed: 42)
        while calm.phase != .finished && calm.time < 400 { calm.step(dt: dt, humanInputs: []) }
        func meanBest(_ r: Race) -> Double {
            let laps = r.cars.compactMap(\.bestLap)
            return laps.reduce(0, +) / Double(max(laps.count, 1))
        }
        let roadCells = track.surfaces.filter { $0 == .asphalt || $0 == .curb }.count
        print(String(format: "  loose sand: %.0f cells total, %.0f on the road, %.2f%% of road covered; mean best lap %.2f vs %.2f without",
                     t.total, t.onRoad, 100 * Double(t.roadCellsCovered) / Double(max(roadCells, 1)), meanBest(race), meanBest(calm)))
    }
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
    if let sand = race.looseSand {
        // Loose sand in bright orange so it's easy to spot.
        for y in 0..<track.height {
            for x in 0..<track.width {
                let a = sand.coverage(x: x, y: y)
                guard a > 0 else { continue }
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0.45, blue: 0, alpha: min(1, 0.25 + a)))
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }
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
