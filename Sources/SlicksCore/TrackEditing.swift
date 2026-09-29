import Foundation

// Editing operations on track definitions, used by the level editor. They keep bridge control
// point indices consistent as points are added, removed and reordered.

/// Where the centerline crosses itself.
public struct RoadCrossing: Sendable, Equatable {
    public var point: Vec2
    /// Positions of the two passes, in control point units (segment index plus fraction).
    public var passA: Double
    public var passB: Double
}

/// Something about a track that will make it race badly.
public struct TrackIssue: Sendable {
    public var message: String
    /// Where to point at on the map, if the issue has a location.
    public var position: Vec2?
}

public extension TrackDefinition {
    /// Fewest control points the spline can be built from.
    static let minControlPoints = 3

    /// A plain oval to start a new track from.
    static func blank(id: String, name: String = "New Track") -> TrackDefinition {
        let count = 10
        let points = (0..<count).map { k -> Vec2 in
            let a = -Double.pi / 2 + Double(k) / Double(count) * 2 * .pi
            return Vec2((480 + 360 * cos(a)).rounded(), (300 + 210 * sin(a)).rounded())
        }
        return TrackDefinition(id: id, name: name, controlPoints: points, barrierDistance: 22)
    }

    /// Keeps `pointWidths` the same length as `controlPoints`, or empty when no point sets a width.
    mutating func normalizeWidths() {
        guard hasPointWidths else { pointWidths = []; return }
        let n = controlPoints.count
        if pointWidths.count < n { pointWidths += [Double?](repeating: nil, count: n - pointWidths.count) }
        if pointWidths.count > n { pointWidths.removeLast(pointWidths.count - n) }
    }

    /// Sets (or with nil, clears) the road width at a control point.
    mutating func setRoadWidth(_ width: Double?, atPoint i: Int) {
        guard controlPoints.indices.contains(i) else { return }
        pointWidths += [Double?](repeating: nil, count: max(0, controlPoints.count - pointWidths.count))
        pointWidths[i] = width
        normalizeWidths()
    }

    /// Inserts a control point so it becomes index `index`. Indices at or after it shift up.
    /// Between points with their own widths, the new point takes the width the road already
    /// has there so nothing bulges.
    mutating func insertControlPoint(_ p: Vec2, at index: Int) {
        let i = clamp(index, 0, controlPoints.count)
        if hasPointWidths {
            normalizeWidths()
            let n = controlPoints.count
            let a = (i - 1 + n) % n, b = i % n
            let w: Double? = pointWidths[a] == nil && pointWidths[b] == nil
                ? nil : (roadWidth(atPoint: a) + roadWidth(atPoint: b)) / 2
            pointWidths.insert(w, at: i)
        }
        controlPoints.insert(p, at: i)
        for k in bridges.indices where bridges[k].controlPoint >= i { bridges[k].controlPoint += 1 }
    }

    /// Removes a control point and any bridge built on it. Returns false if the road would
    /// get too short to build.
    @discardableResult
    mutating func removeControlPoint(at index: Int) -> Bool {
        guard controlPoints.indices.contains(index), controlPoints.count > Self.minControlPoints else { return false }
        controlPoints.remove(at: index)
        if pointWidths.indices.contains(index) { pointWidths.remove(at: index) }
        normalizeWidths()
        bridges.removeAll { $0.controlPoint == index }
        for k in bridges.indices where bridges[k].controlPoint > index { bridges[k].controlPoint -= 1 }
        return true
    }

    /// Makes `index` the start/finish control point, keeping the race direction.
    mutating func makeStart(_ index: Int) {
        let n = controlPoints.count
        guard index > 0, index < n else { return }
        controlPoints = Array(controlPoints[index...] + controlPoints[..<index])
        normalizeWidths()
        if !pointWidths.isEmpty { pointWidths = Array(pointWidths[index...] + pointWidths[..<index]) }
        for k in bridges.indices { bridges[k].controlPoint = (bridges[k].controlPoint - index + n) % n }
    }

    /// Reverses the race direction. The start point stays where it is.
    mutating func reverseDirection() {
        let n = controlPoints.count
        guard n > 1 else { return }
        let old = controlPoints
        controlPoints = (0..<n).map { old[(n - $0) % n] }
        normalizeWidths()
        if !pointWidths.isEmpty {
            let oldWidths = pointWidths
            pointWidths = (0..<n).map { oldWidths[(n - $0) % n] }
        }
        for k in bridges.indices { bridges[k].controlPoint = (n - bridges[k].controlPoint) % n }
    }

    /// Index a new control point at `p` should be inserted at: on the stretch of road under
    /// `p` if it's on or next to the road, otherwise between the two points it bends the
    /// road the least between.
    func insertionIndex(for p: Vec2) -> Int {
        let n = controlPoints.count
        guard n >= 2 else { return n }
        let dense = Track.centerline(through: controlPoints)
        var best = 0, bestD = Double.infinity
        for (i, q) in dense.enumerated() {
            let d = (q - p).lengthSquared
            if d < bestD { bestD = d; best = i }
        }
        let widths = centerlineWidths()
        let halfHere = widths.indices.contains(best) ? widths[best] / 2 : roadWidth / 2
        if bestD.squareRoot() < halfHere + 16 {
            return best / Track.splineSteps + 1
        }
        var seg = 0, cost = Double.infinity
        for i in 0..<n {
            let a = controlPoints[i], b = controlPoints[(i + 1) % n]
            let c = p.distance(to: a) + p.distance(to: b) - a.distance(to: b)
            if c < cost { cost = c; seg = i }
        }
        return seg + 1
    }

    /// Distance between two positions along the loop, in control point units.
    func loopDistance(_ a: Double, _ b: Double) -> Double {
        let n = Double(controlPoints.count)
        let d = abs(a - b).truncatingRemainder(dividingBy: n)
        return min(d, n - d)
    }

    /// Every place the centerline crosses itself.
    func crossings() -> [RoadCrossing] {
        let dense = Track.centerline(through: controlPoints)
        let n = dense.count
        guard n > 8 else { return [] }
        let minGap = Track.splineSteps / 4
        let steps = Double(Track.splineSteps)
        var found: [RoadCrossing] = []
        for i in 0..<n {
            let a = dense[i], b = dense[(i + 1) % n], r = b - a
            let aMinX = min(a.x, b.x), aMaxX = max(a.x, b.x), aMinY = min(a.y, b.y), aMaxY = max(a.y, b.y)
            for j in stride(from: i + minGap, to: n, by: 1) where n - (j - i) >= minGap {
                let c = dense[j], d = dense[(j + 1) % n]
                if max(c.x, d.x) < aMinX || min(c.x, d.x) > aMaxX || max(c.y, d.y) < aMinY || min(c.y, d.y) > aMaxY { continue }
                let s = d - c
                let denom = r.cross(s)
                guard abs(denom) > 1e-9 else { continue }
                let t = (c - a).cross(s) / denom, u = (c - a).cross(r) / denom
                guard t >= 0, t < 1, u >= 0, u < 1 else { continue }
                let p = a + r * t
                // Passes meeting exactly at a shared control point can register on two segments.
                if found.contains(where: { ($0.point - p).length < 6 }) { continue }
                found.append(RoadCrossing(point: p, passA: (Double(i) + t) / steps, passB: (Double(j) + u) / steps))
            }
        }
        return found
    }

    /// Bridge (index into `bridges`) sitting on a crossing, if any.
    func bridgeIndex(at crossing: RoadCrossing, tolerance: Double = 24) -> Int? {
        bridges.indices.first { k in
            let c = bridges[k].controlPoint
            return controlPoints.indices.contains(c) && controlPoints[c].distance(to: crossing.point) < tolerance
        }
    }

    /// Control point on the given pass at the crossing, inserting one exactly at the crossing
    /// if none is close.
    mutating func controlPoint(at crossing: RoadCrossing, pass: Double) -> Int {
        let n = controlPoints.count
        let seg = Int(floor(pass)) % n
        for c in [seg, (seg + 1) % n] where controlPoints[c].distance(to: crossing.point) < 8 { return c }
        insertControlPoint(crossing.point, at: seg + 1)
        return seg + 1
    }

    /// Adds a bridge at a crossing carrying `pass` over the other road. Returns its index.
    @discardableResult
    mutating func addBridge(at crossing: RoadCrossing, over pass: Double) -> Int {
        if let k = bridgeIndex(at: crossing) { return k }
        let c = controlPoint(at: crossing, pass: pass)
        bridges.append(BridgeDefinition(controlPoint: c))
        return bridges.count - 1
    }

    /// Swaps which road of a crossing goes over on bridge `k`.
    mutating func flipBridge(_ k: Int, at crossing: RoadCrossing) {
        guard bridges.indices.contains(k) else { return }
        let current = Double(bridges[k].controlPoint)
        let other = loopDistance(current, crossing.passA) < loopDistance(current, crossing.passB) ? crossing.passB : crossing.passA
        let c = controlPoint(at: crossing, pass: other)
        bridges[k].controlPoint = c
    }

    /// Crossing a bridge sits on, if it's on one.
    func crossing(forBridge k: Int, in list: [RoadCrossing]) -> RoadCrossing? {
        guard bridges.indices.contains(k), controlPoints.indices.contains(bridges[k].controlPoint) else { return nil }
        let p = controlPoints[bridges[k].controlPoint]
        return list.filter { $0.point.distance(to: p) < 24 }.min { $0.point.distance(to: p) < $1.point.distance(to: p) }
    }
}

// MARK: Patch shapes

public enum PatchShapeKind: String, CaseIterable, Sendable {
    case circle, rect, capsule
}

public extension PatchShape {
    var kind: PatchShapeKind {
        switch self {
        case .circle: .circle
        case .rect: .rect
        case .capsule: .capsule
        }
    }

    var center: Vec2 {
        switch self {
        case let .circle(c, _): c
        case let .rect(o, s): o + s * 0.5
        case let .capsule(a, b, _): (a + b) * 0.5
        }
    }

    func translated(by d: Vec2) -> PatchShape {
        switch self {
        case let .circle(c, r): .circle(center: c + d, radius: r)
        case let .rect(o, s): .rect(origin: o + d, size: s)
        case let .capsule(a, b, r): .capsule(from: a + d, to: b + d, radius: r)
        }
    }

    /// Distance from `p` to the shape's edge, zero or negative inside.
    func distance(to p: Vec2) -> Double {
        switch self {
        case let .circle(c, r):
            return (p - c).length - r
        case let .rect(o, s):
            let h = s * 0.5, q = p - (o + h)
            let dx = abs(q.x) - h.x, dy = abs(q.y) - h.y
            return Vec2(max(dx, 0), max(dy, 0)).length + min(max(dx, dy), 0)
        case let .capsule(a, b, r):
            let ab = b - a
            let t = clamp((p - a).dot(ab) / max(ab.lengthSquared, 1e-9), 0, 1)
            return (p - (a + ab * t)).length - r
        }
    }

    /// The same area roughly, as another kind of shape.
    func converted(to kind: PatchShapeKind) -> PatchShape {
        guard kind != self.kind else { return self }
        let c = center
        let extent: Vec2
        switch self {
        case let .circle(_, r): extent = Vec2(r, r)
        case let .rect(_, s): extent = s * 0.5
        case let .capsule(a, b, r): extent = Vec2(abs(b.x - a.x) / 2 + r, abs(b.y - a.y) / 2 + r)
        }
        switch kind {
        case .circle:
            return .circle(center: c, radius: max(4, (extent.x + extent.y) / 2))
        case .rect:
            return .rect(origin: c - extent, size: extent * 2)
        case .capsule:
            let r = max(3, min(extent.x, extent.y))
            let horizontal = extent.x >= extent.y
            let half = max(4, (horizontal ? extent.x : extent.y) - r)
            let d = horizontal ? Vec2(half, 0) : Vec2(0, half)
            return .capsule(from: c - d, to: c + d, radius: r)
        }
    }
}

// MARK: Validation

public extension Track {
    /// Problems that make the track unraceable or broken-looking.
    func issues() -> [TrackIssue] {
        var out: [TrackIssue] = []
        let n = sampleCount

        // Walls across the road, grouped into runs of consecutive samples.
        var run: [Int] = []
        func flush() {
            guard !run.isEmpty else { return }
            out.append(TrackIssue(message: "Road blocked by a wall", position: path[run[run.count / 2]]))
            run.removeAll()
        }
        for i in 0..<n {
            if surface(at: path[i], level: Int(sampleLevels[i])) == .wall {
                if let last = run.last, last != i - 1 { flush() }
                run.append(i)
            }
        }
        flush()

        let maxDeck = 260.0
        for b in bridges {
            let p = path[b.centerSample]
            let deck = b.deckEnd - b.deckStart
            if deck < 8 {
                out.append(TrackIssue(message: "Bridge doesn't cross another road", position: p))
            } else if definition.bridges.first(where: { $0.controlPoint == b.controlPoint })?.length == nil,
                      deck >= maxDeck - 2 * spacing {
                out.append(TrackIssue(message: "Bridge roads run side by side; cross more steeply", position: p))
            }
        }

        if gridSlots(count: 8).contains(where: { surface(at: $0.position) != .asphalt }) {
            out.append(TrackIssue(message: "Starting grid isn't all on asphalt", position: path[0]))
        }
        return out
    }
}
