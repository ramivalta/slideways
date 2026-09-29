import Foundation

/// Authoring format for a track. Codable so tracks can live in JSON files and a future editor.
///
/// The road follows a closed centripetal Catmull-Rom spline through `controlPoints`.
/// The first control point is the start/finish line; the point order sets the race direction.
public struct TrackDefinition: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var width: Int
    public var height: Int
    public var roadWidth: Double
    public var controlPoints: [Vec2]
    public var defaultLaps: Int
    public var theme: TrackTheme
    /// Surface used everywhere that isn't road, curb, barrier or a patch.
    public var background: Surface
    /// If set, a wall is placed this far from the road edge on both sides of the road.
    public var barrierDistance: Double?
    public var barrierThickness: Double
    public var patches: [Patch]
    /// Places where the road crosses itself on two levels.
    public var bridges: [BridgeDefinition]

    public init(
        id: String,
        name: String,
        width: Int = 960,
        height: Int = 600,
        roadWidth: Double = 82,
        controlPoints: [Vec2],
        defaultLaps: Int = 5,
        theme: TrackTheme = .summer,
        background: Surface = .grass,
        barrierDistance: Double? = nil,
        barrierThickness: Double = 7,
        patches: [Patch] = [],
        bridges: [BridgeDefinition] = []
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.roadWidth = roadWidth
        self.controlPoints = controlPoints
        self.defaultLaps = defaultLaps
        self.theme = theme
        self.background = background
        self.barrierDistance = barrierDistance
        self.barrierThickness = barrierThickness
        self.patches = patches
        self.bridges = bridges
    }
}

/// A region painted with a surface after the road is laid down.
public struct Patch: Codable, Sendable {
    public var surface: Surface
    public var shape: PatchShape
    /// When false the patch only replaces non-road cells (e.g. sand traps beside the road).
    public var coversRoad: Bool

    public init(_ surface: Surface, _ shape: PatchShape, coversRoad: Bool = false) {
        self.surface = surface
        self.shape = shape
        self.coversRoad = coversRoad
    }
}

public enum PatchShape: Codable, Sendable {
    case circle(center: Vec2, radius: Double)
    case rect(origin: Vec2, size: Vec2)
    /// A thick line segment with rounded ends. Handy for walls.
    case capsule(from: Vec2, to: Vec2, radius: Double)

    public func contains(_ p: Vec2) -> Bool {
        switch self {
        case let .circle(c, r):
            return (p - c).lengthSquared <= r * r
        case let .rect(o, s):
            return p.x >= o.x && p.y >= o.y && p.x <= o.x + s.x && p.y <= o.y + s.y
        case let .capsule(a, b, r):
            let ab = b - a
            let t = clamp((p - a).dot(ab) / max(ab.lengthSquared, 1e-9), 0, 1)
            return (p - (a + ab * t)).lengthSquared <= r * r
        }
    }

    /// Integer cell bounds (inclusive) that can contain the shape.
    public var bounds: (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        switch self {
        case let .circle(c, r):
            return (Int(floor(c.x - r)), Int(floor(c.y - r)), Int(ceil(c.x + r)), Int(ceil(c.y + r)))
        case let .rect(o, s):
            return (Int(floor(o.x)), Int(floor(o.y)), Int(ceil(o.x + s.x)), Int(ceil(o.y + s.y)))
        case let .capsule(a, b, r):
            return (
                Int(floor(min(a.x, b.x) - r)), Int(floor(min(a.y, b.y) - r)),
                Int(ceil(max(a.x, b.x) + r)), Int(ceil(max(a.y, b.y) + r))
            )
        }
    }
}
