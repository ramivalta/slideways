import Foundation
import SlicksCore

public enum NetProtocol {
    /// Bump whenever messages or the simulation change in a way older builds can't follow.
    /// 2: encrypted UDP transport with join codes.
    /// 3: jumps and loose sand in race state.
    /// 4: slipstream.
    /// 5: AI routes back to the road from behind walls.
    /// 6: tire rubber on the road (its checksum in race state, and rubber deltas).
    /// 7: AI driver personalities (their seeds in race state).
    /// 8: stronger slipstream and rubber grip.
    /// 9: boat and footbridge track objects, urban theme (older builds can't decode tracks using them).
    /// 10: rounded-corner rect patches, square-ended capsules.
    /// 11: online championships (standings in the lobby).
    public static let version: UInt16 = 11
    /// UDP.
    public static let defaultPort: UInt16 = 47800
    public static let bonjourType = "_slideways._udp"
    /// Largest message accepted from a peer. Setups carry a whole track, so allow some room.
    static let maxFrame = 2 << 20
    public static let maxNameLength = 16
}

/// One entry in the lobby's player list.
public struct LobbyPlayer: Codable, Equatable, Sendable {
    /// 0 for the host, otherwise the client id.
    public var id: Int
    public var name: String
    public var localPlayers: Int
    /// Round trip to the host in milliseconds, when known.
    public var pingMs: Int?

    public init(id: Int, name: String, localPlayers: Int, pingMs: Int? = nil) {
        self.id = id
        self.name = name
        self.localPlayers = localPlayers
        self.pingMs = pingMs
    }
}

/// What everyone in the lobby sees. The host owns it and re-sends it on every change.
public struct LobbyInfo: Codable, Equatable, Sendable {
    public var players: [LobbyPlayer]
    public var trackName: String
    public var laps: Int
    public var aiOpponents: Int
    public var aiSkillName: String
    public var inRace: Bool
    /// Set when the host is running (or about to start) a championship.
    public var series: LobbySeries?

    public init(players: [LobbyPlayer], trackName: String, laps: Int, aiOpponents: Int, aiSkillName: String, inRace: Bool,
                series: LobbySeries? = nil) {
        self.players = players
        self.trackName = trackName
        self.laps = laps
        self.aiOpponents = aiOpponents
        self.aiSkillName = aiSkillName
        self.inRace = inRace
        self.series = series
    }

    public var humanCount: Int { players.reduce(0) { $0 + $1.localPlayers } }
}

/// A championship as the lobby shows it.
public struct LobbySeries: Codable, Equatable, Sendable {
    public struct Standing: Codable, Equatable, Sendable {
        public var name: String
        public var colorIndex: Int
        public var points: Int
        public var wins: Int
        /// Points scored in the latest round.
        public var last: Int?
        public var isHuman: Bool

        public init(name: String, colorIndex: Int, points: Int, wins: Int, last: Int?, isHuman: Bool) {
            self.name = name
            self.colorIndex = colorIndex
            self.points = points
            self.wins = wins
            self.last = last
            self.isHuman = isHuman
        }
    }

    public var roundsCompleted: Int
    public var rounds: Int
    /// Empty until the first round starts.
    public var standings: [Standing]

    public init(roundsCompleted: Int, rounds: Int, standings: [Standing]) {
        self.roundsCompleted = roundsCompleted
        self.rounds = rounds
        self.standings = standings
    }

    public var isComplete: Bool { roundsCompleted >= rounds }
}

public enum NetMessage: Equatable {
    // Client to host.
    case hello(version: UInt16, name: String, localPlayers: Int)
    /// Latest input for each of the client's local players, tagged with the client's tick.
    case input(seq: UInt32, inputs: [CarInput])

    // Host to client. Refusals (full, wrong code, race running) end the link with a reason.
    case welcome(clientID: Int)
    case lobby(LobbyInfo)
    /// A race begins. `slots` are the input slots this client drives, one per local player.
    case start(raceID: UInt32, setup: RaceSetup, slots: [Int])
    /// Authoritative race state. `ack` is the newest input seq from this client the host had
    /// applied, so the client knows which of its inputs to replay on top.
    case snapshot(raceID: UInt32, ack: UInt32, state: [UInt8])
    /// The host left the race screen; everyone goes back to the lobby.
    case endRace(raceID: UInt32)
    /// Loose sand that changed (an encoded `SandDelta`). Reliable and in order.
    case sand(raceID: UInt32, delta: [UInt8])
    /// Tire rubber that changed (an encoded `RubberDelta`). Reliable and in order.
    case rubber(raceID: UInt32, delta: [UInt8])

    // Either way.
    case ping(UInt64)
    case pong(UInt64)

    private enum Kind: UInt8 {
        case hello = 1, input, welcome, lobby, start, snapshot, endRace, ping, pong, sand, rubber
    }

    public func encoded() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case let .hello(version, name, localPlayers):
            w.u8(Kind.hello.rawValue); w.u16(version); w.string(name); w.u8(UInt8(clamping: localPlayers))
        case let .input(seq, inputs):
            w.u8(Kind.input.rawValue); w.u32(seq); w.u8(UInt8(clamping: inputs.count))
            for i in inputs.prefix(255) { i.write(to: &w) }
        case let .welcome(id):
            w.u8(Kind.welcome.rawValue); w.u32(UInt32(clamping: id))
        case let .lobby(info):
            w.u8(Kind.lobby.rawValue); w.blob((try? JSONEncoder().encode(info)) ?? Data())
        case let .start(raceID, setup, slots):
            w.u8(Kind.start.rawValue); w.u32(raceID)
            w.blob((try? JSONEncoder().encode(setup)) ?? Data())
            w.u8(UInt8(clamping: slots.count))
            for s in slots.prefix(255) { w.u8(UInt8(clamping: s)) }
        case let .snapshot(raceID, ack, state):
            w.u8(Kind.snapshot.rawValue); w.u32(raceID); w.u32(ack); w.blob(Data(state))
        case let .endRace(raceID):
            w.u8(Kind.endRace.rawValue); w.u32(raceID)
        case let .ping(t):
            w.u8(Kind.ping.rawValue); w.u64(t)
        case let .pong(t):
            w.u8(Kind.pong.rawValue); w.u64(t)
        case let .sand(raceID, delta):
            w.u8(Kind.sand.rawValue); w.u32(raceID); w.blob(Data(delta))
        case let .rubber(raceID, delta):
            w.u8(Kind.rubber.rawValue); w.u32(raceID); w.blob(Data(delta))
        }
        return w.bytes
    }

    public init(decoding bytes: [UInt8]) throws {
        var r = ByteReader(bytes)
        guard let kind = Kind(rawValue: try r.u8()) else { throw WireError.invalid("message type") }
        switch kind {
        case .hello:
            self = .hello(version: try r.u16(), name: try r.string(maxLength: 64), localPlayers: Int(try r.u8()))
        case .input:
            let seq = try r.u32()
            let n = Int(try r.u8())
            guard n <= 8 else { throw WireError.invalid("input count") }
            self = .input(seq: seq, inputs: try (0..<n).map { _ in try CarInput(reading: &r) })
        case .welcome:
            self = .welcome(clientID: Int(try r.u32()))
        case .lobby:
            self = .lobby(try JSONDecoder().decode(LobbyInfo.self, from: r.blob(maxLength: 64 << 10)))
        case .start:
            let id = try r.u32()
            let setup = try JSONDecoder().decode(RaceSetup.self, from: r.blob(maxLength: NetProtocol.maxFrame))
            let n = Int(try r.u8())
            guard n <= 8 else { throw WireError.invalid("slot count") }
            self = .start(raceID: id, setup: setup, slots: try (0..<n).map { _ in Int(try r.u8()) })
        case .snapshot:
            let id = try r.u32(), ack = try r.u32()
            self = .snapshot(raceID: id, ack: ack, state: [UInt8](try r.blob(maxLength: 64 << 10)))
        case .endRace:
            self = .endRace(raceID: try r.u32())
        case .ping:
            self = .ping(try r.u64())
        case .pong:
            self = .pong(try r.u64())
        case .sand:
            let id = try r.u32()
            self = .sand(raceID: id, delta: [UInt8](try r.blob(maxLength: NetProtocol.maxFrame)))
        case .rubber:
            let id = try r.u32()
            self = .rubber(raceID: id, delta: [UInt8](try r.blob(maxLength: NetProtocol.maxFrame)))
        }
        guard r.isAtEnd else { throw WireError.invalid("trailing bytes") }
    }
}
