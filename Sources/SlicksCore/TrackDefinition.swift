import Foundation

/// Authoring format for a track. Codable so tracks can live in JSON files and a future editor.
///
/// The road follows a closed centripetal Catmull-Rom spline through `controlPoints`.
/// The first control point is the start/finish line; the point order sets the race direction.
public struct TrackDefinition: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var width: Int
    public var height: Int
    /// Road width wherever a control point doesn't set its own.
    public var roadWidth: Double
    public var curbWidth: Double
    /// Whether a dashed white line is painted down the middle of the road.
    public var centerLine: Bool
    public var controlPoints: [Vec2]
    /// Optional road width at each control point, parallel to `controlPoints`. Nil (or a
    /// missing entry) uses `roadWidth`. The width eases smoothly between points.
    public var pointWidths: [Double?]
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
    /// Paint on the ground, drawn in order. No effect on driving.
    public var lines: [PaintLine]
    /// Trees, buildings and jump ramps.
    public var objects: [TrackObject]
    /// Whether cars kick sand out of sand traps and track it onto the road during a race.
    public var looseSand: Bool

    public init(
        id: String,
        name: String,
        width: Int = 960,
        height: Int = 600,
        roadWidth: Double = 82,
        curbWidth: Double = Track.curbWidth,
        centerLine: Bool = false,
        controlPoints: [Vec2],
        pointWidths: [Double?] = [],
        defaultLaps: Int = 5,
        theme: TrackTheme = .summer,
        background: Surface = .grass,
        barrierDistance: Double? = nil,
        barrierThickness: Double = 7,
        patches: [Patch] = [],
        bridges: [BridgeDefinition] = [],
        lines: [PaintLine] = [],
        objects: [TrackObject] = [],
        looseSand: Bool = true
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.roadWidth = roadWidth
        self.curbWidth = curbWidth
        self.centerLine = centerLine
        self.controlPoints = controlPoints
        self.pointWidths = pointWidths
        self.defaultLaps = defaultLaps
        self.theme = theme
        self.background = background
        self.barrierDistance = barrierDistance
        self.barrierThickness = barrierThickness
        self.patches = patches
        self.bridges = bridges
        self.lines = lines
        self.objects = objects
        self.looseSand = looseSand
    }

    /// Tracks saved before a field existed still load: missing optional parts get defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 960
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 600
        roadWidth = try c.decodeIfPresent(Double.self, forKey: .roadWidth) ?? 82
        curbWidth = try c.decodeIfPresent(Double.self, forKey: .curbWidth) ?? Track.curbWidth
        centerLine = try c.decodeIfPresent(Bool.self, forKey: .centerLine) ?? false
        controlPoints = try c.decode([Vec2].self, forKey: .controlPoints)
        pointWidths = try c.decodeIfPresent([Double?].self, forKey: .pointWidths) ?? []
        defaultLaps = try c.decodeIfPresent(Int.self, forKey: .defaultLaps) ?? 5
        theme = try c.decodeIfPresent(TrackTheme.self, forKey: .theme) ?? .summer
        background = try c.decodeIfPresent(Surface.self, forKey: .background) ?? .grass
        barrierDistance = try c.decodeIfPresent(Double.self, forKey: .barrierDistance)
        barrierThickness = try c.decodeIfPresent(Double.self, forKey: .barrierThickness) ?? 7
        patches = try c.decodeIfPresent([Patch].self, forKey: .patches) ?? []
        bridges = try c.decodeIfPresent([BridgeDefinition].self, forKey: .bridges) ?? []
        lines = try c.decodeIfPresent([PaintLine].self, forKey: .lines) ?? []
        objects = try c.decodeIfPresent([TrackObject].self, forKey: .objects) ?? []
        looseSand = try c.decodeIfPresent(Bool.self, forKey: .looseSand) ?? true
    }

    /// Road width at a control point.
    public func roadWidth(atPoint i: Int) -> Double {
        pointWidths.indices.contains(i) ? pointWidths[i] ?? roadWidth : roadWidth
    }

    /// Whether any control point sets its own width.
    public var hasPointWidths: Bool { pointWidths.contains { $0 != nil } }

    /// Road width at every point of `Track.centerline(through: controlPoints)`, easing
    /// between control point widths with a smoothstep so edges stay smooth.
    public func centerlineWidths() -> [Double] {
        let n = controlPoints.count
        let steps = Track.splineSteps
        guard hasPointWidths, n >= 3 else { return [Double](repeating: roadWidth, count: n >= 3 ? n * steps : n) }
        var out: [Double] = []
        out.reserveCapacity(n * steps)
        for i in 0..<n {
            let a = roadWidth(atPoint: i), b = roadWidth(atPoint: (i + 1) % n)
            for s in 0..<steps {
                let t = Double(s) / Double(steps)
                out.append(a + (b - a) * t * t * (3 - 2 * t))
            }
        }
        return out
    }
}

/// A region painted with a surface after the road is laid down.
public struct Patch: Codable, Sendable, Equatable {
    public var surface: Surface
    public var shape: PatchShape
    /// When false the patch only replaces non-road cells (e.g. sand traps beside the road).
    public var coversRoad: Bool
    /// Whether the patch paints the bridge deck instead of the ground below it.
    public var onDeck: Bool

    public init(_ surface: Surface, _ shape: PatchShape, coversRoad: Bool = false, onDeck: Bool = false) {
        self.surface = surface
        self.shape = shape
        self.coversRoad = coversRoad
        self.onDeck = onDeck
    }

    private enum CodingKeys: String, CodingKey { case surface, shape, coversRoad, onDeck }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surface = try container.decode(Surface.self, forKey: .surface)
        shape = try container.decode(PatchShape.self, forKey: .shape)
        coversRoad = try container.decode(Bool.self, forKey: .coversRoad)
        onDeck = try container.decodeIfPresent(Bool.self, forKey: .onDeck) ?? false
    }
}

public enum PatchShape: Codable, Sendable, Equatable {
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
