import Foundation

/// A collision worth reacting to (sound, sparks, camera shake).
public struct ImpactEvent: Sendable {
    public var position: Vec2
    /// Closing speed along the contact normal.
    public var strength: Double
    public var isCarToCar: Bool
}

enum Collisions {
    static let wallRestitution = 0.35
    static let carRestitution = 0.5
    static let friction = 0.3

    /// Pushes the car out of walls and bounces it. Each car is modelled as two circles.
    static func resolveWalls(_ car: Car, track: Track, events: inout [ImpactEvent]) {
        let r = car.spec.collisionRadius
        for _ in 0..<2 {
            var touched = false
            let (front, rear) = car.collisionCircles
            for circle in [front, rear] {
                let offsetFromCenter = circle - car.position
                guard let contact = track.wallContact(center: circle, radius: r, level: car.level,
                                                      aboveObstacles: car.isAboveObstacles) else { continue }
                touched = true
                let n = contact.normal
                car.position += n * contact.depth

                let rc = offsetFromCenter - n * r
                let vp = car.pointVelocity(at: rc)
                let vn = vp.dot(n)
                guard vn < 0 else { continue }
                let invMassN = 1 + pow(rc.cross(n), 2) / car.spec.inertia
                let jn = -(1 + wallRestitution) * vn / invMassN
                car.applyImpulse(n * jn, at: rc)

                let t = n.perp
                let vt = car.pointVelocity(at: rc).dot(t)
                let invMassT = 1 + pow(rc.cross(t), 2) / car.spec.inertia
                let jt = clamp(-vt / invMassT, -friction * jn, friction * jn)
                car.applyImpulse(t * jt, at: rc)

                if -vn > 35 {
                    car.wallHits += 1
                    events.append(ImpactEvent(position: circle - n * r, strength: -vn, isCarToCar: false))
                }
            }
            if !touched { break }
        }
    }

    /// Circle-vs-circle contacts between two equal-mass cars.
    static func resolve(_ a: Car, _ b: Car, events: inout [ImpactEvent]) {
        let ra = a.spec.collisionRadius, rb = b.spec.collisionRadius
        // Broad phase.
        let reach = a.spec.length / 2 + b.spec.length / 2
        guard (a.position - b.position).lengthSquared < reach * reach else { return }

        let (af, ar) = a.collisionCircles
        let (bf, br) = b.collisionCircles
        for ca in [af, ar] {
            for cb in [bf, br] {
                let delta = ca - cb
                let d = delta.length
                let minD = ra + rb
                guard d < minD else { continue }
                let n = d > 1e-6 ? delta / d : Vec2(1, 0)
                let push = n * ((minD - d) / 2)
                a.position += push
                b.position -= push

                let contact = cb + n * rb
                let raOff = contact - a.position
                let rbOff = contact - b.position
                let vrel = a.pointVelocity(at: raOff) - b.pointVelocity(at: rbOff)
                let vn = vrel.dot(n)
                guard vn < 0 else { continue }
                let k = 2 + pow(raOff.cross(n), 2) / a.spec.inertia + pow(rbOff.cross(n), 2) / b.spec.inertia
                let j = -(1 + carRestitution) * vn / k
                a.applyImpulse(n * j, at: raOff)
                b.applyImpulse(-(n * j), at: rbOff)
                if -vn > 30 {
                    events.append(ImpactEvent(position: contact, strength: -vn, isCarToCar: true))
                }
            }
        }
    }
}
