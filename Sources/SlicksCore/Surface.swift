/// What a track cell is made of. Stored as one byte per cell.
public enum Surface: UInt8, Codable, Sendable, CaseIterable {
    case asphalt
    case curb
    case grass
    case sand
    case ice
    case wall

    public var properties: SurfaceProperties {
        switch self {
        case .asphalt: SurfaceProperties(grip: 1.0, drag: 0.35, traction: 1.0)
        case .curb: SurfaceProperties(grip: 0.9, drag: 0.6, traction: 0.95)
        case .grass: SurfaceProperties(grip: 0.7, drag: 1.5, traction: 0.6)
        case .sand: SurfaceProperties(grip: 0.65, drag: 3.2, traction: 0.45)
        case .ice: SurfaceProperties(grip: 0.32, drag: 0.15, traction: 0.35)
        case .wall: SurfaceProperties(grip: 1.0, drag: 0.35, traction: 1.0)
        }
    }
}

public struct SurfaceProperties: Sendable {
    /// Multiplier on the car's lateral grip (how hard it can corner before sliding).
    public var grip: Double
    /// Speed-proportional drag per second.
    public var drag: Double
    /// Multiplier on engine and brake force.
    public var traction: Double
}

/// Visual theme for a track. Only affects colors, never physics.
public enum TrackTheme: String, Codable, Sendable, CaseIterable {
    case summer
    case desert
    case winter
}
