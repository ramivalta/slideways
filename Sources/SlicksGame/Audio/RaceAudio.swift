import Foundation
import SlicksCore

/// Turns race state into sound: kart parameters every frame, plus one-shots for impacts,
/// the countdown and laps. Pure logic with no audio output, so SlicksSim can drive it offline.
public final class RaceAudio {
    /// Engine and tire volume for computer karts relative to players, so the player's own
    /// kart stays on top of the pack.
    static let aiEngineGain = 0.3
    static let aiTireGain = 0.55

    private var lastCountdown: Int?
    private var saidGo = false
    private var laps: [Int]
    private var recentHits: [(position: Vec2, time: Double)] = []
    /// Kart volume once the race is over: fades from 1 to 0 so the results screen is quiet.
    private var endFade = 1.0
    static let endFadeDuration = 0.8

    /// Input slots of the players at this machine; nil means every human is local.
    private let localSlots: Set<Int>?

    /// - Parameter localSlots: online, the slots played here. Other humans sound like AI karts
    ///   and don't get lap chimes.
    public init(race: Race, localSlots: Set<Int>? = nil) {
        laps = race.cars.map(\.lapsCompleted)
        self.localSlots = localSlots
    }

    private func isLocalPlayer(_ car: Car) -> Bool {
        guard !car.isAI, let slot = car.playerIndex else { return false }
        return localSlots?.contains(slot) ?? true
    }

    /// - Parameters:
    ///   - humanInputs: live input per player slot, so players can rev on the grid.
    ///   - paused: silences karts while the pause menu is up.
    ///   - dt: frame time, for the fade-out after the race.
    public func update(race: Race, impacts: [ImpactEvent], humanInputs: [CarInput], paused: Bool,
                       dt: Double = 1.0 / 60) -> (cars: [CarSound], effects: [SoundEffect]) {
        var effects: [SoundEffect] = []
        let track = race.track
        if race.phase == .finished {
            endFade = max(0, endFade - dt / Self.endFadeDuration)
        }

        // Countdown ticks and the start signal.
        if race.time < 0 {
            let n = Int(ceil(-race.time))
            if n != lastCountdown, n <= 3 { effects.append(.countdown) }
            lastCountdown = n
        } else if !saidGo {
            saidGo = true
            effects.append(.go)
        }

        // Lap and finish chimes, for players only.
        for car in race.cars {
            defer { laps[car.id] = car.lapsCompleted }
            guard isLocalPlayer(car), car.lapsCompleted > laps[car.id] else { continue }
            effects.append(car.isFinished ? .finish : .lap)
        }

        effects += impactEffects(impacts, time: race.time, width: Double(track.width))

        let hasHumans = race.cars.contains(where: isLocalPlayer)
        let cars = race.cars.map { car -> CarSound in
            var s = CarSound()
            let input: CarInput
            if race.phase == .countdown, let p = car.playerIndex, p < humanInputs.count {
                input = humanInputs[p]
            } else {
                input = car.lastInput
            }
            s.throttle = clamp(input.throttle, 0, 1)

            // Direct drive: revs follow road speed. Wheelspin and loose surfaces let the engine
            // flare above it. On the grid a player can blip the throttle.
            let props = car.surface.properties
            var rpm = clamp(abs(car.forwardSpeed) / car.spec.maxSpeed, 0, 1)
            if race.phase == .countdown { rpm = s.throttle * 0.7 }
            rpm += s.throttle * ((car.isWheelspinning ? 0.18 : 0) + (1 - props.traction) * 0.35)
            s.rpm = clamp(rpm, 0, 1)

            // Nothing under the tires in the air.
            switch car.isAirborne ? .wall : car.surface {
            case .asphalt, .curb, .ice:
                let slide = clamp((car.slip - 22) / 110, 0, 1) * clamp(car.speed / 40, 0, 1)
                let braking = car.isBraking && car.speed > 70 ? 0.35 + 0.3 * clamp((car.speed - 70) / 200, 0, 1) : 0
                let spin = car.isWheelspinning ? 0.4 : 0
                s.screech = max(slide, braking, spin) * (car.surface == .ice ? 0.45 : 1)
                s.screechPitch = car.surface == .ice ? 0.62 : car.surface == .curb ? 0.9 : 1
            case .grass, .sand, .mud, .water:
                let loudness: Double = switch car.surface {
                case .sand: 1.2
                case .mud: 1.1
                case .water: 0.8
                default: 1
                }
                s.rumble = clamp(car.speed / 220, 0, 1) * loudness
            case .wall:
                break
            }

            let isPlayer = isLocalPlayer(car)
            s.engineGain = isPlayer ? 1 : hasHumans ? Self.aiEngineGain : Self.aiEngineGain * 1.5
            s.tireGain = isPlayer ? 1 : Self.aiTireGain
            s.pan = (car.position.x / Double(track.width) * 2 - 1) * 0.75

            if paused {
                s.engineGain = 0
                s.tireGain = 0
            } else if race.phase == .finished {
                s.engineGain *= endFade
                s.tireGain = 0
            }
            return s
        }
        return (cars, effects)
    }

    /// Picks the impacts worth hearing: the strongest few per frame, and not the same spot over
    /// and over while a kart grinds along a wall.
    private func impactEffects(_ impacts: [ImpactEvent], time: Double, width: Double) -> [SoundEffect] {
        recentHits.removeAll { time - $0.time > 0.12 }
        var out: [SoundEffect] = []
        for hit in impacts.sorted(by: { $0.strength > $1.strength }) where out.count < 3 {
            if recentHits.contains(where: { ($0.position - hit.position).length < 30 }) { continue }
            recentHits.append((hit.position, time))
            let pan = (hit.position.x / width * 2 - 1) * 0.75
            if hit.isCarToCar {
                out.append(.carHit(strength: clamp((hit.strength - 30) / 180, 0, 1), pan: pan))
            } else {
                out.append(.wallHit(strength: clamp((hit.strength - 35) / 220, 0, 1), pan: pan))
            }
        }
        return out
    }
}
