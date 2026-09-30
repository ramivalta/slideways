import Foundation

/// Jump ramps. A ramp rises from its low front edge to a lip at the back. Cars that drive up
/// it and over the lip are launched into the air, where they clear tire walls, water, sand
/// and other cars; trees, buildings, bridges and the edge of the map still stop them.
/// Driving onto a ramp over the lip or up its sides is a bump that scrubs speed instead.
///
/// Heights are in track units, like everything else; they only affect what a car can clear
/// and how it's drawn.
public enum Jumps {
    public static let gravity = 700.0
    /// Height of a ramp's lip.
    public static let lipHeight = 7.0
    /// Airborne cars higher than this clear tire walls and other cars.
    public static let clearance = 6.0
    /// Take-off vertical speed per unit of speed up the ramp.
    static let launchFactor = 0.65
    /// Slower than this, a car just rolls off the lip.
    static let minLaunchSpeed = 40.0
    /// Fraction of speed a head-on bump into the lip takes off.
    static let bumpScrub = 0.5

    /// Height of the ramp surface under `p`, or 0 off every ramp.
    static func groundHeight(at p: Vec2, track: Track) -> Double {
        var h = 0.0
        for ramp in track.ramps {
            let l = ramp.local(p)
            guard abs(l.x) <= ramp.size.x / 2, abs(l.y) <= ramp.size.y / 2 else { continue }
            h = max(h, lipHeight * rise(l.y, ramp))
        }
        return h
    }

    /// 0 at the front edge of a ramp, 1 at its lip.
    static func rise(_ localY: Double, _ ramp: TrackObject) -> Double {
        clamp((localY + ramp.size.y / 2) / max(ramp.size.y, 1), 0, 1)
    }

    /// Advances a car's height after it moved from `before` this step: flight, landings,
    /// launches off lips and bumps from the wrong side.
    static func update(_ car: Car, from before: Vec2, track: Track, dt: Double, events: inout [ImpactEvent]) {
        guard !track.ramps.isEmpty || car.isAirborne || car.height != 0 else { return }
        if car.isAirborne {
            car.verticalSpeed -= gravity * dt
            car.height += car.verticalSpeed * dt
            let ground = groundHeight(at: car.position, track: track)
            if car.verticalSpeed < 0, car.height <= ground { land(car, on: ground, events: &events) }
            return
        }

        var height = 0.0
        for ramp in track.ramps {
            let hl = ramp.size.x / 2, hd = ramp.size.y / 2
            let l0 = ramp.local(before), l1 = ramp.local(car.position)
            let inside0 = abs(l0.x) <= hl && abs(l0.y) <= hd
            let inside1 = abs(l1.x) <= hl && abs(l1.y) <= hd
            if inside0, !inside1, l1.y > hd {
                return launch(car, off: ramp)
            }
            if !inside0, inside1, l0.y >= -hd {
                // Came on over the lip or up a side: the higher the ramp where the car hit it,
                // the harder the knock.
                return bump(car, on: ramp, at: l1, events: &events)
            }
            if inside1 { height = max(height, lipHeight * rise(l1.y, ramp)) }
        }
        car.height = height
    }

    private static func launch(_ car: Car, off ramp: TrackObject) {
        let up = car.velocity.dot(ramp.rampDirection)
        car.isAirborne = true
        car.height = lipHeight
        if up > minLaunchSpeed {
            car.verticalSpeed = up * launchFactor
            car.jumps += 1
        } else {
            car.verticalSpeed = 0
        }
    }

    private static func bump(_ car: Car, on ramp: TrackObject, at l: Vec2, events: inout [ImpactEvent]) {
        let t = rise(l.y, ramp)
        let (u, v) = ramp.axes
        // Speed into the face the car hit: the lip from behind, or a side.
        let fromBehind = l.y > ramp.size.y / 2 - 3
        let closing = fromBehind ? max(0, -car.velocity.dot(v)) : abs(car.velocity.dot(u))
        let hit = closing * t
        car.velocity *= 1 - bumpScrub * t
        car.angularVelocity += clamp(l.x / max(ramp.size.x / 2, 1), -1, 1) * 2.5 * t
        // A small hop up onto the ramp.
        car.isAirborne = true
        car.height = lipHeight * t
        car.verticalSpeed = 25 + hit * 0.2
        if hit > 30 {
            events.append(ImpactEvent(position: car.position, strength: hit, isCarToCar: false))
        }
    }

    private static func land(_ car: Car, on ground: Double, events: inout [ImpactEvent]) {
        let impact = -car.verticalSpeed
        car.isAirborne = false
        car.height = ground
        car.verticalSpeed = 0
        if impact > 120 {
            car.velocity *= 0.96
            events.append(ImpactEvent(position: car.position, strength: impact * 0.35, isCarToCar: false))
        }
    }
}
