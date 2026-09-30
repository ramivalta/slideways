import Foundation

/// Drafting: a car running close behind another pushes through less air, so its engine can
/// carry it faster and it closes in down the straights. Sitting behind several cars in a line
/// adds up, with a cap.
///
/// The benefit shows up as a higher effective top speed in `Car.integrate`: it only matters
/// flat out on fast surfaces, and does next to nothing in sand or grass where drag dominates.
enum Slipstream {
    /// How far back the wake reaches, in lead-car lengths.
    static let reachLengths = 7.0
    /// No wake from a car that isn't really moving.
    static let minLeaderSpeed = 90.0
    /// Leader speed above `minLeaderSpeed` at which the wake reaches full strength.
    static let fullWakeSpeedRange = 60.0
    /// Wake half-width right behind the car, in car widths, and how much it widens per pixel back.
    static let baseHalfWidth = 0.8
    static let spread = 0.12
    /// The follower must be heading roughly the same way (cosine of the angle between velocities).
    static let minAlignment = 0.8
    /// Most draft stacked from several cars.
    static let maxDraft = 1.5
    /// Extra engine top speed per unit of draft. One car right ahead gives roughly 12% more
    /// top speed on asphalt, a line of cars about 17%.
    static let topSpeedGain = 0.18
    /// Seconds for the effect to build up or fade once a car enters or leaves a wake.
    static let response = 0.3

    /// Updates every car's draft from where the others are at the start of this step, so the
    /// result doesn't depend on the order the cars are integrated in.
    static func update(_ cars: [Car], dt: Double) {
        let targets = cars.map { target(for: $0, among: cars) }
        let blend = 1 - exp(-dt / response)
        for (car, t) in zip(cars, targets) {
            car.slipstream += (t - car.slipstream) * blend
        }
    }

    /// Draft the car would get from the wakes it's sitting in right now: 0 in clean air.
    static func target(for car: Car, among cars: [Car]) -> Double {
        let speed = car.speed
        guard speed > 1, !car.isAirborne else { return 0 }
        let heading = car.velocity / speed
        var total = 0.0
        for leader in cars where leader !== car {
            total += wake(of: leader, at: car, heading: heading)
        }
        return min(total, maxDraft)
    }

    /// Strength (0...1) of one car's wake at the follower's position.
    private static func wake(of leader: Car, at car: Car, heading: Vec2) -> Double {
        // Cars on a bridge deck and underneath it don't share air, nor do cars in flight.
        guard leader.level == car.level, !leader.isAirborne else { return 0 }
        let leaderSpeed = leader.speed
        guard leaderSpeed > minLeaderSpeed else { return 0 }
        let dir = leader.velocity / leaderSpeed
        guard heading.dot(dir) > minAlignment else { return 0 }

        // How far the follower is behind the leader along its line of travel, and how far off it.
        let d = leader.position - car.position
        let gap = d.dot(dir)
        // Bumpers overlapping means side by side, not behind.
        let minGap = (leader.spec.length + car.spec.length) / 2
        let reach = leader.spec.length * reachLengths
        guard gap > minGap, gap < reach else { return 0 }
        let halfWidth = leader.spec.width * baseHalfWidth + gap * spread
        let lateral = abs(d.dot(dir.perp))
        guard lateral < halfWidth else { return 0 }

        // Strongest tucked right in behind, fading out with distance and toward the wake's edges.
        let along = 1 - (gap - minGap) / (reach - minGap)
        let across = 1 - (lateral / halfWidth) * (lateral / halfWidth)
        let strength = clamp((leaderSpeed - minLeaderSpeed) / fullWakeSpeedRange, 0, 1)
        return along * across * strength
    }
}
