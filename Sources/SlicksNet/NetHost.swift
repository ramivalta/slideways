import Foundation
import SlicksCore
import SlicksLink

/// Hosts an online game: accepts players, keeps the lobby in sync, and relays inputs and
/// race state. The host's own machine runs the authoritative race (see `HostRaceController`).
///
/// Getting in takes the game's code, `ROOM-SECRET`. The room part finds the game (on the local
/// network or through the relay server); the secret part is mixed into the encryption keys and
/// never sent. With `requireCode` off, the room alone is enough.
public final class NetHost {
    public final class Client {
        public let id: Int
        public let name: String
        public let localPlayers: Int
        let peer: NetPeer
        /// Newest input seq received and the inputs that came with it.
        public internal(set) var lastSeq: UInt32 = 0
        public internal(set) var inputs: [CarInput] = []
        /// Input slots in the current race.
        public internal(set) var slots: [Int] = []

        init(id: Int, name: String, localPlayers: Int, peer: NetPeer) {
            self.id = id
            self.name = name
            self.localPlayers = localPlayers
            self.peer = peer
        }

        public var pingMs: Int? { peer.rtt.map { Int(($0 * 1000).rounded()) } }
        public var isRelayed: Bool { peer.route.isRelayed }
    }

    public enum RelayState: Equatable {
        case off
        case connecting
        case registered(publicAddress: SocketAddress)
        case failed(String)
    }

    public let name: String
    public let localPlayers: Int
    public private(set) var clients: [Client] = []
    public private(set) var port: UInt16?
    /// Race in progress, if any. New players are turned away until it ends.
    public private(set) var raceID: UInt32?

    /// Finds the game. Assigned by the relay server when one is set, otherwise made up here.
    public private(set) var room = RoomCode.random(length: 4)
    /// Lets you in. Never leaves this machine except on the host's screen.
    public private(set) var secret = RoomCode.random(length: 4)
    public var requireCode: Bool {
        didSet { applyAccess() }
    }
    /// What players type to join.
    public var joinCode: String { requireCode ? "\(room)-\(secret)" : room }

    public private(set) var relayState = RelayState.off
    public var portMapping: PortMapper.State { mapper?.state ?? .off }

    /// Player list, pings, code or reachability changed: refresh the lobby screen.
    public var onChange: (() -> Void)?
    /// A player dropped out. Called before `onChange`.
    public var onClientLeft: ((Client) -> Void)?
    /// The socket is open, on this port.
    public var onListening: ((UInt16) -> Void)?
    public var onError: ((String) -> Void)?
    /// Last say on a player joining, by name and local player count: a refusal reason, or nil to let them in.
    public var admitPlayer: ((_ name: String, _ localPlayers: Int) -> String?)?

    private var transport: NetTransport?
    private var waiting: [ObjectIdentifier: NetPeer] = [:]
    private var nextID = 1
    private var nextRaceID: UInt32 = 1
    private var lobby: LobbyInfo?
    private var timer: DispatchSourceTimer?
    private let advertise: Bool
    private let relayText: String?
    private let mapPort: Bool
    private var advertiser: BonjourAdvertiser?
    private var mapper: PortMapper?
    private let hostKey = randomBytes(RelayMessage.hostKeyLength)
    private var banned: Set<[UInt8]> = []
    private var failures: [[UInt8]: [Double]] = [:]
    private var recentFailures: [Double] = []
    private var recentIntros: [Double] = []

    /// Wrong codes allowed per player (IP or relay session) per minute, and for everyone together.
    static let failuresPerSource = 5
    static let failuresOverall = 30

    /// - Parameters:
    ///   - advertise: list the game on the local network over Bonjour.
    ///   - relayServer: "host[:port]" of a rendezvous/relay server, for joining by code over the internet.
    ///   - mapPort: ask the router to forward the port (NAT-PMP, then UPnP).
    public init(name: String, localPlayers: Int, requireCode: Bool = true, advertise: Bool = true,
                relayServer: String? = nil, mapPort: Bool = true) {
        self.name = String(name.prefix(NetProtocol.maxNameLength))
        self.localPlayers = localPlayers
        self.requireCode = requireCode
        self.advertise = advertise
        relayText = relayServer.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.mapPort = mapPort
    }

    deinit { stop(reason: "the host closed the game") }

    public var humanCount: Int { localPlayers + clients.reduce(0) { $0 + $1.localPlayers } }

    /// Simulated bad network on this host's outgoing packets (testing).
    public var networkConditions: NetConditions {
        get { transport?.socket.conditions ?? .none }
        set { transport?.socket.conditions = newValue }
    }

    /// Opens the UDP port (`port`, or any free one if it's taken) and starts announcing the game.
    public func start(port wanted: UInt16 = NetProtocol.defaultPort) {
        let t: NetTransport
        do {
            t = try NetTransport(port: wanted)
        } catch let e as SocketError where e.isAddressInUse && wanted != 0 {
            guard let any = try? NetTransport(port: 0) else { return fail("can't open a network port") }
            t = any
        } catch {
            return fail("can't host: \(error)")
        }
        transport = t
        port = t.port
        t.acceptsConnections = true
        t.admit = { [weak self] route in self?.admit(route) }
        t.admitGuess = { [weak self] route in self?.guessLimit(route) }
        t.onIncoming = { [weak self] link in self?.accept(link) }
        t.onBadSecret = { [weak self] route in self?.recordFailure(route) }
        t.onRelayMessage = { [weak self] in self?.handleRelay($0) }
        applyAccess()

        if advertise {
            advertiser = BonjourAdvertiser(name: name, port: t.port, txt: txtRecord())
        }
        if mapPort {
            let m = PortMapper(internalPort: t.port)
            m.onChange = { [weak self] in self?.onChange?() }
            m.start()
            mapper = m
        }
        if let relayText {
            relayState = .connecting
            SocketAddress.resolve(relayText, defaultPort: RelayMessage.defaultPort) { [weak self] found in
                guard let self, let server = found.first else {
                    self?.relayState = .failed("relay server not found")
                    self?.onChange?()
                    return
                }
                self.transport?.relayServer = server
                self.registerWithRelay()
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        var ticks = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            ticks += 1
            // Re-register often enough that the server and our router both keep us.
            if ticks % 10 == 0 { self.registerWithRelay() }
            if case .connecting = self.relayState, ticks % 2 == 0 { self.registerWithRelay() }
            if case .connecting = self.relayState, ticks >= 8 {
                self.relayState = .failed("no answer from the relay server")
            }
            self.onChange?()
        }
        timer.resume()
        self.timer = timer
        let p = t.port
        DispatchQueue.main.async { [weak self] in self?.onListening?(p) }
    }

    /// - Parameter quitting: the app is about to exit; wait (briefly) for the router to drop
    ///   the port mapping, since there won't be another chance.
    public func stop(reason: String = "the host closed the game", quitting: Bool = false) {
        timer?.cancel()
        timer = nil
        for c in clients { c.peer.close(reason: reason) }
        for p in waiting.values { p.close(reason: reason) }
        clients.removeAll()
        waiting.removeAll()
        if transport?.relayServer != nil { transport?.sendToRelay(.unregister(hostKey: hostKey)) }
        advertiser?.stop()
        advertiser = nil
        mapper?.stop(wait: quitting)
        mapper = nil
        // Let the goodbyes go out before the socket closes.
        let t = transport
        transport = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { t?.close() }
    }

    /// Sends the lobby to everyone now and to anyone who joins later.
    public func updateLobby(_ info: LobbyInfo) {
        guard info != lobby else { return }
        lobby = info
        for c in clients { c.peer.send(.lobby(info)) }
    }

    /// Players for the lobby screen, host first.
    public var lobbyPlayers: [LobbyPlayer] {
        [LobbyPlayer(id: 0, name: name, localPlayers: localPlayers)]
            + clients.map { LobbyPlayer(id: $0.id, name: $0.name, localPlayers: $0.localPlayers, pingMs: $0.pingMs) }
    }

    // MARK: Access

    /// A fresh secret. Players already in stay; anyone who only knew the old code can't join.
    public func newCode() {
        secret = RoomCode.random(length: 4)
        applyAccess()
    }

    /// Removes a player and keeps them out of this game.
    public func kick(clientID: Int) {
        guard let c = clients.first(where: { $0.id == clientID }) else { return }
        banned.insert(Self.sourceKey(c.peer.route))
        c.peer.close(reason: "the host removed you from the game")
        remove(c)
    }

    private func applyAccess() {
        transport?.joinSecret = secret
        transport?.requireSecret = requireCode
        advertiser?.update(txt: txtRecord())
        onChange?()
    }

    private func txtRecord() -> [String: String] {
        let ips = SocketAddress.localAddresses(port: 0).filter(\.isIPv4).prefix(4).map(\.host)
        return ["v": "\(NetProtocol.version)", "room": room, "code": requireCode ? "1" : "0",
                "port": "\(port ?? 0)", "ip": ips.joined(separator: ",")]
    }

    static func sourceKey(_ route: Route) -> [UInt8] { NetTransport.sourceKey(route) }

    private func admit(_ route: Route) -> String? {
        if banned.contains(Self.sourceKey(route)) { return "the host removed you from this game" }
        if raceID != nil { return "a race is in progress, try again in a moment" }
        if humanCount >= RaceSetup.maxCars { return "the game is full" }
        return guessLimit(route)
    }

    /// Wrong-code limits. Checked on hello and again right before each guess is judged, so
    /// opening many handshakes at once doesn't buy extra guesses. The overall limit means
    /// someone hammering the game can keep it closed for a while: a deliberate trade, since
    /// the alternative is letting guesses through.
    private func guessLimit(_ route: Route) -> String? {
        let now = monotonicNow()
        recentFailures.removeAll { now - $0 > 60 }
        if recentFailures.count >= Self.failuresOverall { return "too many wrong codes lately, try again in a minute" }
        if let f = failures[Self.sourceKey(route)], f.filter({ now - $0 < 60 }).count >= Self.failuresPerSource {
            return "too many wrong codes, try again in a minute"
        }
        return nil
    }

    private func recordFailure(_ route: Route) {
        let now = monotonicNow()
        failures[Self.sourceKey(route), default: []].append(now)
        recentFailures.append(now)
        if failures.count > 200 {
            failures = failures.compactMapValues { times in
                let recent = times.filter { now - $0 < 60 }
                return recent.isEmpty ? nil : recent
            }
        }
    }

    // MARK: Relay

    private func registerWithRelay() {
        guard let t = transport, t.relayServer != nil else { return }
        let local = SocketAddress.localAddresses(port: t.port).filter(\.isIPv4).prefix(3)
        t.sendToRelay(.register(hostKey: hostKey, local: Array(local)))
    }

    private func handleRelay(_ m: RelayMessage) {
        switch m {
        case let .registered(code, publicAddress):
            let changed = code != room
            room = code
            relayState = .registered(publicAddress: publicAddress)
            if changed { advertiser?.update(txt: txtRecord()) }
            onChange?()
        case let .intro(_, client):
            // A player is about to try us directly: open our router toward them. Rate-limited,
            // so a flood of lookups can't turn us into a packet cannon.
            let now = monotonicNow()
            recentIntros.removeAll { now - $0 > 10 }
            guard recentIntros.count < 20 else { return }
            recentIntros.append(now)
            for k in 0..<8 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.05) { [weak self] in
                    self?.transport?.punch(toward: client)
                }
            }
        case let .refused(reason):
            relayState = .failed(reason)
            onChange?()
        default:
            break
        }
    }

    // MARK: Races

    /// Tells every client a race is starting. `slots` gives each client's input slots.
    @discardableResult
    public func startRace(setup: RaceSetup, slots: [Int: [Int]]) -> UInt32 {
        let id = nextRaceID
        nextRaceID &+= 1
        raceID = id
        for c in clients {
            c.slots = slots[c.id] ?? []
            c.lastSeq = 0
            c.inputs = []
            c.peer.send(.start(raceID: id, setup: setup, slots: c.slots))
        }
        return id
    }

    /// Sends loose sand changes (an encoded `SandDelta`) to everyone in the race.
    public func sendSand(_ delta: [UInt8]) {
        guard let raceID else { return }
        for c in clients where !c.slots.isEmpty {
            c.peer.send(.sand(raceID: raceID, delta: delta))
        }
    }

    /// Sends tire rubber changes (an encoded `RubberDelta`) to everyone in the race.
    public func sendRubber(_ delta: [UInt8]) {
        guard let raceID else { return }
        for c in clients where !c.slots.isEmpty {
            c.peer.send(.rubber(raceID: raceID, delta: delta))
        }
    }

    /// Sends race state to every client, each with its own input acknowledgement.
    public func sendSnapshot(_ state: [UInt8]) {
        guard let raceID else { return }
        for c in clients where !c.slots.isEmpty {
            c.peer.send(.snapshot(raceID: raceID, ack: c.lastSeq, state: state))
        }
    }

    /// Back to the lobby for everyone.
    public func endRace() {
        guard let id = raceID else { return }
        raceID = nil
        for c in clients {
            c.slots = []
            c.peer.send(.endRace(raceID: id))
        }
    }

    // MARK: Players

    private func accept(_ link: Link) {
        let peer = NetPeer(link: link)
        let key = ObjectIdentifier(peer)
        waiting[key] = peer
        peer.onClose = { [weak self] _ in self?.waiting[key] = nil }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            guard case let .hello(version, name, localPlayers) = message else {
                return peer.close(reason: "expected a hello")
            }
            self.waiting[key] = nil
            self.greet(peer, version: version, name: name, localPlayers: localPlayers)
        }
        // Anyone who gets in but never says hello is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak peer] in
            guard let self, let peer, self.waiting[key] != nil else { return }
            self.waiting[key] = nil
            peer.close(reason: "no hello")
        }
    }

    private func greet(_ peer: NetPeer, version: UInt16, name rawName: String, localPlayers: Int) {
        if version != NetProtocol.version { return peer.close(reason: "version mismatch") }
        guard (1...4).contains(localPlayers) else { return peer.close(reason: "1 to 4 players per machine") }
        if raceID != nil { return peer.close(reason: "a race is in progress, try again in a moment") }
        if humanCount + localPlayers > RaceSetup.maxCars { return peer.close(reason: "the game is full") }
        var name = String(rawName.filter { !$0.isNewline && $0 != "\t" && !$0.isASCIIControl }.prefix(NetProtocol.maxNameLength))
            .trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Player" }
        if let refusal = admitPlayer?(name, localPlayers) { return peer.close(reason: refusal) }
        let client = Client(id: nextID, name: name, localPlayers: localPlayers, peer: peer)
        nextID += 1
        clients.append(client)
        peer.onMessage = { [weak self, weak client] message in
            guard let self, let client else { return }
            self.handle(message, from: client)
        }
        peer.onClose = { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.remove(client)
        }
        peer.send(.welcome(clientID: client.id))
        if let lobby { peer.send(.lobby(lobby)) }
        onChange?()
    }

    private func handle(_ message: NetMessage, from client: Client) {
        switch message {
        case let .input(seq, inputs):
            // Stale or reordered inputs are ignored; only the newest counts.
            guard raceID != nil, seq > client.lastSeq else { return }
            client.lastSeq = seq
            client.inputs = inputs.map(\.quantized)
        default:
            break
        }
    }

    private func remove(_ client: Client) {
        guard let i = clients.firstIndex(where: { $0 === client }) else { return }
        clients.remove(at: i)
        onClientLeft?(client)
        onChange?()
    }

    private func fail(_ reason: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(reason) }
    }
}

extension RaceSetup {
    /// Cars on the grid, humans and computer drivers together.
    public static let maxCars = 8
}

private extension Character {
    var isASCIIControl: Bool { asciiValue.map { $0 < 0x20 || $0 == 0x7F } ?? false }
}
