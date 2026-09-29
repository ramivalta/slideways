import Foundation
import SlicksCore

public enum GameInfo {
    /// Working title. Change freely.
    public static let title = "Slideways"
    /// Logical scene size: a 960x600 track plus a 40pt HUD strip on top.
    public static let sceneSize = CGSize(width: 960, height: 640)
    public static let maxCars = 8
}

/// Race setup chosen in the menu. Persisted between launches.
public struct RaceSettings: Codable, Sendable, Equatable {
    public var trackIndex = 0
    public var laps = 5
    public var humanPlayers = 1
    public var aiOpponents = 5
    public var aiSkill = 0.75

    public init() {}

    private static let key = "raceSettings.v1"

    public static func load() -> RaceSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(RaceSettings.self, from: data) else { return RaceSettings() }
        return s
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static let aiNames = ["Rusty", "Nitro", "Skid", "Blitz", "Drifty", "Turbo", "Sprocket", "Gravel"]

    /// Builds the starting grid: humans at the back, AI ahead of them like the original.
    public func entrants(seed: UInt64) -> [Entrant] {
        var rng = SplitMix64(seed: seed)
        var list: [Entrant] = []
        let names = RaceSettings.aiNames.shuffled(using: &rng)
        for i in 0..<aiOpponents {
            let jitter = Double.random(in: -0.12...0.12, using: &rng)
            list.append(Entrant(name: names[i % names.count], colorIndex: humanPlayers + i, playerIndex: nil,
                                aiSkill: clamp(aiSkill + jitter, 0, 1)))
        }
        for p in 0..<humanPlayers {
            list.append(Entrant(name: "Player \(p + 1)", colorIndex: p, playerIndex: p))
        }
        return list
    }
}

/// Builds tracks and their images once and keeps them around.
public final class TrackLibrary {
    public static let shared = TrackLibrary()
    public let definitions = BuiltInTracks.all
    private var built: [String: Track] = [:]

    public func track(at index: Int) -> Track {
        let def = definitions[(index % definitions.count + definitions.count) % definitions.count]
        if let t = built[def.id] { return t }
        let t = Track(definition: def)
        built[def.id] = t
        return t
    }
}
