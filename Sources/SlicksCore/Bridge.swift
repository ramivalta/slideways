import Foundation

/// One end of a bridge deck, in race direction: `back` is where cars drive onto it, `ahead`
/// where they drive off.
public enum BridgeEnd: CaseIterable, Sendable {
    case back, ahead

    /// Direction along the upper road, in samples.
    public var sign: Int { self == .back ? -1 : 1 }
}

/// Authoring format: where the road crosses itself, one pass goes over on a bridge. A deck can
/// be stretched along its road to carry it over several other roads.
public struct BridgeDefinition: Codable, Sendable, Equatable {
    /// Index into `TrackDefinition.controlPoints` the deck is built around. The pass through
    /// this control point is the upper road; every other road under the deck goes under.
    public var controlPoint: Int
    /// How far the deck reaches back from the control point (against the race direction).
    /// When nil it's sized to clear the roads underneath.
    public var back: Double?
    /// How far the deck reaches ahead of the control point. Nil sizes it automatically.
    public var ahead: Double?

    public init(controlPoint: Int, back: Double? = nil, ahead: Double? = nil) {
        self.controlPoint = controlPoint
        self.back = back
        self.ahead = ahead
    }

    /// A deck of fixed total length centered on the control point, or automatic with nil.
    public init(controlPoint: Int, length: Double?) {
        self.init(controlPoint: controlPoint, back: length.map { $0 / 2 }, ahead: length.map { $0 / 2 })
    }

    public func extent(_ end: BridgeEnd) -> Double? {
        end == .back ? back : ahead
    }

    public mutating func setExtent(_ value: Double?, _ end: BridgeEnd) {
        if end == .back { back = value } else { ahead = value }
    }

    private enum CodingKeys: String, CodingKey {
        case controlPoint, back, ahead
        /// Symmetric deck length, written by earlier versions.
        case length
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        controlPoint = try c.decode(Int.self, forKey: .controlPoint)
        back = try c.decodeIfPresent(Double.self, forKey: .back)
        ahead = try c.decodeIfPresent(Double.self, forKey: .ahead)
        if back == nil, ahead == nil, let length = try c.decodeIfPresent(Double.self, forKey: .length) {
            back = length / 2
            ahead = length / 2
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(controlPoint, forKey: .controlPoint)
        try c.encodeIfPresent(back, forKey: .back)
        try c.encodeIfPresent(ahead, forKey: .ahead)
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
    /// An automatic end ran to the longest deck allowed without clearing the road below.
    public let reachedMaxLength: Bool
    /// Where a ramp comes down on another road (at most one spot per end).
    public let blockedRamps: [Vec2]

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
    public var structureRange: ClosedRange<Double> {
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

    /// Longest an automatically sized deck end reaches from its control point.
    static let maxAutoDeckEnd = 260.0

    /// The roads around one bridge's upper road, for sizing its deck: which cross-sections of
    /// the upper road are clear of every other road, for the deck and for the ramps.
    struct BridgeClearance {
        let path: [Vec2]
        let tangents: [Vec2]
        let centerSample: Int
        let halfWidth: Double
        let curbWidth: Double
        let rampSamples: Int
        /// Samples of every other pass near the bridge, with the half width of their asphalt
        /// and curbs, and whether that pass is up on another bridge's deck there.
        let lower: [(index: Int, point: Vec2, edge: Double, raised: Bool)]
        /// Along the loop, samples this close to a ramp section are the ramp's own road, even
        /// past the structure (a hairpin can't fold back tighter than this).
        let ownRoadGap: Int

        /// `reach` is the farthest the structure (deck plus ramp) may reach from the center.
        /// `raised` marks samples on other bridges' decks: a ramp can run out under those.
        init(path: [Vec2], tangents: [Vec2], halfWidths: [Double], centerSample ci: Int, halfWidth: Double, curbWidth: Double,
             reach: Double, step: Double, raised: [Bool] = []) {
            let n = path.count
            self.path = path
            self.tangents = tangents
            centerSample = ci
            self.halfWidth = halfWidth
            self.curbWidth = curbWidth
            rampSamples = Int((bridgeRampLength / step).rounded(.up))
            // Everything far enough along the loop from here is another pass. The upper road's
            // own samples within the structure are excluded.
            let exclude = Int((reach / step).rounded(.up)) + rampSamples + 8
            let center = path[ci]
            let radius = reach + bridgeRampLength + 60
            lower = (0..<n).filter { j in
                let d = abs(j - ci) % n
                return min(d, n - d) > exclude && (path[j] - center).length < radius
            }.map { (index: $0, point: path[$0], edge: halfWidths[$0] + curbWidth, raised: raised.indices.contains($0) && raised[$0]) }
            ownRoadGap = Int(((halfWidth * 2 + 60) / step).rounded(.up))
        }

        func sample(_ k: Int) -> Int {
            let n = path.count
            return ((centerSample + k) % n + n) % n
        }

        /// Whether the cross-section `k` samples from the center keeps `margin` clear of the
        /// edges of `roads`.
        func isClear(_ k: Int, margin: Double, of roads: [(index: Int, point: Vec2, edge: Double, raised: Bool)]) -> Bool {
            let i = sample(k)
            let p = path[i], nrm = tangents[i].perp
            var l = -halfWidth
            while l <= halfWidth + 0.01 {
                let q = p + nrm * l
                if roads.contains(where: { let c = $0.edge + margin; return ($0.point - q).lengthSquared < c * c }) { return false }
                l += 2
            }
            return true
        }

        /// A deck section needs room for the road below to pass with some clearance.
        func deckClear(_ k: Int) -> Bool { isClear(k, margin: bridgeMargin, of: lower) }

        /// First section of the ramp beyond a deck end at `k` (signed) whose walls would stand
        /// on another road's asphalt, as an offset past the end. Roads up on other decks (or
        /// high on their ramps) pass over it.
        func rampBlock(deckEnd k: Int, sign: Int) -> Int? {
            let n = path.count
            let ground = lower.filter { !$0.raised }
            guard !ground.isEmpty else { return nil }
            return (1...rampSamples).first { r in
                let i = sample(k + sign * r)
                let roads = ground.filter { let d = abs($0.index - i) % n; return min(d, n - d) > ownRoadGap }
                return !isClear(k + sign * r, margin: -curbWidth, of: roads)
            }
        }

        /// Shortest deck end, at least `from` samples out, whose section clears the roads
        /// below and whose ramp doesn't come down on another road. Nil past `limit`.
        func autoEnd(sign: Int, from: Int = 0, limit: Int, checkRamp: Bool = true) -> Int? {
            var k = from
            while k <= limit {
                guard let clear = (k...limit).first(where: { deckClear(sign * $0) }) else { return nil }
                guard checkRamp, let blocked = rampBlock(deckEnd: sign * clear, sign: sign) else { return clear }
                k = clear + blocked
            }
            return nil
        }
    }

    static func buildBridges(def: TrackDefinition, path: [Vec2], tangents: [Vec2], halfWidths: [Double],
                             controlSamples: [Int], step: Double) -> [Bridge] {
        let maxAuto = Int(maxAutoDeckEnd / step)
        let zoneExtension = 14.0
        let n = path.count
        let valid = def.bridges.filter { $0.controlPoint >= 0 && $0.controlPoint < controlSamples.count }

        /// Deck ends of a bridge in samples. The first pass sizes decks to clear the roads
        /// under them; the second also keeps ramps off roads on the ground, which needs to know
        /// where the other decks are.
        func ends(_ bd: BridgeDefinition, raised: [Bool]?) -> (back: Int, fwd: Int, maxed: Bool, blocked: [Vec2], clearance: BridgeClearance) {
            let ci = controlSamples[bd.controlPoint]
            let halfWidth = halfWidths[ci] + def.curbWidth + bridgeRailing
            let fixed = BridgeEnd.allCases.map { bd.extent($0).map { max(0, Int(($0 / step).rounded())) } }
            let longest = Double(max(maxAuto, fixed[0] ?? 0, fixed[1] ?? 0)) * step
            let clearance = BridgeClearance(path: path, tangents: tangents, halfWidths: halfWidths, centerSample: ci,
                                            halfWidth: halfWidth, curbWidth: def.curbWidth, reach: longest, step: step, raised: raised ?? [])
            var maxed = false
            var blocked: [Vec2] = []
            let ks = BridgeEnd.allCases.enumerated().map { e, end -> Int in
                if let k = fixed[e] {
                    if raised != nil, let r = clearance.rampBlock(deckEnd: end.sign * k, sign: end.sign) {
                        blocked.append(path[clearance.sample(end.sign * (k + r))])
                    }
                    return k
                }
                if let k = clearance.autoEnd(sign: end.sign, limit: maxAuto, checkRamp: raised != nil) { return k }
                maxed = true
                return maxAuto
            }
            return (ks[0], ks[1], maxed, blocked, clearance)
        }

        // Road up on a deck, or on the upper half of a ramp: another bridge's ramp can run out
        // under it.
        let halfRamp = Int((bridgeRampLength / 2 / step).rounded())
        var raised = [Bool](repeating: false, count: n)
        for bd in valid {
            let e = ends(bd, raised: nil), ci = controlSamples[bd.controlPoint]
            for k in -(e.back + halfRamp)...(e.fwd + halfRamp) { raised[((ci + k) % n + n) % n] = true }
        }

        return valid.map { bd in
            let ci = controlSamples[bd.controlPoint]
            // The upper road keeps the width it has at the crossing across the whole structure.
            let half = halfWidths[ci]
            let halfWidth = half + def.curbWidth + bridgeRailing
            let e = ends(bd, raised: raised)
            let back = e.back, fwd = e.fwd, reachedMax = e.maxed, blocked = e.blocked, clearance = e.clearance

            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for k in -back...fwd {
                let i = clearance.sample(k)
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
                          deckBounds: bounds, reachedMaxLength: reachedMax, blockedRamps: blocked)
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
                let p = path[i], pad = halfWidths[i] + def.curbWidth + 4
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
                surfaces[c] = e <= 0 ? .asphalt : e <= def.curbWidth ? .curb : .wall
            } else if b.rampDistance(along: a) != nil, l >= b.driveHalfWidth, l <= b.halfWidth {
                surfaces[c] = .wall
            }
        }
    }
}

// MARK: Crossings under bridges

public extension Track {
    /// Bridge (index into `bridges`) whose deck carries one road of the crossing over the
    /// other, if any. Long decks can cover several crossings.
    func bridge(covering x: RoadCrossing) -> Int? {
        bridges.indices.first { bi in
            let b = bridges[bi]
            let l = upperRoadLocal(bridge: b, point: x.point)
            return l.along > b.deckStart && l.along < b.deckEnd && l.lateral < 6
        }
    }

    /// How far one end of bridge `bi` has to reach from its control point to carry its road
    /// over crossing `x` too: past the road there, with the ramp landing clear of other roads.
    /// Nil when the crossing isn't on this bridge's road within `maxEnd`, is already on the
    /// deck, or can't be cleared within `maxEnd`.
    func extent(toCover x: RoadCrossing, bridge bi: Int, maxEnd: Double) -> (end: BridgeEnd, length: Double)? {
        guard bridges.indices.contains(bi) else { return nil }
        let b = bridges[bi]
        let n = sampleCount, step = length / Double(n)
        let maxK = min(Int(maxEnd / step), n / 2 - 1)
        guard maxK > 0 else { return nil }
        // Where the upper road runs through the crossing.
        var bestK = 0, bestD = Double.infinity
        for k in -maxK...maxK {
            let d = (path[((b.centerSample + k) % n + n) % n] - x.point).lengthSquared
            if d < bestD { bestD = d; bestK = k }
        }
        guard bestD < 36 else { return nil }
        let along = Double(bestK) * step
        guard along < b.deckStart || along > b.deckEnd else { return nil }
        let end: BridgeEnd = bestK < 0 ? .back : .ahead
        var raised = [Bool](repeating: false, count: n)
        // Same rule as when the decks were built: roads on other decks and the upper half of
        // their ramps pass over this one's ramp.
        for (j, o) in bridges.enumerated() where j != bi {
            let k0 = Int(((o.deckStart - o.rampLength / 2) / step).rounded()), k1 = Int(((o.deckEnd + o.rampLength / 2) / step).rounded())
            for k in k0...k1 { raised[((o.centerSample + k) % n + n) % n] = true }
        }
        let clearance = BridgeClearance(path: path, tangents: tangents, halfWidths: halfWidths, centerSample: b.centerSample,
                                        halfWidth: b.halfWidth, curbWidth: definition.curbWidth,
                                        reach: Double(maxK) * step, step: step, raised: raised)
        guard let k = clearance.autoEnd(sign: end.sign, from: abs(bestK), limit: maxK) else { return nil }
        return (end, Double(k) * step)
    }
}
