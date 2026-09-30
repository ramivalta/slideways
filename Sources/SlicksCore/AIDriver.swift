import Foundation

/// Computer driver: follows the centerline with a speed-dependent lookahead and brakes
/// for upcoming corners based on the car's grip.
public struct AIDriver: Sendable {
    /// 0...1, scales cornering speed and reaction.
    public var skill: Double
    /// Preferred lateral offset from the centerline, as a fraction of half the road width.
    public var lane: Double
    var stuckTime = 0.0
    var reverseTime = 0.0
    var reverseSteer = 0.0
    var laneDrift = 0.0
    /// While routing back to the road: closest to it so far, and how long since that improved.
    var routeBest = Float.infinity
    var routeStall = 0.0

    public init(skill: Double, lane: Double) {
        self.skill = clamp(skill, 0, 1)
        self.lane = clamp(lane, -0.6, 0.6)
    }

    /// Top speed while picking a way back to the road around walls.
    static let routeSpeed = 90.0
    /// When routing, a waypoint further round than this (radians) is reversed toward.
    static let turnAroundAngle = 2.0
    /// Seconds without getting closer to the road along the route before backing up.
    static let routeStallTime = 1.5

    mutating func input(for car: Car, track: Track, sand: LooseSand? = nil, roads: RoadFinder? = nil,
                        dt: Double, elapsed: Double) -> CarInput {
        let n = track.sampleCount
        let speed = car.speed
        let spec = car.spec

        // Wiggle the preferred lane slowly so the pack doesn't drive in single file.
        laneDrift = sin(elapsed * 0.35 + Double(car.id) * 1.7) * 0.25

        // Steer toward a point ahead on the path.
        let look = Int(7 + speed * 0.075)
        let ti = (car.pathIndex + look) % n
        let laneOffset = clamp(lane + laneDrift, -0.65, 0.65) * track.halfWidths[ti]
        // Tighten the line toward the centerline in corners so we don't clip the inside curb.
        let cornerFactor = clamp(1 - track.curvature[ti] * 40, 0.2, 1)
        var target = track.path[ti] + track.normals[ti] * (laneOffset * cornerFactor)
        // Knocked off the road somewhere a wall stands between us and the line (behind the
        // tire barrier, say): follow the route around the walls back to the road instead.
        var routing = false
        if let roads, car.level == 0, car.bridgeZone == nil, !car.isAirborne,
           !track.isOnRoad(car.position), track.wallBetween(car.position, target),
           let waypoint = roads.waypoint(from: car.position) {
            target = waypoint
            routing = true
        }
        let toTarget = target - car.position
        let angleError = wrapAngle(toTarget.angle - car.heading)
        var steer = clamp(angleError * 2.8, -1, 1)

        // Counter-steer a bit when the rear is stepping out.
        let lateral = car.velocity.dot(car.left)
        if speed > 60 {
            steer = clamp(steer + clamp(lateral / 400, -0.35, 0.35), -1, 1)
        }

        // Speed planning: for each sample ahead, the fastest we can go now and still make that corner.
        // Grip and braking use the surface at each upcoming sample, so ice ahead is respected.
        let skillGrip = spec.grip * (0.72 + 0.26 * skill)
        let turnLimit = spec.turnRate * 0.75 * (0.85 + 0.15 * skill)
        let hereProps = LooseSand.surface(track: track, sand: sand, at: car.position, level: car.level).properties
        let horizon = Int(12 + speed * 0.18)
        var desired = spec.maxSpeed
        var k = 2
        while k <= horizon {
            let i = (car.pathIndex + k) % n
            let ahead = LooseSand.surface(track: track, sand: sand, at: track.path[i], level: Int(track.sampleLevels[i])).properties
            let gripAccel = skillGrip * ahead.grip
            // Braking happens between here and there, so use the worse of the two surfaces.
            let brakeDecel = spec.brakeDeceleration * 0.8 * min(hereProps.traction, ahead.traction)
            let kappa = max(track.curvature[i], 1e-5)
            let cornerSpeed = min((gripAccel / kappa).squareRoot(), turnLimit / kappa)
            let dist = Double(k) * track.spacing
            let allowed = (cornerSpeed * cornerSpeed + 2 * brakeDecel * dist).squareRoot()
            desired = min(desired, allowed)
            k += 2
        }
        // Big heading errors (spun out, off line) call for a slower approach.
        desired *= clamp(1.15 - abs(angleError) * 0.6, 0.35, 1)
        if routing { desired = min(desired, AIDriver.routeSpeed) }

        var throttle = 1.0
        var brake = 0.0
        let fwd = car.forwardSpeed
        if fwd > desired + 12 {
            throttle = 0
            brake = 1
        } else if fwd > desired {
            throttle = 0.3
        }

        if routing, let left = roads?.remaining(from: car.position) {
            // Scraping along a wall still counts as moving, so going nowhere along the route
            // counts as stuck too.
            if left < routeBest - 1 {
                routeBest = left
                routeStall = 0
            } else {
                routeStall += dt
            }
            // The way back is behind us, or we're pinned: back up swinging the nose round
            // toward it, then drive on (a three-point turn).
            if reverseTime <= 0, abs(angleError) > AIDriver.turnAroundAngle || routeStall > AIDriver.routeStallTime {
                reverseTime = 0.6
                reverseSteer = angleError > 0 ? -1 : 1
                stuckTime = 0
                routeStall = 0
                routeBest = left
            }
        } else {
            routeBest = .infinity
            routeStall = 0
        }
        // Stuck against a wall or another car: back out with opposite lock.
        if elapsed > 1, reverseTime <= 0 {
            if speed < 18 {
                stuckTime += dt
            } else {
                stuckTime = max(0, stuckTime - dt * 2)
            }
            if stuckTime > 1.0 {
                reverseTime = 0.9
                reverseSteer = angleError > 0 ? -1 : 1
                stuckTime = 0
            }
        }
        if reverseTime > 0 {
            reverseTime -= dt
            return CarInput(throttle: 0, brake: 1, steer: reverseSteer)
        }
        return CarInput(throttle: throttle, brake: brake, steer: steer)
    }
}
