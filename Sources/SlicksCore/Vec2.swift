import Foundation

/// Minimal 2D vector used by the simulation. World space is y-up, 1 unit = 1 track pixel.
public struct Vec2: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(angle: Double) {
        self.x = cos(angle)
        self.y = sin(angle)
    }

    public static let zero = Vec2(0, 0)

    @inlinable public var length: Double { (x * x + y * y).squareRoot() }
    @inlinable public var lengthSquared: Double { x * x + y * y }
    @inlinable public var angle: Double { atan2(y, x) }
    /// Left-hand perpendicular (rotated +90 degrees).
    @inlinable public var perp: Vec2 { Vec2(-y, x) }

    @inlinable public var normalized: Vec2 {
        let l = length
        return l > 1e-9 ? Vec2(x / l, y / l) : .zero
    }

    @inlinable public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    /// 2D cross product (z component).
    @inlinable public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    @inlinable public func distance(to o: Vec2) -> Double { (self - o).length }

    @inlinable public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    @inlinable public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    @inlinable public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    @inlinable public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(a.x * s, a.y * s) }
    @inlinable public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    @inlinable public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    @inlinable public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    @inlinable public static func -= (a: inout Vec2, b: Vec2) { a = a - b }
    @inlinable public static func *= (a: inout Vec2, s: Double) { a = a * s }
}

/// Wraps an angle into (-pi, pi].
@inlinable public func wrapAngle(_ a: Double) -> Double {
    var r = a.truncatingRemainder(dividingBy: 2 * .pi)
    if r > .pi { r -= 2 * .pi }
    if r <= -.pi { r += 2 * .pi }
    return r
}

@inlinable public func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(max(v, lo), hi)
}

/// Small deterministic RNG so races and AI personalities are reproducible.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Smooth 2D value noise in [0, 1): hashed lattice values blended with smoothstep.
public func valueNoise(_ x: Double, _ y: Double, salt: Int = 0) -> Double {
    let x0 = floor(x), y0 = floor(y)
    let ix = Int(x0), iy = Int(y0)
    let fx = x - x0, fy = y - y0
    let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
    let a = hash01(ix, iy, salt), b = hash01(ix + 1, iy, salt)
    let c = hash01(ix, iy + 1, salt), d = hash01(ix + 1, iy + 1, salt)
    return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
}

/// Three octaves of value noise in [0, 1) at a base feature size of `scale` units.
public func fractalNoise(_ p: Vec2, scale: Double, salt: Int = 0) -> Double {
    let x = p.x / scale, y = p.y / scale
    return 0.57 * valueNoise(x, y, salt: salt)
        + 0.29 * valueNoise(x * 2.3, y * 2.3, salt: salt + 1)
        + 0.14 * valueNoise(x * 5.1, y * 5.1, salt: salt + 2)
}

/// Cheap integer hash to [0, 1) for procedural texturing.
@inlinable public func hash01(_ x: Int, _ y: Int, _ salt: Int = 0) -> Double {
    var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263 &+ salt &* 2_147_483_647))
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Double(h & 0xFFFF) / 65536.0
}
