import Foundation

/// Authoring format: where the road crosses itself, one pass goes over on a bridge.
public struct BridgeDefinition: Codable, Sendable {
    /// Index into `TrackDefinition.controlPoints` at the middle of the deck. The pass through this
    /// control point is the upper road; whichever other part of the track crosses there goes under.
    public var controlPoint: Int
    /// Deck length along the upper road. When nil it's sized to span the road underneath.
    public var length: Double?

    public init(controlPoint: Int, length: Double? = nil) {
        self.controlPoint = controlPoint
        self.length = length
    }
}

/// A built bridge: an oriented rectangle deck over the lower road.
///
/// Local coordinates: `u` runs along the upper road (deck axis), `v` across it.
/// Cars entering the zone through the ends go on the deck (level 1); cars entering from the
/// sides go under it (level 0). The level sticks until the car leaves the zone.
public struct Bridge: Sendable {
    public let center: Vec2
    /// Unit vector along the deck, in the upper road's direction of travel.
    public let axis: Vec2
    /// Unit vector across the deck.
    public let side: Vec2
    public let halfLength: Double
    public let halfWidth: Double
    public let railing: Double
    /// Length of the walled ramp approach beyond each end of the deck, measured along the road.
    public let rampLength: Double
    /// Ramp length in centerline samples.
    public let rampSamples: Int
    /// First centerline sample past the deck's far end (ramp going down, in race direction).
    public let forwardRampStart: Int
    /// First centerline sample before the deck's near end (ramp coming up).
    public let backwardRampStart: Int
    /// How far past each deck end a car keeps its level, so it doesn't pop under the deck while
    /// its tail is still on it.
    public let zoneExtension: Double
    public let centerSample: Int
    /// Samples within this many indices of `centerSample` belong to the upper pass.
    public let upperHalfSpan: Int

    /// Half width a car on the deck can use before touching the railing.
    public var driveHalfWidth: Double { halfWidth - railing }

    public func local(_ p: Vec2) -> (u: Double, v: Double) {
        let d = p - center
        return (d.dot(axis), d.dot(side))
    }

    public func isOnDeck(_ p: Vec2) -> Bool {
        let (u, v) = local(p)
        return abs(u) <= halfLength && abs(v) <= halfWidth
    }

    public func isInZone(_ p: Vec2) -> Bool {
        let (u, v) = local(p)
        return abs(u) <= halfLength + zoneExtension && abs(v) <= halfWidth
    }

    /// Steps down a ramp from the deck end (0 = at the deck) for a centerline sample, or nil if
    /// the sample isn't on one of this bridge's ramps.
    public func rampStep(sample i: Int, count n: Int) -> Int? {
        let f = ((i - forwardRampStart) % n + n) % n
        if f <= rampSamples { return f }
        let b = ((backwardRampStart - i) % n + n) % n
        if b <= rampSamples { return b }
        return nil
    }

    /// Ramp height for a centerline sample: 1 where it meets the deck, 0 at ground level.
    public func rampHeight(sample i: Int, count n: Int) -> Double? {
        rampStep(sample: i, count: n).map { 1 - Double($0) / Double(max(rampSamples, 1)) }
    }

    /// The four deck corners, for bounds and rendering.
    public var corners: [Vec2] {
        [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { su, sv in
            center + axis * (su * halfLength) + side * (sv * halfWidth)
        }
    }
}

extension Track {
    static let bridgeRailing = 7.0
    static let bridgeRampLength = 100.0
    static let bridgeMargin = 20.0

    /// Sample index for each control point, following the spline's construction order so passes
    /// through a shared crossing point stay distinct.
    static func controlPointSamples(controlPoints: [Vec2], dense: [Vec2], sampleCount: Int, totalLength: Double) -> [Int] {
        let steps = dense.count / max(controlPoints.count, 1)
        var cumulative = 0.0
        var result: [Int] = []
        var k = 0
        for i in 0..<dense.count {
            if i == k * steps && k < controlPoints.count {
                result.append(Int((cumulative / totalLength * Double(sampleCount)).rounded()) % sampleCount)
                k += 1
            }
            cumulative += dense[i].distance(to: dense[(i + 1) % dense.count])
        }
        return result
    }

    static func buildBridges(def: TrackDefinition, path: [Vec2], tangents: [Vec2], controlSamples: [Int], spacing: Double) -> [Bridge] {
        let n = path.count
        let half = def.roadWidth / 2
        let edge = half + curbWidth
        let halfWidth = edge + bridgeRailing
        return def.bridges.compactMap { bd in
            guard bd.controlPoint >= 0, bd.controlPoint < controlSamples.count else { return nil }
            let ci = controlSamples[bd.controlPoint]
            let center = path[ci]
            let axis = tangents[ci]

            // Find the lower pass: the nearest sample well away from the upper pass in index.
            let exclude = Int((def.roadWidth * 3) / spacing)
            var best = -1
            var bestD = Double.infinity
            for i in 0..<n {
                var d = abs(i - ci) % n
                d = min(d, n - d)
                guard d > exclude else { continue }
                let dist = (path[i] - center).lengthSquared
                if dist < bestD { bestD = dist; best = i }
            }
            var halfLength = bd.length.map { $0 / 2 } ?? (edge + bridgeMargin)
            if best >= 0, bd.length == nil {
                let t = tangents[best]
                let sinA = max(abs(axis.cross(t)), 0.5)
                let cotA = abs(axis.dot(t)) / sinA
                halfLength = edge / sinA + halfWidth * cotA + bridgeMargin
            }
            let span = Int((halfLength + bridgeRampLength + 60) / spacing)

            // Walk along the upper pass to where it leaves the deck at each end.
            func deckExit(step: Int) -> Int {
                var i = ci
                for _ in 0..<span {
                    let u = (path[i] - center).dot(axis)
                    if abs(u) > halfLength { return i }
                    i = ((i + step) % n + n) % n
                }
                return i
            }
            return Bridge(center: center, axis: axis, side: axis.perp, halfLength: halfLength, halfWidth: halfWidth,
                          railing: bridgeRailing, rampLength: bridgeRampLength,
                          rampSamples: Int(bridgeRampLength / spacing),
                          forwardRampStart: deckExit(step: 1), backwardRampStart: deckExit(step: -1),
                          zoneExtension: 14, centerSample: ci, upperHalfSpan: span)
        }
    }

    /// Carves the ground layer under and around each bridge: under the deck only the lower road
    /// stays open (the rest is abutment), and the ramps get walls so the two roads can't be
    /// swapped at the crossing.
    static func carveBridges(_ bridges: [Bridge], def: TrackDefinition, path: [Vec2], distance: [Float],
                             nearest: [Int32], surfaces: inout [Surface]) {
        let w = def.width, h = def.height
        let half = def.roadWidth / 2
        let edge = half + curbWidth
        let n = path.count
        for b in bridges {
            // Ramp side walls: follow the road, whichever way it curves.
            for i in 0..<(w * h) {
                let s = Int(nearest[i])
                guard s >= 0, b.rampStep(sample: s, count: n) != nil else { continue }
                let d = Double(distance[i])
                guard d >= b.driveHalfWidth, d <= b.halfWidth + 1 else { continue }
                let p = Vec2(Double(i % w) + 0.5, Double(i / w) + 0.5)
                if !b.isOnDeck(p) { surfaces[i] = .wall }
            }

            let reachU = b.halfLength
            let reachV = b.halfWidth + 2
            let ext = [(-reachU, -reachV), (reachU, -reachV), (reachU, reachV), (-reachU, reachV)].map { b.center + b.axis * $0.0 + b.side * $0.1 }
            let minX = max(0, Int(floor(ext.map(\.x).min()!))), maxX = min(w - 1, Int(ceil(ext.map(\.x).max()!)))
            let minY = max(0, Int(floor(ext.map(\.y).min()!))), maxY = min(h - 1, Int(ceil(ext.map(\.y).max()!)))
            guard minX <= maxX, minY <= maxY else { continue }

            // Lower-road samples near this bridge.
            let pad = edge + 4
            let lower = (0..<n).filter { i in
                var d = abs(i - b.centerSample) % n
                d = min(d, n - d)
                let p = path[i]
                return d > b.upperHalfSpan && p.x >= Double(minX) - pad && p.x <= Double(maxX) + pad
                    && p.y >= Double(minY) - pad && p.y <= Double(maxY) + pad
            }.map { path[$0] }

            func lowerDistance(_ p: Vec2) -> Double {
                var best = Double.infinity
                for q in lower { best = min(best, (p - q).lengthSquared) }
                return best.squareRoot()
            }

            for y in minY...maxY {
                for x in minX...maxX {
                    let p = Vec2(Double(x) + 0.5, Double(y) + 0.5)
                    let (u, v) = b.local(p)
                    let au = abs(u), av = abs(v)
                    let i = y * w + x
                    if au <= b.halfLength && av <= b.halfWidth {
                        let d = lowerDistance(p)
                        surfaces[i] = d <= half ? .asphalt : d <= edge ? .curb : .wall
                    }
                }
            }
        }
    }
}
