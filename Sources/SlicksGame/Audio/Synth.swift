import Foundation
import SlicksCore

/// Sound parameters for one kart, set once per frame by the game. The synth smooths them.
public struct CarSound: Sendable, Equatable {
    /// Engine speed: 0 at idle, 1 at top speed.
    public var rpm: Double = 0
    /// Engine load: 0 off the gas, 1 flat out. Makes the engine louder and brighter.
    public var throttle: Double = 0
    /// Tire squeal intensity, 0...1.
    public var screech: Double = 0
    /// Squeal pitch multiplier: 1 on asphalt, lower and duller on ice.
    public var screechPitch: Double = 1
    /// Off-road surface noise (grass, sand), 0...1.
    public var rumble: Double = 0
    /// Engine volume. 0 silences the voice.
    public var engineGain: Double = 0
    /// Volume for tire squeal and rumble.
    public var tireGain: Double = 0
    /// Stereo position, -1 left ... 1 right.
    public var pan: Double = 0

    public init() {}
}

/// One-shot sounds.
public enum SoundEffect: Sendable, Equatable {
    /// Strength is 0...1.
    case wallHit(strength: Double, pan: Double)
    case carHit(strength: Double, pan: Double)
    /// Countdown tick (3, 2, 1) and the start signal.
    case countdown
    case go
    case lap
    case finish
    case menuMove
    case menuSelect
}

/// Procedural sound: kart engines, tires and effects, all synthesized, no samples.
///
/// Not thread-safe. The audio render thread owns an instance; the game talks to it through
/// `SoundSystem`. It's also usable offline (SlicksSim renders it to WAV files for checks).
public final class Synth {
    public let sampleRate: Double
    /// Final output gain, 0...1.
    public var masterVolume = 0.8

    private var voices: [KartVoice] = []
    private var shots: [OneShot] = []
    private var noise = Noise(seed: 0x5EED_CAFE)
    private var master = 0.0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// Replaces the kart parameters. Voices are matched by index.
    public func setCars(_ cars: [CarSound]) {
        while voices.count < cars.count { voices.append(KartVoice(seed: UInt64(voices.count + 1) &* 0x9E37_79B9)) }
        for i in voices.indices {
            voices[i].target = i < cars.count ? cars[i] : CarSound()
        }
    }

    public func trigger(_ effect: SoundEffect) {
        guard shots.count < 32 else { return }
        switch effect {
        case let .wallHit(strength, pan):
            shots.append(OneShot(kind: .thump, amp: 0.25 + 0.75 * strength, pan: pan, duration: 0.35))
        case let .carHit(strength, pan):
            shots.append(OneShot(kind: .knock, amp: 0.2 + 0.6 * strength, pan: pan, duration: 0.18))
        case .countdown:
            shots.append(OneShot(kind: .beep(587.3), amp: 0.32, pan: 0, duration: 0.18))
        case .go:
            shots.append(OneShot(kind: .beep(1174.7), amp: 0.34, pan: 0, duration: 0.5))
        case .lap:
            for (i, f) in [1046.5, 1568.0].enumerated() {
                shots.append(OneShot(kind: .beep(f), amp: 0.24, pan: 0, duration: 0.22, delay: Double(i) * 0.09))
            }
        case .finish:
            for (i, f) in [523.3, 659.3, 784.0, 1046.5].enumerated() {
                shots.append(OneShot(kind: .beep(f), amp: 0.26, pan: 0, duration: i == 3 ? 0.7 : 0.2, delay: Double(i) * 0.12))
            }
        case .menuMove:
            shots.append(OneShot(kind: .beep(1760), amp: 0.08, pan: 0, duration: 0.035))
        case .menuSelect:
            for (i, f) in [880.0, 1318.5].enumerated() {
                shots.append(OneShot(kind: .beep(f), amp: 0.18, pan: 0, duration: 0.12, delay: Double(i) * 0.06))
            }
        }
    }

    /// Renders `frames` samples of stereo audio, overwriting the buffers.
    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        for i in 0..<frames { left[i] = 0; right[i] = 0 }
        for v in voices.indices {
            voices[v].render(frames: frames, sampleRate: sampleRate, left: left, right: right)
        }
        var k = 0
        while k < shots.count {
            shots[k].render(frames: frames, sampleRate: sampleRate, noise: &noise, left: left, right: right)
            if shots[k].isDone { shots.swapAt(k, shots.count - 1); shots.removeLast() } else { k += 1 }
        }
        // Master gain (smoothed so volume changes don't click) and a soft limiter.
        let step = 1 - exp(-1 / (0.03 * sampleRate))
        for i in 0..<frames {
            master += (masterVolume - master) * step
            let g = Float(master)
            left[i] = tanh(left[i]) * g
            right[i] = tanh(right[i]) * g
        }
    }

    /// Convenience for offline rendering: returns interleaved-free stereo arrays.
    public func render(seconds: Double) -> (left: [Float], right: [Float]) {
        let n = Int(seconds * sampleRate)
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        let block = 512
        var start = 0
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                while start < n {
                    let count = min(block, n - start)
                    render(frames: count, left: lp.baseAddress! + start, right: rp.baseAddress! + start)
                    start += count
                }
            }
        }
        return (l, r)
    }
}

// MARK: - Voices

/// Engine, tire squeal and off-road rumble for one kart.
private struct KartVoice {
    var target = CarSound()
    private var cur = CarSound()
    private var noise: Noise
    private var phase = 0.0
    private var periodScale = 1.0
    private var dcBlock = OnePole()
    private var tone = OnePole()
    private var squealPhase = 0.0
    private var vibratoPhase = 0.0
    private var squealBand = Biquad()
    private var rumble1 = OnePole(), rumble2 = OnePole()

    init(seed: UInt64) { noise = Noise(seed: seed) }

    private var isSilent: Bool {
        cur.engineGain < 1e-4 && target.engineGain < 1e-4
            && (cur.tireGain < 1e-4 || (cur.screech < 1e-4 && cur.rumble < 1e-4))
            && (target.tireGain < 1e-4 || (target.screech < 1e-4 && target.rumble < 1e-4))
    }

    mutating func render(frames: Int, sampleRate sr: Double, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard !isSilent else { cur = target; cur.engineGain = 0; cur.tireGain = 0; return }
        // Parameter smoothing: rpm follows quickly but not instantly, like a flywheel.
        let dt = 1 / sr
        let kRpm = 1 - exp(-dt / 0.07), kFast = 1 - exp(-dt / 0.025), kGain = 1 - exp(-dt / 0.05)
        // Filter coefficients change slowly, so update them once per block.
        squealBand.setBandpass(frequency: 1900 * max(0.3, cur.screechPitch), q: 5, sampleRate: sr)
        rumble1.setCutoff(260, sampleRate: sr)
        rumble2.setCutoff(260, sampleRate: sr)
        dcBlock.setCutoff(35, sampleRate: sr)

        for i in 0..<frames {
            cur.rpm += (target.rpm - cur.rpm) * kRpm
            cur.throttle += (target.throttle - cur.throttle) * kFast
            cur.screech += (target.screech - cur.screech) * kFast
            cur.screechPitch += (target.screechPitch - cur.screechPitch) * kGain
            cur.rumble += (target.rumble - cur.rumble) * kFast
            cur.engineGain += (target.engineGain - cur.engineGain) * kGain
            cur.tireGain += (target.tireGain - cur.tireGain) * kGain
            cur.pan += (target.pan - cur.pan) * kGain

            var sample = 0.0

            // Engine: a single-cylinder two-stroke. Each firing is a sharp pulse with a bit of
            // exhaust rasp; slightly uneven periods keep it from sounding like a pure tone.
            if cur.engineGain > 1e-4 {
                let freq = (46 + 175 * cur.rpm) * (1 + 0.06 * cur.throttle)
                phase += freq * dt * periodScale
                if phase >= 1 {
                    phase -= 1
                    periodScale = 1 + (noise.next() * 0.035)
                }
                let firing = exp(-phase * 7)
                let body = firing + 0.35 * sin(2 * .pi * phase) + 0.12 * sin(4 * .pi * phase)
                let rasp = noise.next() * exp(-phase * 11) * (0.2 + 0.4 * cur.throttle)
                let raw = body + rasp
                let noDC = raw - dcBlock.process(raw)
                tone.setCutoff(450 + 2600 * cur.throttle + 1400 * cur.rpm, sampleRate: sr)
                let shaped = tone.process(noDC)
                let loud = (0.4 + 0.6 * cur.throttle) * (0.75 + 0.45 * cur.rpm)
                sample += shaped * loud * cur.engineGain * 0.55
            }

            // Tires: band-passed hiss plus a wavering tonal squeal.
            if cur.tireGain > 1e-4, cur.screech > 1e-4 {
                vibratoPhase += 6.5 * dt
                if vibratoPhase >= 1 { vibratoPhase -= 1 }
                let squealFreq = (980 + 320 * cur.screech) * cur.screechPitch * (1 + 0.025 * sin(2 * .pi * vibratoPhase))
                squealPhase += squealFreq * dt
                if squealPhase >= 1 { squealPhase -= 1 }
                let hiss = squealBand.process(noise.next())
                let tone = sin(2 * .pi * squealPhase) * 0.5 + sin(4 * .pi * squealPhase) * 0.12
                let level = pow(cur.screech, 1.4)
                sample += (hiss * 1.6 + tone * 0.55) * level * cur.tireGain * 0.8
            }

            // Off-road: low rumble of gravel and grass under the tires.
            if cur.tireGain > 1e-4, cur.rumble > 1e-4 {
                let r = rumble2.process(rumble1.process(noise.next()))
                sample += r * cur.rumble * cur.tireGain * 2.2
            }

            let angle = (clamp(cur.pan, -1, 1) + 1) * .pi / 4
            left[i] += Float(sample * cos(angle))
            right[i] += Float(sample * sin(angle))
        }
    }
}

private struct OneShot {
    enum Kind {
        case thump
        case knock
        case beep(Double)
    }

    let kind: Kind
    let amp: Double
    let pan: Double
    let duration: Double
    /// Seconds into the sound; negative while waiting out a delay.
    private var t: Double
    private var phase = 0.0
    private var lowpass = OnePole()

    init(kind: Kind, amp: Double, pan: Double, duration: Double, delay: Double = 0) {
        self.kind = kind
        self.amp = amp
        self.pan = pan
        self.duration = duration
        t = -delay
    }

    var isDone: Bool { t >= duration }

    mutating func render(frames: Int, sampleRate sr: Double, noise: inout Noise,
                         left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let dt = 1 / sr
        let angle = (clamp(pan, -1, 1) + 1) * .pi / 4
        let gl = cos(angle), gr = sin(angle)
        switch kind {
        case .thump: lowpass.setCutoff(700, sampleRate: sr)
        case .knock: lowpass.setCutoff(2400, sampleRate: sr)
        case .beep: break
        }
        for i in 0..<frames {
            defer { t += dt }
            guard t >= 0, t < duration else { continue }
            var s = 0.0
            switch kind {
            case .thump:
                // Body of the kart hitting tires: a falling low tone and a burst of noise.
                let f = 42 + 95 * exp(-t * 22)
                phase += f * dt
                s = sin(2 * .pi * phase) * exp(-t * 13) + lowpass.process(noise.next()) * exp(-t * 35) * 1.4
            case .knock:
                // Two karts bumping: shorter and higher, with a plastic click.
                let f = 95 + 190 * exp(-t * 30)
                phase += f * dt
                s = sin(2 * .pi * phase) * exp(-t * 24) * 0.9 + lowpass.process(noise.next()) * exp(-t * 70) * 1.2
            case let .beep(f):
                phase += f * dt
                let x = 2 * .pi * phase
                // Soft square: a few odd harmonics, for a chunky retro beep.
                let wave = sin(x) + 0.28 * sin(3 * x) + 0.12 * sin(5 * x)
                let attack = min(1, t / 0.004)
                let release = min(1, (duration - t) / 0.03)
                s = wave * attack * release * exp(-t * 2.2 / duration)
            }
            let out = s * amp
            left[i] += Float(out * gl)
            right[i] += Float(out * gr)
        }
    }
}

// MARK: - DSP building blocks

private struct Noise {
    private var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    /// White noise in -1...1.
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(Int64(bitPattern: state)) / Double(Int64.max)
    }
}

/// One-pole low-pass.
private struct OnePole {
    private var a = 1.0
    private var y = 0.0
    mutating func setCutoff(_ hz: Double, sampleRate sr: Double) {
        a = 1 - exp(-2 * .pi * min(hz, sr * 0.45) / sr)
    }
    mutating func process(_ x: Double) -> Double {
        y += a * (x - y)
        return y
    }
}

/// RBJ biquad, used as a band-pass.
private struct Biquad {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    mutating func setBandpass(frequency f: Double, q: Double, sampleRate sr: Double) {
        let w0 = 2 * .pi * min(f, sr * 0.45) / sr
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b1 = 0
        b2 = -alpha / a0
        a1 = -2 * cos(w0) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}
