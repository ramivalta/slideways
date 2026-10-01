import Foundation

/// Computer driver: follows the centerline with a speed-dependent lookahead and brakes
/// for upcoming corners based on the car's grip.
public struct AIDriver: Codable, Sendable, Equatable {
    /// How one computer driver's habits differ from the others'. Drawn from a seed, so every
    /// machine in an online race builds the same drivers and only the seed goes on the wire.
    public struct Personality: Codable, Sendable, Equatable {
        /// Cornering grip the driver counts on, relative to the default. Brave drivers go over 1.
        public var cornerPace: Double
        /// Braking the driver counts on when planning: late brakers go over 1.
        public var braking: Double
        /// Scales how far ahead the driver steers toward: smooth over 1, twitchy under.
        public var lookahead: Double
        public var steerGain: Double
        /// Counter-steer when the rear steps out, relative to the default.
        public var counterSteer: Double
        /// Throttle held when just over the target speed (instead of lifting right off).
        public var lift: Double
        /// Line through corners, as a fraction of half the road width: positive hugs the
        /// inside, negative swings wide.
        public var apex: Double
        /// How far and how fast the preferred lane wanders down the straights.
        public var weave: Double
        public var weaveRate: Double
        public var weavePhase: Double
        /// 0...1: how much the driver's pace and steering wander over a lap. Skill damps it.
        public var inconsistency: Double
        /// Seconds late off the line at the green light.
        public var reaction: Double
        /// Picks this driver's stream of little mistakes.
        public var noiseSalt: Int

        /// The same habits every computer driver had before personalities: used for autopilots
        /// and tests that want a predictable driver.
        public static let neutral = Personality(
            cornerPace: 1, braking: 1, lookahead: 1, steerGain: 2.8, counterSteer: 1, lift: 0.3, apex: 0,
            weave: 0.25, weaveRate: 0.35, weavePhase: 0, inconsistency: 0, reaction: 0, noiseSalt: 0
        )

        public init(cornerPace: Double, braking: Double, lookahead: Double, steerGain: Double, counterSteer: Double,
                    lift: Double, apex: Double, weave: Double, weaveRate: Double, weavePhase: Double,
                    inconsistency: Double, reaction: Double, noiseSalt: Int) {
            self.cornerPace = cornerPace
            self.braking = braking
            self.lookahead = lookahead
            self.steerGain = steerGain
            self.counterSteer = counterSteer
            self.lift = lift
            self.apex = apex
            self.weave = weave
            self.weaveRate = weaveRate
            self.weavePhase = weavePhase
            self.inconsistency = inconsistency
            self.reaction = reaction
            self.noiseSalt = noiseSalt
        }

        /// A random but reproducible personality.
        public init(seed: UInt64) {
            var rng = SplitMix64(seed: seed)
            func pick(_ r: ClosedRange<Double>) -> Double { Double.random(in: r, using: &rng) }
            cornerPace = pick(0.9...1.08)
            braking = pick(0.82...1.12)
            lookahead = pick(0.82...1.25)
            steerGain = pick(2.3...3.3)
            counterSteer = pick(0.6...1.4)
            lift = pick(0.1...0.5)
            apex = pick(-0.3...0.2)
            weave = pick(0.08...0.35)
            weaveRate = pick(0.2...0.6)
            weavePhase = pick(0...(2 * .pi))
            inconsistency = pick(0.2...1)
            reaction = pick(0...0.3)
            noiseSalt = Int(truncatingIfNeeded: rng.next() & 0x7FFF_FFFF)
        }
    }

    /// 0...1, scales cornering speed and reaction.
    public var skill: Double
    /// Preferred lateral offset from the centerline, as a fraction of half the road width.
    public var lane: Double
    /// Where `personality` came from, or nil for the neutral one.
    public let seed: UInt64?
    public let personality: Personality
    var stuckTime = 0.0
    var reverseTime = 0.0
    var reverseSteer = 0.0
    var laneDrift = 0.0
    /// While routing back to the road: closest to it so far, and how long since that improved.
    var routeBest: Double?
    var routeStall = 0.0

    /// - Parameter seed: draws the driver's personality; nil drives with the neutral one.
    public init(skill: Double, lane: Double, seed: UInt64? = nil) {
        self.skill = clamp(skill, 0, 1)
        self.lane = clamp(lane, -0.6, 0.6)
        self.seed = seed
        personality = seed.map(Personality.init(seed:)) ?? .neutral
    }

    /// Slow noise in -1...1 for this driver: `rate` changes a second, `channel` picks an
    /// independent stream. Depends only on the race clock, so rewinding replays it exactly.
    private func wander(_ elapsed: Double, rate: Double, channel: Int) -> Double {
        valueNoise(elapsed * rate, Double(channel * 17), salt: personality.noiseSalt) * 2 - 1
    }

    /// Top speed while picking a way back to the road around walls.
    static let routeSpeed = 90.0
    /// When routing, a waypoint further round than this (radians) is reversed toward.
    static let turnAroundAngle = 2.0
    /// Seconds without getting closer to the road along the route before backing up.
    static let routeStallTime = 1.5

    /// Public so tests can drive "human" cars with the AI's judgment. Without a route map it
    /// won't find its way back from behind walls.
    public mutating func input(for car: Car, track: Track, sand: LooseSand? = nil, rubber: Rubber? = nil,
                               dt: Double, elapsed: Double) -> CarInput {
        input(for: car, track: track, sand: sand, rubber: rubber, roads: nil, dt: dt, elapsed: elapsed)
    }

    mutating func input(for car: Car, track: Track, sand: LooseSand?, rubber: Rubber?, roads: RoadFinder?,
                        dt: Double, elapsed: Double) -> CarInput {
        let n = track.sampleCount
        let speed = car.speed
        let spec = car.spec
        let p = personality

        // Some drivers are slow off the line.
        if elapsed < p.reaction { return .none }
        // How much this driver's pace and steering wander: erratic, less skilled drivers
        // overcook corners and saw at the wheel more.
        let lapses = p.inconsistency * (1.3 - skill)

        // Wiggle the preferred lane slowly so the pack doesn't drive in single file.
        laneDrift = sin(elapsed * p.weaveRate + p.weavePhase + Double(car.id) * 1.7) * p.weave

        // Steer toward a point ahead on the path.
        let look = Int((7 + speed * 0.075) * p.lookahead)
        let ti = (car.pathIndex + look) % n
        // Tighten the line toward the centerline in corners so we don't clip the inside curb.
        let cornerFactor = clamp(1 - track.curvature[ti] * 40, 0.2, 1)
        // Then each driver's own line: apex hunters lean to the inside, others run wide.
        let bend = (1 - cornerFactor) / 0.8
        let turn = track.tangents[(ti - 3 + n) % n].cross(track.tangents[(ti + 3) % n])
        let inside: Double = turn >= 0 ? 1 : -1
        let laneFraction = clamp(clamp(lane + laneDrift, -0.65, 0.65) * cornerFactor + inside * p.apex * bend, -0.65, 0.65)
        var target = track.path[ti] + track.normals[ti] * (laneFraction * track.halfWidths[ti])
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
        var steer = clamp(angleError * p.steerGain + wander(elapsed, rate: 1.7, channel: 1) * 0.1 * lapses, -1, 1)

        // Counter-steer a bit when the rear is stepping out.
        let lateral = car.velocity.dot(car.left)
        if speed > 60 {
            let catchLimit = 0.35 * p.counterSteer
            steer = clamp(steer + clamp(lateral / 400 * p.counterSteer, -catchLimit, catchLimit), -1, 1)
        }

        // Speed planning: for each sample ahead, the fastest we can go now and still make that corner.
        // Grip and braking use the surface at each upcoming sample, so ice ahead is respected.
        // Brave drivers count on more grip than timid ones, and nobody judges it the same way twice.
        let judgement = p.cornerPace * (1 + wander(elapsed, rate: 0.6, channel: 0) * 0.09 * lapses)
        let skillGrip = spec.grip * (0.72 + 0.26 * skill) * judgement
        let turnLimit = spec.turnRate * 0.75 * (0.85 + 0.15 * skill)
        let hereProps = Ground.at(car.position, level: car.level, track: track, sand: sand, rubber: rubber).properties
        let horizon = Int(12 + speed * 0.18)
        var desired = spec.maxSpeed
        var k = 2
        while k <= horizon {
            let i = (car.pathIndex + k) % n
            let ahead = Ground.at(track.path[i], level: Int(track.sampleLevels[i]), track: track, sand: sand, rubber: rubber).properties
            let gripAccel = skillGrip * ahead.grip
            // Braking happens between here and there, so use the worse of the two surfaces.
            let brakeDecel = spec.brakeDeceleration * 0.8 * p.braking * min(hereProps.traction, ahead.traction)
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
            throttle = p.lift
        }

        if routing, let left = roads?.remaining(from: car.position).map(Double.init) {
            // Scraping along a wall still counts as moving, so going nowhere along the route
            // counts as stuck too.
            if left < (routeBest ?? .infinity) - 1 {
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
            routeBest = nil
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
