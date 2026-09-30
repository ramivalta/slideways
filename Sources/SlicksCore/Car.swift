import Foundation

/// Tunable handling numbers. Units are track pixels and seconds.
public struct CarSpec: Codable, Sendable {
    public var maxSpeed: Double = 315
    public var acceleration: Double = 260
    public var brakeDeceleration: Double = 400
    public var reverseSpeed: Double = 85
    public var reverseAcceleration: Double = 170
    /// Peak yaw rate in rad/s at full steering. Higher than the tires can follow, so the car rotates into slides.
    public var turnRate: Double = 4.2
    /// Lateral acceleration the tires can hold before letting go (on asphalt).
    public var grip: Double = 250
    /// Once sliding, grip drops to this fraction until the car straightens up. Makes drifts hold.
    public var slidingGripFactor: Double = 0.65
    /// Sideways speed above which the tires count as sliding.
    public var slideThreshold: Double = 18
    /// How much forward speed a slide scrubs off per second, scaled by surface grip.
    public var slideScrub: Double = 0.22
    public var length: Double = 22
    public var width: Double = 11

    public init() {}

    /// Radius of the two collision circles (front and rear).
    public var collisionRadius: Double { width / 2 }
    /// Offset of the collision circles from the car center along its heading.
    public var collisionOffset: Double { length / 2 - width / 2 }
    /// Moment of inertia for a unit-mass box.
    public var inertia: Double { (length * length + width * width) / 12 }
}

public struct CarInput: Sendable, Equatable {
    public var throttle: Double
    public var brake: Double
    /// -1 = full right, +1 = full left (counter-clockwise).
    public var steer: Double

    public init(throttle: Double = 0, brake: Double = 0, steer: Double = 0) {
        self.throttle = throttle
        self.brake = brake
        self.steer = steer
    }

    public static let none = CarInput()
}

public final class Car {
    public let id: Int
    public let name: String
    public let colorIndex: Int
    public let isAI: Bool
    /// For humans: which local player (0-3) controls this car.
    public let playerIndex: Int?
    public var spec: CarSpec

    public var position: Vec2
    public var velocity: Vec2 = .zero
    public var heading: Double
    public var angularVelocity: Double = 0

    // Race progress
    public var pathIndex: Int
    /// Unwrapped progress along the centerline in samples. Crossing multiples of the sample count completes laps.
    public var progress: Double
    public var lapsCompleted = 0
    public var lapTimes: [Double] = []
    public var lastLapMark: Double = 0
    public var finishTime: Double?

    // Telemetry for rendering, sound and debugging
    public private(set) var slip: Double = 0
    public private(set) var isBraking = false
    /// Rear tires spinning under hard acceleration (leaves marks).
    public private(set) var isWheelspinning = false
    /// Engine push (before surface traction) above which the rear tires spin. With the default
    /// spec that's full throttle below roughly a third of top speed.
    static let wheelspinAcceleration = 175.0
    /// Reverse gear: engaged by braking at a standstill, released by the throttle.
    public private(set) var inReverse = false
    public private(set) var surface: Surface = .asphalt
    public var wallHits = 0
    public var lastInput = CarInput.none

    /// 0 = ground, 1 = on a bridge deck.
    public internal(set) var level = 0
    /// Index of the bridge zone the car is currently in, if any.
    public internal(set) var bridgeZone: Int?
    /// Sand stuck to the rear tires after driving through a trap, in cells' worth (up to
    /// `LooseSand.tireCapacity`). Shed onto the road over the next few car lengths.
    public internal(set) var sandOnTires = 0.0
    /// Drafting benefit from running in other cars' wakes: 0 in clean air, up to
    /// `Slipstream.maxDraft` behind a line of cars. See `Slipstream`.
    public internal(set) var slipstream = 0.0

    /// Height above the ground: rising up a ramp or flying off one. See `Jumps`.
    public internal(set) var height = 0.0
    var verticalSpeed = 0.0
    /// In the air after leaving a ramp: no grip, steering or engine until it lands.
    public internal(set) var isAirborne = false
    /// Ramp launches so far, for telemetry.
    public internal(set) var jumps = 0
    /// High enough to clear tire walls and other cars.
    public var isAboveObstacles: Bool { isAirborne && height > Jumps.clearance }

    init(id: Int, name: String, colorIndex: Int, isAI: Bool, playerIndex: Int?, spec: CarSpec,
         position: Vec2, heading: Double, pathIndex: Int, progress: Double) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.isAI = isAI
        self.playerIndex = playerIndex
        self.spec = spec
        self.position = position
        self.heading = heading
        self.pathIndex = pathIndex
        self.progress = progress
    }

    public var forward: Vec2 { Vec2(angle: heading) }
    public var left: Vec2 { Vec2(angle: heading).perp }
    public var speed: Double { velocity.length }
    public var forwardSpeed: Double { velocity.dot(forward) }
    public var isFinished: Bool { finishTime != nil }
    public var bestLap: Double? { lapTimes.min() }

    public var collisionCircles: (Vec2, Vec2) {
        let f = forward * spec.collisionOffset
        return (position + f, position - f)
    }

    /// Advances the car's own dynamics: steering, engine, drag and tire grip.
    /// Collisions are resolved separately by the race.
    func integrate(input: CarInput, track: Track, sand: LooseSand? = nil, rubber: Rubber? = nil, dt: Double) {
        lastInput = input
        if isAirborne {
            // Ballistic: the tires have nothing to push on, so the car keeps its heading
            // and velocity apart from a little air drag and whatever spin it took off with.
            isBraking = false
            isWheelspinning = false
            angularVelocity *= exp(-1.5 * dt)
            heading = wrapAngle(heading + angularVelocity * dt)
            velocity *= exp(-0.08 * dt)
            position += velocity * dt
            return
        }
        let ground = Ground.at(position, level: level, track: track, sand: sand, rubber: rubber)
        surface = ground.surface
        let props = ground.properties

        // Steering scales in with speed so the car can't spin on the spot,
        // and flips when reversing like a real car.
        // Uses total speed so you can still steer while sliding sideways.
        let fwdSpeed = velocity.dot(forward)
        let throttle = clamp(input.throttle, 0, 1)
        let brake = clamp(input.brake, 0, 1)
        // Steering only flips when the driver is deliberately reversing. Being knocked backward
        // by a crash doesn't put the car in reverse, so the controls keep working as expected.
        if throttle > 0 {
            inReverse = false
        } else if brake > 0, fwdSpeed <= 5 {
            inReverse = true
        }
        let speedFactor = clamp(velocity.length / 60, 0, 1)
        let highSpeedDamp = 1 - 0.25 * clamp(abs(fwdSpeed) / spec.maxSpeed, 0, 1)
        let direction: Double = inReverse && fwdSpeed < 0 ? -1 : 1
        let yaw = clamp(input.steer, -1, 1) * spec.turnRate * speedFactor * highSpeedDamp * direction
        angularVelocity *= exp(-5 * dt)
        heading = wrapAngle(heading + (yaw + angularVelocity) * dt)

        let fwd = forward
        let side = fwd.perp
        var vf = velocity.dot(fwd)
        var vl = velocity.dot(side)

        isBraking = false
        isWheelspinning = false
        if throttle > 0 {
            // The engine pulls the same whether the car is rolling forward or was knocked
            // backward by a crash, so the gas always drives it away.
            // Drafting behind other cars means less air to push through, so the engine
            // runs out of pull at a higher speed.
            let topSpeed = spec.maxSpeed * (1 + Slipstream.topSpeedGain * slipstream)
            let push = spec.acceleration * throttle * clamp(1 - vf / topSpeed, 0, 1)
            vf += push * props.traction * dt
            // Hard launches (and flooring it while rolling backward) spin the rear tires.
            isWheelspinning = push > Car.wheelspinAcceleration
        }
        if brake > 0 {
            if vf > 5 {
                vf = max(0, vf - spec.brakeDeceleration * props.traction * brake * dt)
                isBraking = true
            } else if throttle == 0 {
                vf = max(-spec.reverseSpeed, vf - spec.reverseAcceleration * props.traction * brake * dt)
            }
        }
        // Rolling resistance and surface drag.
        vf -= vf * props.drag * dt
        if throttle == 0 && brake == 0 {
            let coast = 30 * dt
            vf = abs(vf) <= coast ? 0 : vf - coast * (vf > 0 ? 1 : -1)
        }

        // Tires can only kill so much sideways velocity per step: anything beyond that is a slide.
        // Sliding tires grip less than rolling ones, so once the tail steps out it stays out
        // until the driver straightens up or lifts.
        slip = abs(vl)
        let sliding = abs(vl) > spec.slideThreshold
        let lateralGrip = spec.grip * props.grip * (sliding ? spec.slidingGripFactor : 1)
        let maxLateral = lateralGrip * dt
        if abs(vl) <= maxLateral {
            vl = 0
        } else {
            vl -= maxLateral * (vl > 0 ? 1 : -1)
            if sliding { vf -= vf * spec.slideScrub * props.grip * dt }
        }
        velocity = fwd * vf + side * vl
        position += velocity * dt
    }

    /// Applies an impulse at a world-space offset from the car center (unit mass).
    func applyImpulse(_ j: Vec2, at offset: Vec2) {
        velocity += j
        angularVelocity += offset.cross(j) / spec.inertia
    }

    /// Velocity of a point on the car body.
    func pointVelocity(at offset: Vec2) -> Vec2 {
        velocity + Vec2(-angularVelocity * offset.y, angularVelocity * offset.x)
    }
}
