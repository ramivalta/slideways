import Foundation

// Things placed on a track besides the road and surface patches: paint lines, trees and
// buildings.

/// Paint on the ground: a polyline drawn over whatever surface is under it. Purely visual.
public struct PaintLine: Codable, Sendable, Equatable {
    public var points: [Vec2]
    public var width: Double
    public var color: PaintColor

    public init(points: [Vec2], width: Double = 2, color: PaintColor = .white) {
        self.points = points
        self.width = width
        self.color = color
    }

    /// Distance from `p` to the line's centerline.
    public func distance(to p: Vec2) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return first.distance(to: p) }
        var best = Double.infinity
        for k in 0..<(points.count - 1) {
            best = min(best, segmentDistance(p, points[k], points[k + 1]))
        }
        return best
    }

    public func translated(by d: Vec2) -> PaintLine {
        var l = self
        l.points = points.map { $0 + d }
        return l
    }
}

public enum PaintColor: String, Codable, Sendable, CaseIterable {
    case white, yellow, red, blue, black
}

public enum TrackObjectKind: String, Codable, Sendable, CaseIterable {
    /// Round leafy tree.
    case tree
    case pine
    case palm
    case grandstand
    case pitBuilding
    /// Jump ramp: low at the front (local -y), rising to a lip at the back (local +y).
    case ramp
    /// Moored boat, bow at local +x.
    case boat
    /// Pedestrian bridge spanning the road along local x. Cars drive under it.
    case footbridge

    public var isTree: Bool {
        switch self {
        case .tree, .pine, .palm: true
        case .grandstand, .pitBuilding, .ramp, .boat, .footbridge: false
        }
    }

    public var isBuilding: Bool { self == .grandstand || self == .pitBuilding }
    public var isRamp: Bool { self == .ramp }
}

/// A tree, building, boat, footbridge or ramp on the map. Buildings and boats are always solid;
/// trees are solid only when `solid` is set, otherwise cars drive under their canopy. Ramps are
/// driven over and footbridges driven under.
///
/// Trees are circles of diameter `size.x`. Buildings and ramps are rectangles `size.x` long
/// and `size.y` deep, rotated by `angle`; their front (the seats of a grandstand, the garage
/// doors of a pit building, the low entry of a ramp) faces local -y.
public struct TrackObject: Codable, Sendable, Equatable {
    public var kind: TrackObjectKind
    public var position: Vec2
    public var size: Vec2
    /// Rotation in radians, counter-clockwise.
    public var angle: Double
    public var solid: Bool

    public init(_ kind: TrackObjectKind, at position: Vec2, size: Vec2? = nil, angle: Double = 0, solid: Bool = true) {
        self.kind = kind
        self.position = position
        self.size = size ?? kind.defaultSize
        self.angle = angle
        self.solid = solid
        if kind.isTree { self.size.y = self.size.x }
    }

    /// Whether cars crash into it.
    public var isSolid: Bool { kind.isBuilding || kind == .boat || (kind.isTree && solid) }

    /// Direction a ramp launches cars in: from its low front toward its lip.
    public var rampDirection: Vec2 { axes.v }

    /// Canopy radius for trees.
    public var radius: Double { size.x / 2 }

    /// Radius cars collide with on a solid tree: the trunk and lower branches. Cars slip under
    /// the outer leaves.
    public var trunkRadius: Double { max(2, radius * 0.6) }

    /// Unit vectors of the building's length and depth axes.
    public var axes: (u: Vec2, v: Vec2) {
        let u = Vec2(angle: angle)
        return (u, u.perp)
    }

    /// World position in building coordinates (x along the length, y across).
    public func local(_ p: Vec2) -> Vec2 {
        let d = p - position, (u, v) = axes
        return Vec2(d.dot(u), d.dot(v))
    }

    public func world(_ l: Vec2) -> Vec2 {
        let (u, v) = axes
        return position + u * l.x + v * l.y
    }

    /// Whether `p` is under the object as drawn (canopy or roof).
    public func covers(_ p: Vec2) -> Bool {
        if kind.isTree { return (p - position).lengthSquared <= radius * radius }
        let l = local(p)
        return abs(l.x) <= size.x / 2 && abs(l.y) <= size.y / 2
    }

    /// Whether `p` is inside the part cars crash into.
    public func blocks(_ p: Vec2) -> Bool {
        guard isSolid else { return false }
        if kind.isTree { return (p - position).lengthSquared <= trunkRadius * trunkRadius }
        return covers(p)
    }

    /// Building corners in local order (-x -y), (+x -y), (+x +y), (-x +y): counter-clockwise,
    /// starting at the left end of the front.
    public var corners: [Vec2] {
        let h = size * 0.5
        return [Vec2(-h.x, -h.y), Vec2(h.x, -h.y), Vec2(h.x, h.y), Vec2(-h.x, h.y)].map(world)
    }

    /// Integer cell bounds (inclusive) of the drawn footprint.
    public var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let r: Double
        if kind.isTree {
            r = radius
        } else {
            let (u, v) = axes
            let ex = abs(u.x) * size.x / 2 + abs(v.x) * size.y / 2
            let ey = abs(u.y) * size.x / 2 + abs(v.y) * size.y / 2
            return (Int(floor(position.x - ex)), Int(floor(position.y - ey)),
                    Int(ceil(position.x + ex)), Int(ceil(position.y + ey)))
        }
        return (Int(floor(position.x - r)), Int(floor(position.y - r)), Int(ceil(position.x + r)), Int(ceil(position.y + r)))
    }
}

public extension TrackObjectKind {
    var defaultSize: Vec2 {
        switch self {
        case .tree: Vec2(26, 26)
        case .pine: Vec2(20, 20)
        case .palm: Vec2(24, 24)
        case .grandstand: Vec2(130, 34)
        case .pitBuilding: Vec2(150, 40)
        case .ramp: Vec2(60, 32)
        case .boat: Vec2(40, 14)
        case .footbridge: Vec2(140, 14)
        }
    }
}

func segmentDistance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
    let ab = b - a
    let t = clamp((p - a).dot(ab) / max(ab.lengthSquared, 1e-9), 0, 1)
    return (p - (a + ab * t)).length
}
