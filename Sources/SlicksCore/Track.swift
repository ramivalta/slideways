import Foundation

/// A track built from a `TrackDefinition`: a raster surface map plus the sampled centerline
/// that AI and lap counting use.
public final class Track: @unchecked Sendable {
    public let definition: TrackDefinition
    public let width: Int
    public let height: Int

    /// Surface per cell, row-major with row 0 at the bottom (y-up, like the world).
    public let surfaces: [Surface]
    /// Distance from each cell to the nearest centerline sample (capped far from the road).
    public let distanceField: [Float]
    /// Index of the nearest centerline sample per cell, or -1 when far from the road.
    public let nearestSample: [Int32]

    /// Centerline resampled at uniform `spacing`. Index 0 is the start/finish line.
    public let path: [Vec2]
    public let tangents: [Vec2]
    /// Left-hand normals of the centerline.
    public let normals: [Vec2]
    /// Unsigned curvature (1 / radius) at each sample.
    public let curvature: [Double]
    public let spacing: Double
    public let length: Double

    /// Half the road width at each centerline sample. Constant through each bridge's upper
    /// road so decks and ramps have straight sides.
    public let halfWidths: [Double]
    /// Widest half road width anywhere on the track.
    public let maxHalfRoad: Double
    public var sampleCount: Int { path.count }

    /// Half road width at the road nearest a cell (the default width far from the road).
    public func halfRoad(atCell i: Int) -> Double {
        let s = Int(nearestSample[i])
        return s >= 0 ? halfWidths[s] : definition.roadWidth / 2
    }

    public static let curbWidth: Double = 4

    public init(definition def: TrackDefinition) {
        definition = def
        width = def.width
        height = def.height

        let spacing = 4.0
        self.spacing = spacing
        let dense = Track.spline(def.controlPoints)
        let centerline = Track.resample(dense, spacing: spacing)
        path = centerline.points
        length = centerline.length

        // Width at each sample, read off the dense spline the sample came from.
        let denseWidths = def.centerlineWidths()
        var halves: [Double]
        if denseWidths.count == dense.count, def.hasPointWidths {
            let m = dense.count
            halves = centerline.denseIndex.map { pos in
                let i = Int(pos), t = pos - Double(i)
                let a = denseWidths[i % m], b = denseWidths[(i + 1) % m]
                return (a + (b - a) * t) / 2
            }
        } else {
            halves = [Double](repeating: def.roadWidth / 2, count: path.count)
        }

        let n = path.count
        var tangents = [Vec2](repeating: .zero, count: n)
        for i in 0..<n {
            tangents[i] = (path[(i + 1) % n] - path[(i - 1 + n) % n]).normalized
        }
        self.tangents = tangents
        normals = tangents.map(\.perp)

        let span = 3
        var curvature = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = tangents[(i - span + n) % n].angle
            let b = tangents[(i + span) % n].angle
            curvature[i] = abs(wrapAngle(b - a)) / (Double(2 * span) * spacing)
        }
        self.curvature = curvature

        let controlSamples = Track.controlPointSamples(controlPoints: def.controlPoints, dense: dense,
                                                       sampleCount: n, totalLength: length)
        // Actual arc length between samples (the resampler spreads the remainder evenly).
        let step = length / Double(n)
        let bridges = Track.buildBridges(def: def, path: path, tangents: tangents, halfWidths: halves,
                                         controlSamples: controlSamples, step: step)
        self.bridges = bridges
        Track.flattenWidths(&halves, under: bridges)
        halfWidths = halves
        maxHalfRoad = halves.max() ?? def.roadWidth / 2
        let structure = Track.buildStructure(bridges, path: path, tangents: tangents, step: step,
                                             width: def.width, height: def.height)
        structureBridge = structure.bridge
        structureAlong = structure.along
        structureLateral = structure.lateral

        var levels = [UInt8](repeating: 0, count: n)
        for b in bridges {
            for k in -b.upperHalfSpan...b.upperHalfSpan where b.isZone(along: Double(k) * step, lateral: 0) {
                levels[((b.centerSample + k) % n + n) % n] = 1
            }
        }
        sampleLevels = levels

        let raster = Track.rasterize(def: def, path: path, halfWidths: halves, bridges: bridges, structure: structure)
        surfaces = raster.surfaces
        distanceField = raster.distance
        nearestSample = raster.nearest
    }

    // MARK: Bridges

    public let bridges: [Bridge]
    /// 1 where the centerline runs over a bridge deck, 0 elsewhere.
    public let sampleLevels: [UInt8]
    /// Per cell: index of the bridge structure (deck, ramps, zone) covering it, or -1.
    let structureBridge: [Int8]
    /// Per cell: distance along / away from that bridge's upper road. See `Bridge`.
    let structureAlong: [Float]
    let structureLateral: [Float]

    /// Position of a cell relative to the bridge structure covering it, if any.
    public func bridgeLocal(x: Int, y: Int) -> (bridge: Int, along: Double, lateral: Double)? {
        guard !bridges.isEmpty, x >= 0, y >= 0, x < width, y < height else { return nil }
        let c = y * width + x
        let bi = Int(structureBridge[c])
        guard bi >= 0 else { return nil }
        return (bi, Double(structureAlong[c]), Double(structureLateral[c]))
    }

    public func bridgeLocal(at p: Vec2) -> (bridge: Int, along: Double, lateral: Double)? {
        bridgeLocal(x: Int(floor(p.x)), y: Int(floor(p.y)))
    }

    /// Exact position of `p` relative to a bridge's upper road, for rendering at sub-cell
    /// resolution. Uses the same nearest-sample projection as the per-cell structure map.
    public func upperRoadLocal(bridge b: Bridge, point p: Vec2) -> (along: Double, lateral: Double) {
        let n = sampleCount
        let step = length / Double(n)
        let k0 = Int(floor(b.deckStart / step)) - 4, k1 = Int(ceil(b.deckEnd / step)) + 4
        var bestK = 0, bestD = Double.infinity
        for k in k0...k1 {
            let d = (p - path[((b.centerSample + k) % n + n) % n]).lengthSquared
            if d < bestD { bestD = d; bestK = k }
        }
        let i = ((b.centerSample + bestK) % n + n) % n
        let d = p - path[i]
        return (Double(bestK) * step + d.dot(tangents[i]), abs(d.dot(normals[i])))
    }

    /// Bridge whose deck covers a cell, if any.
    public func deck(x: Int, y: Int) -> Int? {
        guard let l = bridgeLocal(x: x, y: y), bridges[l.bridge].isDeck(along: l.along, lateral: l.lateral) else { return nil }
        return l.bridge
    }

    /// Bridge whose level zone contains `p`, if any.
    public func bridgeZone(containing p: Vec2) -> Int? {
        guard let l = bridgeLocal(at: p), bridges[l.bridge].isZone(along: l.along, lateral: l.lateral) else { return nil }
        return l.bridge
    }

    /// Surface a car at `level` feels at `p`. Bridge decks are asphalt.
    public func surface(at p: Vec2, level: Int) -> Surface {
        if level > 0, deck(x: Int(floor(p.x)), y: Int(floor(p.y))) != nil { return .asphalt }
        return surface(at: p)
    }

    /// Height of the bridge structure over a cell: 1 on a deck, falling to 0 at the bottom of
    /// each ramp. Nil for plain ground. Includes the ramp railings.
    public func elevation(x: Int, y: Int) -> (height: Double, bridge: Int, rampDistance: Double?)? {
        guard let l = bridgeLocal(x: x, y: y) else { return nil }
        let b = bridges[l.bridge]
        guard l.lateral <= b.halfWidth, let hgt = b.height(along: l.along) else { return nil }
        return (hgt, l.bridge, b.rampDistance(along: l.along))
    }

    /// Wall contact for a car on a given level. Cars on a deck ignore the ground under it and
    /// are kept on by the railings; cars below use the ground layer (abutments included).
    public func wallContact(center c: Vec2, radius r: Double, level: Int) -> (normal: Vec2, depth: Double)? {
        guard level > 0 else { return wallContact(center: c, radius: r) }
        return wallContact(center: c, radius: r) { x, y in
            if let l = self.bridgeLocal(x: x, y: y) {
                let b = self.bridges[l.bridge]
                if b.isDeck(along: l.along, lateral: l.lateral) { return l.lateral > b.driveHalfWidth }
            }
            return self.isWall(x, y)
        }
    }

    // MARK: Queries

    @inlinable public func cellIndex(_ x: Int, _ y: Int) -> Int { y * width + x }

    public func surface(x: Int, y: Int) -> Surface {
        guard x >= 0, y >= 0, x < width, y < height else { return .wall }
        return surfaces[y * width + x]
    }

    public func surface(at p: Vec2) -> Surface {
        surface(x: Int(floor(p.x)), y: Int(floor(p.y)))
    }

    @inlinable public func isWall(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return true }
        return surfaces[y * width + x] == .wall
    }

    /// Signed index difference b - a, wrapped to the shorter way around the loop.
    public func indexDelta(from a: Int, to b: Int) -> Int {
        let n = sampleCount
        var d = (b - a) % n
        if d > n / 2 { d -= n }
        if d < -n / 2 { d += n }
        return d
    }

    /// Nearest centerline sample to `p`, searching only a window around `index`.
    /// The window keeps crossings (figure eights) and big shortcuts from confusing progress.
    public func nearestSample(to p: Vec2, near index: Int, behind: Int = 30, ahead: Int = 60) -> Int {
        let n = sampleCount
        var best = index
        var bestD = Double.infinity
        for k in -behind...ahead {
            let i = ((index + k) % n + n) % n
            let d = (path[i] - p).lengthSquared
            if d < bestD {
                bestD = d
                best = i
            }
        }
        return best
    }

    /// Nearest wall contact for a circle, used for car collisions.
    /// Returns the push-out normal and penetration depth.
    public func wallContact(center c: Vec2, radius r: Double) -> (normal: Vec2, depth: Double)? {
        wallContact(center: c, radius: r) { x, y in self.isWall(x, y) }
    }

    /// Raster wall contact against the cells `blocked` reports as solid.
    func wallContact(center c: Vec2, radius r: Double, blocked: (Int, Int) -> Bool) -> (normal: Vec2, depth: Double)? {
        let x0 = Int(floor(c.x - r)), x1 = Int(floor(c.x + r))
        let y0 = Int(floor(c.y - r)), y1 = Int(floor(c.y + r))
        var bestD = Double.infinity
        var bestPoint = Vec2.zero
        var inside = false
        var away = Vec2.zero
        for y in y0...y1 {
            for x in x0...x1 where blocked(x, y) {
                let closest = Vec2(clamp(c.x, Double(x), Double(x + 1)), clamp(c.y, Double(y), Double(y + 1)))
                let d = (c - closest).length
                if d < r {
                    away += c - Vec2(Double(x) + 0.5, Double(y) + 0.5)
                    if d < 1e-6 { inside = true }
                    if d < bestD {
                        bestD = d
                        bestPoint = closest
                    }
                }
            }
        }
        guard bestD < r else { return nil }
        if inside {
            // Center is inside a wall cell: push away from the wall mass around us.
            let n = away.normalized
            return (n.lengthSquared > 0 ? n : Vec2(0, 1), r)
        }
        return ((c - bestPoint) / bestD, r - bestD)
    }

    /// Grid slots behind the start line, two abreast. Returns position, heading and path index.
    public func gridSlots(count: Int) -> [(position: Vec2, heading: Double, index: Int)] {
        let n = sampleCount
        return (0..<count).map { k in
            let row = k / 2
            let side: Double = k % 2 == 0 ? 1 : -1
            let i = ((n - 6 - row * 8) % n + n) % n
            let pos = path[i] + normals[i] * (side * halfWidths[i] * 0.45) - tangents[i] * (Double(k % 2) * 8)
            return (pos, tangents[i].angle, i)
        }
    }

    // MARK: Building

    /// Dense points the spline emits per control point segment.
    public static let splineSteps = 48

    /// The dense closed centerline a track built from `points` follows. Segment `i` (from
    /// control point `i` to `i + 1`) is `splineSteps` points starting at `i * splineSteps`.
    public static func centerline(through points: [Vec2]) -> [Vec2] { spline(points) }

    /// Centripetal Catmull-Rom through a closed loop of control points.
    static func spline(_ pts: [Vec2]) -> [Vec2] {
        let n = pts.count
        guard n >= 3 else { return pts }
        var out: [Vec2] = []
        let steps = splineSteps
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            func knot(_ t: Double, _ a: Vec2, _ b: Vec2) -> Double { t + max(pow((b - a).length, 0.5), 1e-4) }
            let t0 = 0.0, t1 = knot(t0, p0, p1), t2 = knot(t1, p1, p2), t3 = knot(t2, p2, p3)
            for s in 0..<steps {
                let t = t1 + (t2 - t1) * Double(s) / Double(steps)
                let a1 = p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
                let a2 = p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
                let a3 = p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
                let b1 = a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
                let b2 = a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
                out.append(b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1)))
            }
        }
        return out
    }

    /// Resamples a closed polyline at uniform arc-length spacing. `denseIndex` is each sample's
    /// position on the input polyline (segment index plus fraction).
    static func resample(_ poly: [Vec2], spacing: Double) -> (points: [Vec2], length: Double, denseIndex: [Double]) {
        let n = poly.count
        var total = 0.0
        for i in 0..<n { total += poly[i].distance(to: poly[(i + 1) % n]) }
        let count = max(8, Int((total / spacing).rounded()))
        let step = total / Double(count)
        var out: [Vec2] = []
        out.reserveCapacity(count)
        var positions: [Double] = []
        positions.reserveCapacity(count)
        var seg = 0
        var segStart = 0.0
        var segLen = poly[0].distance(to: poly[1 % n])
        for k in 0..<count {
            let target = Double(k) * step
            while segStart + segLen < target && seg < n - 1 {
                segStart += segLen
                seg += 1
                segLen = poly[seg].distance(to: poly[(seg + 1) % n])
            }
            let t = segLen > 0 ? (target - segStart) / segLen : 0
            let a = poly[seg], b = poly[(seg + 1) % n]
            out.append(a + (b - a) * t)
            positions.append(Double(seg) + clamp(t, 0, 1))
        }
        return (out, total, positions)
    }

    static func rasterize(def: TrackDefinition, path: [Vec2], halfWidths: [Double], bridges: [Bridge],
                          structure: (bridge: [Int8], along: [Float], lateral: [Float])) -> (surfaces: [Surface], distance: [Float], nearest: [Int32]) {
        let w = def.width, h = def.height
        let maxHalf = halfWidths.max() ?? def.roadWidth / 2
        let barrierOuter = def.barrierDistance.map { maxHalf + $0 + def.barrierThickness } ?? 0
        let reach = max(maxHalf + 60, barrierOuter + 2)
        let reach2 = reach * reach
        // With a constant width the nearest sample decides everything, so squared distance is
        // enough. With varying widths the sample whose road edge is closest wins (distance minus
        // its half width), so a wide stretch isn't cut short by a narrow one next to it.
        let varying = halfWidths.contains { $0 != halfWidths.first }

        var key = [Double](repeating: .infinity, count: w * h)
        var nearest = [Int32](repeating: -1, count: w * h)

        // Stamp discs along the centerline, keeping the best key per cell.
        for (si, s) in path.enumerated() {
            let hs = halfWidths[si]
            let y0 = max(0, Int(floor(s.y - reach))), y1 = min(h - 1, Int(ceil(s.y + reach)))
            guard y0 <= y1 else { continue }
            for y in y0...y1 {
                let dy = Double(y) + 0.5 - s.y
                let rem = reach2 - dy * dy
                if rem < 0 { continue }
                let span = rem.squareRoot()
                let x0 = max(0, Int(floor(s.x - span))), x1 = min(w - 1, Int(ceil(s.x + span)))
                guard x0 <= x1 else { continue }
                let row = y * w
                for x in x0...x1 {
                    let dx = Double(x) + 0.5 - s.x
                    let d2 = dx * dx + dy * dy
                    let k = varying ? d2.squareRoot() - hs : d2
                    if k < key[row + x] {
                        key[row + x] = k
                        nearest[row + x] = Int32(si)
                    }
                }
            }
        }

        var surfaces = [Surface](repeating: def.background, count: w * h)
        var distance = [Float](repeating: .infinity, count: w * h)
        let constantHalf = halfWidths.first ?? def.roadWidth / 2
        for i in 0..<(w * h) {
            let s = Int(nearest[i])
            guard s >= 0 else { continue }
            let half = varying ? halfWidths[s] : constantHalf
            // Distance to the chosen sample, and how far past its road edge the cell is.
            let d = varying ? key[i] + half : key[i].squareRoot()
            let e = d - half
            distance[i] = Float(d)
            if e <= 0 {
                surfaces[i] = .asphalt
            } else if e <= curbWidth {
                surfaces[i] = .curb
            } else if let bd = def.barrierDistance, e >= bd, e <= bd + def.barrierThickness {
                surfaces[i] = .wall
            }
        }

        for (pi, patch) in def.patches.enumerated() {
            let ragged = patch.surface == .sand ? RaggedEdge(shape: patch.shape, salt: pi &* 7919 &+ 17) : nil
            let b = patch.shape.bounds
            let grow = ragged.map { Int(ceil($0.reach)) } ?? 0
            // Patches may hang off the map (or lie entirely outside it) while editing.
            let x0 = max(0, b.minX - grow), x1 = min(w - 1, b.maxX + grow)
            let y0 = max(0, b.minY - grow), y1 = min(h - 1, b.maxY + grow)
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let i = y * w + x
                    if !patch.coversRoad && (surfaces[i] == .asphalt || surfaces[i] == .curb) { continue }
                    let p = Vec2(Double(x) + 0.5, Double(y) + 0.5)
                    let covered = ragged?.covers(p, x: x, y: y) ?? patch.shape.contains(p)
                    if covered { surfaces[i] = patch.surface }
                }
            }
        }

        carveBridges(bridges, def: def, path: path, halfWidths: halfWidths, structure: structure, surfaces: &surfaces)

        // The screen edge is always a wall, like the original.
        let border = 3
        for y in 0..<h {
            for x in 0..<w where x < border || y < border || x >= w - border || y >= h - border {
                surfaces[y * w + x] = .wall
            }
        }
        return (surfaces, distance, nearest)
    }
}
