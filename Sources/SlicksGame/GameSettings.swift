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
    public var playerNames: [String]?

    public init() {}

    private static let key = "raceSettings.v1"

    public static func load() -> RaceSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var s = try? JSONDecoder().decode(RaceSettings.self, from: data) else { return RaceSettings() }
          if s.playerNames == nil, let name = UserDefaults.standard.string(forKey: "online.name") {
            s.setPlayerName(name, for: 0)
          }
        return s
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static let aiNames = ["Rusty", "Nitro", "Skid", "Blitz", "Drifty", "Turbo", "Sprocket", "Gravel"]

    public func playerName(for player: Int) -> String {
        let name = playerNames?.indices.contains(player) == true ? playerNames![player] : ""
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Player \(player + 1)" : String(trimmed.prefix(16))
    }

    public mutating func setPlayerName(_ name: String, for player: Int) {
        guard (0..<4).contains(player) else { return }
        var names = playerNames ?? []
        while names.count <= player { names.append("") }
        names[player] = String(name.prefix(16))
        playerNames = names
    }

    /// Builds the starting grid: humans at the back, AI ahead of them like the original.
    public func entrants(seed: UInt64) -> [Entrant] {
        entrants(seed: seed, humans: (0..<humanPlayers).map { playerName(for: $0) })
    }

    /// Grid with these human drivers, who get input slots and liveries in order. AI fill the
    /// rest up to `aiOpponents`, never past the car limit.
    public func entrants(seed: UInt64, humans: [String]) -> [Entrant] {
        var rng = SplitMix64(seed: seed)
        var list: [Entrant] = []
        let names = RaceSettings.aiNames.shuffled(using: &rng)
        let availableCars = max(0, GameInfo.maxCars - humans.count)
        let minimumOpponents = humans.isEmpty && availableCars > 0 ? 1 : 0
        let opponentCount = clamp(aiOpponents, minimumOpponents, availableCars)
        for i in 0..<opponentCount {
            let jitter = Double.random(in: -0.12...0.12, using: &rng)
            list.append(Entrant(name: names[i % names.count], colorIndex: humans.count + i, playerIndex: nil,
                                aiSkill: clamp(aiSkill + jitter, 0, 1)))
        }
        for (p, name) in humans.enumerated() {
            list.append(Entrant(name: name, colorIndex: p, playerIndex: p))
        }
        return list
    }

    /// A race on `track` with these settings. Humans get input slots 0..<humanPlayers.
    public func raceSetup(track: TrackDefinition, seed: UInt64) -> RaceSetup {
        RaceSetup(track: track, entrants: entrants(seed: seed), laps: laps, seed: seed)
    }
}

/// Window preferences. Persisted between launches.
public enum DisplaySettings {
    private static let fullScreenKey = "display.fullScreen"

    /// Whether the window was last in full screen, so the next launch opens the same way.
    public static var fullScreen: Bool {
        get { UserDefaults.standard.bool(forKey: fullScreenKey) }
        set { UserDefaults.standard.set(newValue, forKey: fullScreenKey) }
    }
}

/// Built-in tracks followed by the player's custom tracks. Builds tracks once and keeps them.
public final class TrackLibrary {
    public static let shared = TrackLibrary()
    public private(set) var definitions: [TrackDefinition]
    private var built: [String: Track] = [:]

    init() {
        definitions = BuiltInTracks.all + TrackStore.loadAll()
    }

    /// Re-reads custom tracks from disk, dropping any cached builds of them.
    public func reload() {
        definitions = BuiltInTracks.all + TrackStore.loadAll()
        built = built.filter { !TrackStore.isCustom($0.key) }
    }

    public func index(of id: String) -> Int? {
        definitions.firstIndex { $0.id == id }
    }

    public func track(at index: Int) -> Track {
        let def = definitions[(index % definitions.count + definitions.count) % definitions.count]
        if let t = built[def.id] { return t }
        let t = Track(definition: def)
        built[def.id] = t
        return t
    }
}
