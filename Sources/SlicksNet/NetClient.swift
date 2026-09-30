import Foundation
import SlicksCore
import SlicksLink

/// A player's connection to a host.
public final class NetClient {
    public enum Target {
        /// "host[:port]", typed by the player.
        case address(String)
        /// Known addresses, e.g. from a Bonjour listing.
        case addresses([SocketAddress])
        /// A room code: tried on `nearby` addresses (a Bonjour listing with that room) and,
        /// if a relay server is set, looked up there.
        case room(String, nearby: [SocketAddress])
    }

    public let name: String
    public let localPlayers: Int
    public private(set) var clientID: Int?
    public private(set) var lobby: LobbyInfo?
    /// How we reached the host, once connected.
    public var route: Route? { peer?.route }

    public var onWelcome: (() -> Void)?
    public var onLobby: ((LobbyInfo) -> Void)?
    public var onStart: ((_ raceID: UInt32, _ setup: RaceSetup, _ slots: [Int]) -> Void)?
    public var onSnapshot: ((_ raceID: UInt32, _ ack: UInt32, _ state: [UInt8]) -> Void)?
    public var onSand: ((_ raceID: UInt32, _ delta: [UInt8]) -> Void)?
    public var onRubber: ((_ raceID: UInt32, _ delta: [UInt8]) -> Void)?
    public var onRaceEnded: ((_ raceID: UInt32) -> Void)?
    /// Refused, disconnected, or never got through. The reason is shown to the player.
    public var onClose: ((String) -> Void)?
    /// Progress for the "connecting" screen.
    public var onStatus: ((String) -> Void)?

    private let target: Target
    private let secret: String
    private let relayText: String?
    private var transport: NetTransport?
    private var attempt: NetTransport.ConnectAttempt?
    private var peer: NetPeer?
    private var closed = false
    private var lookupTimer: DispatchSourceTimer?
    private var roomFound = false

    /// After this long without getting through directly, also try through the relay.
    static let relayFallbackDelay = 1.5
    public static var relayOnly = ProcessInfo.processInfo.environment["SLIDEWAYS_RELAY_ONLY"] != nil

    /// - Parameters:
    ///   - secret: the part of the code after the dash; empty if the game is open.
    ///   - relayServer: "host[:port]" of the rendezvous/relay server, for `.room` targets.
    public init(target: Target, name: String, localPlayers: Int, secret: String = "", relayServer: String? = nil) {
        self.target = target
        self.name = String(name.prefix(NetProtocol.maxNameLength))
        self.localPlayers = localPlayers
        self.secret = secret
        relayText = relayServer.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    deinit { lookupTimer?.cancel() }

    public var rtt: Double? { peer?.rtt }

    /// Simulated bad network on this player's outgoing packets (testing).
    public var networkConditions: NetConditions {
        get { transport?.socket.conditions ?? .none }
        set { transport?.socket.conditions = newValue }
    }
    public var isConnected: Bool { clientID != nil && !(peer?.isClosed ?? true) }

    public func connect() {
        let t: NetTransport
        do {
            t = try NetTransport(port: 0)
        } catch {
            return fail("can't open a network port: \(error)")
        }
        transport = t
        t.onRelayMessage = { [weak self] in self?.handleRelay($0) }

        switch target {
        case let .address(text):
            onStatus?("Looking up \(text)...")
            SocketAddress.resolve(text, defaultPort: NetProtocol.defaultPort) { [weak self] found in
                guard let self, !self.closed else { return }
                guard !found.isEmpty else { return self.fail("couldn't find \(text)") }
                self.begin(found.map(Route.direct))
            }
        case let .addresses(list):
            begin(list.map(Route.direct))
        case let .room(room, nearby):
            begin(nearby.map(Route.direct), timeout: 12)
            guard let relayText else {
                if nearby.isEmpty { fail("no game with code \(room) on this network (set a server to join over the internet)") }
                return
            }
            onStatus?("Looking for game \(room)...")
            SocketAddress.resolve(relayText, defaultPort: RelayMessage.defaultPort) { [weak self] found in
                guard let self, !self.closed else { return }
                guard let server = found.first else {
                    if nearby.isEmpty { self.fail("relay server \(relayText) not found") }
                    return
                }
                self.transport?.relayServer = server
                self.lookUp(room)
            }
        }
    }

    public func sendInput(seq: UInt32, inputs: [CarInput]) {
        peer?.send(.input(seq: seq, inputs: inputs))
    }

    public func disconnect(reason: String = "left the game") {
        guard !closed else { return }
        closed = true
        lookupTimer?.cancel()
        peer?.close(reason: reason)
        if let attempt { transport?.cancel(attempt) }
        let t = transport
        transport = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { t?.close() }
    }

    // MARK: Connecting

    private func begin(_ routes: [Route], timeout: Double = 10) {
        guard let transport else { return }
        onStatus?("Connecting...")
        attempt = transport.connect(routes: routes, secret: secret, timeout: timeout) { [weak self] result in
            guard let self, !self.closed else { return }
            self.lookupTimer?.cancel()
            switch result {
            case let .success(link):
                self.connected(link)
            case let .failure(error):
                if case .timedOut = error, !self.roomFound, case let .room(room, nearby) = self.target, nearby.isEmpty {
                    return self.fail("no game with code \(room) (check the code, or the host may have closed it)")
                }
                self.fail(error.description)
            }
        }
    }

    private func lookUp(_ room: String) {
        var tries = 0
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self, !self.roomFound else { return }
            tries += 1
            if tries > 12 { self.lookupTimer?.cancel(); return }
            self.transport?.sendToRelay(.lookup(room: room))
        }
        t.resume()
        lookupTimer = t
    }

    private func handleRelay(_ m: RelayMessage) {
        guard !closed, let attempt else { return }
        switch m {
        case let .peer(_, session, hostPublic, hostLocal):
            guard !roomFound else { return }
            roomFound = true
            lookupTimer?.cancel()
            onStatus?("Found the game, connecting...")
            // Straight to the host first: its public address (the relay has asked it to open
            // its router toward us) and its LAN addresses in case we're on the same network.
            // `SLIDEWAYS_RELAY_ONLY` skips that, to test the relayed path on one machine.
            if !Self.relayOnly {
                // LAN addresses come from the host via the server; only private ones make
                // sense, and anything else would have us send hellos to strangers.
                for a in [hostPublic] + hostLocal.filter(\.isLocalNetwork) { attempt.add(.direct(a)) }
            }
            if let server = transport?.relayServer {
                DispatchQueue.main.asyncAfter(deadline: .now() + (Self.relayOnly ? 0 : Self.relayFallbackDelay)) { [weak self] in
                    guard let self, !self.closed, self.peer == nil else { return }
                    self.onStatus?("Connecting through the relay...")
                    attempt.add(.relay(server: server, session: session))
                }
            }
        case let .notFound(room):
            guard !roomFound, case let .room(_, nearby) = target, nearby.isEmpty else { return }
            fail("no game with code \(room) (check the code, or the host may have closed it)")
        case let .refused(reason):
            if !roomFound { fail("relay server: \(reason)") }
        default:
            break
        }
    }

    private func connected(_ link: Link) {
        let p = NetPeer(link: link)
        peer = p
        p.onMessage = { [weak self] in self?.handle($0) }
        p.onClose = { [weak self] in self?.fail($0) }
        p.send(.hello(version: NetProtocol.version, name: name, localPlayers: localPlayers))
        onStatus?(link.route.isRelayed ? "Connected through the relay, waiting for the host..." : "Connected, waiting for the host...")
    }

    private func handle(_ message: NetMessage) {
        switch message {
        case let .welcome(id):
            clientID = id
            onWelcome?()
        case let .lobby(info):
            lobby = info
            onLobby?(info)
        case let .start(raceID, setup, slots):
            onStart?(raceID, setup, slots)
        case let .snapshot(raceID, ack, state):
            onSnapshot?(raceID, ack, state)
        case let .sand(raceID, delta):
            onSand?(raceID, delta)
        case let .rubber(raceID, delta):
            onRubber?(raceID, delta)
        case let .endRace(raceID):
            onRaceEnded?(raceID)
        default:
            break
        }
    }

    private func fail(_ reason: String) {
        guard !closed else { return }
        disconnect(reason: "connection problem")
        onClose?(reason)
    }
}
