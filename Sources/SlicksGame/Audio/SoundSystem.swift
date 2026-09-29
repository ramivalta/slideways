import AVFoundation
import Foundation
import os

/// Plays the game's synthesized sound through AVAudioEngine.
///
/// The game thread posts kart parameters and one-shot effects; the audio render thread picks
/// them up without ever blocking on the game (it skips a hand-off if the lock is busy).
public final class SoundSystem {
    public static let shared = SoundSystem()

    /// Volume steps offered in the menu.
    public static let volumeSteps: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 1.0]
    private static let volumeKey = "soundVolume.v1"

    private struct Pending: Sendable {
        var cars: [CarSound]?
        var effects: [SoundEffect] = []
        var volume = 0.8
    }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let pending = OSAllocatedUnfairLock(initialState: Pending())
    private var isRunning = false
    private var configObserver: NSObjectProtocol?

    /// Master volume, 0...1. Persisted.
    public var volume: Double {
        didSet {
            volume = min(max(volume, 0), 1)
            UserDefaults.standard.set(volume, forKey: Self.volumeKey)
            let v = volume
            pending.withLock { $0.volume = v }
        }
    }

    private init() {
        let stored = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double
        volume = stored ?? 0.8
        let v = volume
        pending.withLock { $0.volume = v }
    }

    /// Starts audio output. Safe to call more than once. Failures (no output device) are logged
    /// and the game carries on silently.
    public func start() {
        guard !isRunning else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        if source == nil {
            var rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if rate <= 0 { rate = 48_000 }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
            let synth = Synth(sampleRate: rate)
            let pending = self.pending
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
                // Take whatever the game posted since the last buffer, if the lock is free.
                let taken = pending.withLockIfAvailable { state -> Pending in
                    let copy = state
                    state.cars = nil
                    state.effects.removeAll(keepingCapacity: true)
                    return copy
                }
                if let taken {
                    if let cars = taken.cars { synth.setCars(cars) }
                    for e in taken.effects { synth.trigger(e) }
                    synth.masterVolume = taken.volume
                }
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                guard buffers.count >= 2,
                      let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                synth.render(frames: Int(frameCount), left: l, right: r)
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            source = node

            // Output device changes (headphones, AirPlay) stop the engine; start it again.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.isRunning = false
                self.start()
            }
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            print("Sound unavailable: \(error.localizedDescription)")
        }
    }

    /// Replaces all kart sounds. Pass an empty array to silence engines and tires.
    public func setCars(_ cars: [CarSound]) {
        pending.withLock { $0.cars = cars }
    }

    public func play(_ effect: SoundEffect) {
        guard volume > 0 else { return }
        pending.withLock { state in
            if state.effects.count < 32 { state.effects.append(effect) }
        }
    }
}
