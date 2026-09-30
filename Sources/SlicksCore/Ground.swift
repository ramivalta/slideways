/// What a car's tires are on at a point, with everything a race lays on top of the track:
/// rubber on the road, and loose sand over that.
public enum Ground {
    /// Surface and handling at a point for a car on `level`. Bridge decks never get sand or
    /// rubber on them.
    public static func at(_ p: Vec2, level: Int, track: Track, sand: LooseSand?, rubber: Rubber?) -> (surface: Surface, properties: SurfaceProperties) {
        let base = track.surface(at: p, level: level)
        guard level == 0 else { return (base, base.properties) }
        let rubbered = rubber.map { Rubber.properties(base: base, rubber: $0.level(at: p)) } ?? base.properties
        guard let sand else { return (base, rubbered) }
        let c = sand.coverage(at: p)
        let feel = c > LooseSand.feelsLikeSand && base != .wall ? Surface.sand : base
        return (feel, LooseSand.properties(base: base, coverage: c, beneath: rubbered))
    }
}
