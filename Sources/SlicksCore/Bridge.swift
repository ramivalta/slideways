import Foundation

/// Authoring format: where the road crosses itself, one pass goes over on a bridge.
public struct BridgeDefinition: Codable, Sendable, Equatable {
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

/// Inclusive-exclusive cell rectangle.
public struct CellBounds: Sendable {
    public let minX: Int, minY: Int, maxX: Int, maxY: Int
    public var width: Int { maxX - minX }
    public var height: Int { maxY - minY }
}

/// A built bridge: a stretch of the upper road lifted onto a deck, following the road's curve.
///
/// Positions near a bridge are described by `along` (distance along the upper road's centerline,
/// measured from `centerSample`, positive in race direction) and `lateral` (unsigned distance
/// from that centerline). The deck covers `deckStart...deckEnd`; a walled ramp of `rampLength`
/// runs down from each end. Cars entering the zone through the ends go on the deck (level 1);
/// cars entering from the sides go under it (level 0). The level sticks until the car leaves.
public struct Bridge: Sendable {
    /// The `BridgeDefinition.controlPoint` this bridge was built from.
    public let controlPoint: Int
    public let centerSample: Int
    /// Deck extent along the upper road, relative to `centerSample` (deckStart < 0 < deckEnd).
    public let deckStart: Double
    public let deckEnd: Double
    /// Half width of the upper road's asphalt, constant along the whole structure.
    public let roadHalf: Double
    public let halfWidth: Double
    public let railing: Double
    /// Length of the walled ramp beyond each end of the deck.
    public let rampLength: Double
    /// How far past each deck end a car keeps its level, so it doesn't pop under the deck while
    /// its tail is still on it.
    public let zoneExtension: Double
    /// Samples within this many indices of `centerSample` belong to the upper pass.
    public let upperHalfSpan: Int
    /// Cells covered by the deck.
    public let deckBounds: CellBounds

    /// Half width a car on the deck can use before touching the railing.
    public var driveHalfWidth: Double { halfWidth - railing }

    public func isDeck(along a: Double, lateral l: Double) -> Bool {
        a >= deckStart && a <= deckEnd && l <= halfWidth
    }

    public func isZone(along a: Double, lateral l: Double) -> Bool {
        a >= deckStart - zoneExtension && a <= deckEnd + zoneExtension && l <= halfWidth
    }

    /// Distance down a ramp from the deck end (0 = at the deck), or nil off the ramps.
    public func rampDistance(along a: Double) -> Double? {
        if a > deckEnd, a <= deckEnd + rampLength { return a - deckEnd }
        if a < deckStart, a >= deckStart - rampLength { return deckStart - a }
        return nil
    }

    /// Structure height: 1 on the deck, easing to 0 at the bottom of each ramp.
    public func height(along a: Double) -> Double? {
        if a >= deckStart, a <= deckEnd { return 1 }
        return rampDistance(along: a).map { 1 - $0 / rampLength }
    }

    /// Along range covered by deck, ramps and zone.
    var structureRange: ClosedRange<Double> {
        (deckStart - max(rampLength, zoneExtension))...(deckEnd + max(rampLength, zoneExtension))
    }
}

extension Track {
    static let bridgeRailing = 7.0
    static let bridgeRampLength = 100.0
    /// Clearance between the deck ends and the edge of the road underneath.
    static let bridgeMargin = 12.0

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

    static func buildBridges(def: TrackDefinition, path: [Vec2], tangents: [Vec2], halfWidths: [Double],
                             controlSamples: [Int], step: Double) -> [Bridge] {
        let n = path.count
        let maxDeck = Int(260 / step)
        let rampSamples = Int((bridgeRampLength / step).rounded(.up))
        let zoneExtension = 14.0
        func wrap(_ i: Int) -> Int { (i % n + n) % n }
        func indexGap(_ a: Int, _ b: Int) -> Int { let d = abs(a - b) % n; return min(d, n - d) }

        return def.bridges.compactMap { bd in
            guard bd.controlPoint >= 0, bd.controlPoint < controlSamples.count else { return nil }
            let ci = controlSamples[bd.controlPoint]
            let center = path[ci]
            // The upper road keeps the width it has at the crossing across the whole structure.
            let half = halfWidths[ci]
            let halfWidth = half + curbWidth + bridgeRailing

            // Other passes near the crossing: everything far enough along the loop from here,
            // each with the clearance its own road edge needs.
            let exclude = maxDeck + rampSamples + 8
            let lower = (0..<n).filter { indexGap($0, ci) > exclude && (path[$0] - center).length < 420 }
                .map { (point: path[$0], clearance: halfWidths[$0] + curbWidth + bridgeMargin) }

            // A cross-section of the upper road is clear when no point on it is near another pass.
            func isClear(_ i: Int) -> Bool {
                let p = path[i], nrm = tangents[i].perp
                var l = -halfWidth
                while l <= halfWidth + 0.01 {
                    let q = p + nrm * l
                    if lower.contains(where: { ($0.point - q).lengthSquared < $0.clearance * $0.clearance }) { return false }
                    l += 2
                }
                return true
            }
            func deckSamples(dir: Int) -> Int {
                if let length = bd.length { return Int((length / 2 / step).rounded()) }
                for k in 0...maxDeck where isClear(wrap(ci + dir * k)) { return k }
                return maxDeck
            }
            let back = deckSamples(dir: -1), fwd = deckSamples(dir: 1)

            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for k in -back...fwd {
                let i = wrap(ci + k)
                for side in [-1.0, 1.0] {
                    let q = path[i] + tangents[i].perp * (side * halfWidth)
                    minX = min(minX, q.x); maxX = max(maxX, q.x)
                    minY = min(minY, q.y); maxY = max(maxY, q.y)
                }
            }
            let bounds = CellBounds(minX: max(0, Int(floor(minX)) - 3), minY: max(0, Int(floor(minY)) - 3),
                                    maxX: min(def.width, Int(ceil(maxX)) + 3), maxY: min(def.height, Int(ceil(maxY)) + 3))
            let reach = Double(max(back, fwd)) * step + bridgeRampLength + zoneExtension + 8
            return Bridge(controlPoint: bd.controlPoint, centerSample: ci, deckStart: -Double(back) * step, deckEnd: Double(fwd) * step,
                          roadHalf: half, halfWidth: halfWidth, railing: bridgeRailing, rampLength: bridgeRampLength,
                          zoneExtension: zoneExtension, upperHalfSpan: Int((reach / step).rounded(.up)),
                          deckBounds: bounds)
        }
    }

    /// Holds the road width constant along each bridge's upper road (deck, ramps and zone) so
    /// the railings run straight, easing back to the designed width over `blend` samples.
    static func flattenWidths(_ halves: inout [Double], under bridges: [Bridge], blend: Int = 24) {
        let n = halves.count
        guard n > 0 else { return }
        let original = halves
        for b in bridges {
            let span = min(b.upperHalfSpan, n / 2)
            for k in -(span + blend)...(span + blend) {
                let i = ((b.centerSample + k) % n + n) % n
                let off = abs(k) - span
                if off <= 0 {
                    halves[i] = b.roadHalf
                } else {
                    let t = Double(off) / Double(blend)
                    halves[i] = b.roadHalf + (original[i] - b.roadHalf) * t * t * (3 - 2 * t)
                }
            }
        }
    }

    /// Per-cell position relative to each bridge's upper road, for cells within the structure
    /// (deck, ramps and zone, out to the railing plus one cell).
    static func buildStructure(_ bridges: [Bridge], path: [Vec2], tangents: [Vec2], step: Double,
                               width w: Int, height h: Int) -> (bridge: [Int8], along: [Float], lateral: [Float]) {
        guard !bridges.isEmpty else { return ([], [], []) }
        let n = path.count
        var index = [Int8](repeating: -1, count: w * h)
        var along = [Float](repeating: 0, count: w * h)
        var lateral = [Float](repeating: .infinity, count: w * h)
        var best = [Double](repeating: .infinity, count: w * h)
        // 0 = deck, 1 = ramp or zone. When two bridges' structures overlap (one bridge's ramp
        // running out under another's deck), the deck wins so it has no holes.
        var rank = [UInt8](repeating: .max, count: w * h)
        // Per-bridge scratch: each bridge first finds its own nearest upper-road sample per
        // cell, exactly as if it were the only bridge, and only then competes for the cell.
        var nearD2 = [Double](repeating: .infinity, count: w * h)
        var nearAlong = [Float](repeating: 0, count: w * h)
        var nearLateral = [Float](repeating: 0, count: w * h)
        var touched: [Int] = []
        for (bi, b) in bridges.enumerated() {
            let range = b.structureRange
            let r = b.halfWidth + 3
            let kMin = Int(floor(range.lowerBound / step)) - 1, kMax = Int(ceil(range.upperBound / step)) + 1
            touched.removeAll(keepingCapacity: true)
            for k in kMin...kMax {
                let i = ((b.centerSample + k) % n + n) % n
                let s = path[i], t = tangents[i], nrm = t.perp
                let x0 = max(0, Int(floor(s.x - r))), x1 = min(w - 1, Int(ceil(s.x + r)))
                let y0 = max(0, Int(floor(s.y - r))), y1 = min(h - 1, Int(ceil(s.y + r)))
                guard x0 <= x1, y0 <= y1 else { continue }
                for y in y0...y1 {
                    for x in x0...x1 {
                        let d = Vec2(Double(x) + 0.5, Double(y) + 0.5) - s
                        let d2 = d.lengthSquared
                        let c = y * w + x
                        guard d2 < nearD2[c], d2 <= r * r else { continue }
                        if nearD2[c] == .infinity { touched.append(c) }
                        nearD2[c] = d2
                        nearAlong[c] = Float(Double(k) * step + d.dot(t))
                        nearLateral[c] = Float(abs(d.dot(nrm)))
                    }
                }
            }
            for c in touched {
                let d2 = nearD2[c], a = Double(nearAlong[c]), l = Double(nearLateral[c])
                nearD2[c] = .infinity
                // Only cells that really are part of this bridge's structure compete, so a
                // bridge can't knock a hole in another bridge's deck.
                guard range.contains(a), l <= b.halfWidth + 1 else { continue }
                let cellRank: UInt8 = b.isDeck(along: a, lateral: l) ? 0 : 1
                guard index[c] < 0 || cellRank < rank[c] || (cellRank == rank[c] && d2 < best[c]) else { continue }
                best[c] = d2
                rank[c] = cellRank
                index[c] = Int8(bi)
                along[c] = Float(a)
                lateral[c] = Float(l)
            }
        }
        for c in 0..<(w * h) where index[c] >= 0 {
            let b = bridges[Int(index[c])]
            if !b.structureRange.contains(Double(along[c])) || Double(lateral[c]) > b.halfWidth + 1 {
                index[c] = -1
            }
        }
        return (index, along, lateral)
    }

    /// Carves the ground layer under and around each bridge: under the deck only the lower road
    /// stays open (the rest is abutment), and the ramps get walls so the two roads can't be
    /// swapped at the crossing.
    static func carveBridges(_ bridges: [Bridge], def: TrackDefinition, path: [Vec2], halfWidths: [Double],
                             structure: (bridge: [Int8], along: [Float], lateral: [Float]),
                             surfaces: inout [Surface]) {
        guard !bridges.isEmpty else { return }
        let w = def.width
        let n = path.count

        // Samples of the other passes near each deck, with their half widths.
        let lowers: [[(point: Vec2, half: Double)]] = bridges.map { b in
            let r = b.deckBounds
            return (0..<n).filter { i in
                var d = abs(i - b.centerSample) % n
                d = min(d, n - d)
                let p = path[i], pad = halfWidths[i] + curbWidth + 4
                return d > b.upperHalfSpan && p.x >= Double(r.minX) - pad && p.x <= Double(r.maxX) + pad
                    && p.y >= Double(r.minY) - pad && p.y <= Double(r.maxY) + pad
            }.map { (path[$0], halfWidths[$0]) }
        }

        for c in 0..<structure.bridge.count where structure.bridge[c] >= 0 {
            let bi = Int(structure.bridge[c])
            let b = bridges[bi]
            let a = Double(structure.along[c]), l = Double(structure.lateral[c])
            if b.isDeck(along: a, lateral: l) {
                // Same edge rule as the open road: the lower pass whose edge is nearest wins.
                let p = Vec2(Double(c % w) + 0.5, Double(c / w) + 0.5)
                var e = Double.infinity
                for q in lowers[bi] { e = min(e, (p - q.point).length - q.half) }
                surfaces[c] = e <= 0 ? .asphalt : e <= curbWidth ? .curb : .wall
            } else if b.rampDistance(along: a) != nil, l >= b.driveHalfWidth, l <= b.halfWidth {
                surfaces[c] = .wall
            }
        }
    }
}
