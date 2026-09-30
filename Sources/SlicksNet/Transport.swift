import CryptoKit
import Foundation
import SlicksCore
import SlicksLink

/// One UDP socket for everything a machine does online: accepting players (host), connecting
/// (player), talking to the relay server, and relayed traffic. Runs on the main queue.
///
/// Handshake: the player sends an ephemeral X25519 key; the host answers with its own and a
/// connection id. Both derive session keys from the shared secret *and the join secret*, so
/// the join code never crosses the network and a wrong code simply yields keys the host can't
/// decrypt with. Every later packet is ChaCha20-Poly1305 encrypted and replay-checked.
public final class NetTransport {
    public let socket: UDPSocket
    public var port: UInt16 { socket.port }

    // Host side.
    public var acceptsConnections = false
    /// Mixed into the keys: the part of the join code after the dash.
    public var joinSecret = ""
    /// When off, players may also join with no secret at all (an open game). Players who do
    /// type the current secret still get in.
    public var requireSecret = true
    /// Checked on every hello. Return a reason to turn the player away.
    public var admit: ((Route) -> String?)?
    /// Checked again right before a player's secret is tried, so the wrong-code limit counts
    /// guesses, not hellos. Return a reason to stop.
    public var admitGuess: ((Route) -> String?)?
    /// A player finished the handshake with the right secret.
    public var onIncoming: ((Link) -> Void)?
    /// A player's keys didn't match: almost certainly a wrong join code.
    public var onBadSecret: ((Route) -> Void)?

    // Relay server.
    public var relayServer: SocketAddress?
    public var onRelayMessage: ((RelayMessage) -> Void)?

    private var links: [UInt64: Link] = [:]
    private var pending: [[UInt8]: PendingHandshake] = [:]
    private var pendingByConnection: [UInt64: [UInt8]] = [:]
    private var attempts: [[UInt8]: ConnectAttempt] = [:]
    private var timer: DispatchSourceTimer?

    static let version: UInt16 = NetProtocol.version
    static let maxPending = 256
    /// Handshakes one source (IP, or relay session) may have waiting at once.
    static let maxPendingPerSource = 4
    static let pendingLifetime = 6.0

    private struct PendingHandshake {
        let clientNonce: [UInt8]
        let challenge: [UInt8]
        /// One link per secret the host will accept (just the code, or also none when open).
        let links: [Link]
        let route: Route
        let source: [UInt8]
        let created: Double
    }

    /// IP for direct peers (IPv6 grouped by /64, which one household typically gets), or the
    /// relay session.
    static func sourceKey(_ route: Route) -> [UInt8] {
        switch route {
        case let .direct(a): return a.isIPv4 ? a.ip : Array(a.ip[0..<8])
        case let .relay(_, session): return withUnsafeBytes(of: session) { Array($0) }
        }
    }

    public init(port: UInt16 = 0, conditions: NetConditions = .fromEnvironment()) throws {
        socket = try UDPSocket(port: port, queue: .main, conditions: conditions)
        socket.onReceive = { [weak self] bytes, from in self?.receive(bytes, from: from) }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.01, repeating: 0.01, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { close() }

    public func close() {
        timer?.cancel()
        timer = nil
        for l in links.values { l.close(reason: "closed") }
        links.removeAll()
        pending.removeAll()
        pendingByConnection.removeAll()
        attempts.removeAll()
        socket.close()
    }

    // MARK: Sending

    func transmit(_ bytes: [UInt8], _ route: Route) {
        switch route {
        case let .direct(a):
            socket.send(bytes, to: a)
        case let .relay(server, session):
            socket.send(RelayMessage.relay(session: session, payload: bytes).encoded(), to: server)
        }
    }

    public func sendToRelay(_ m: RelayMessage) {
        guard let relayServer else { return }
        socket.send(m.encoded(), to: relayServer)
    }

    /// Opens this machine's router toward a player the relay introduced.
    public func punch(toward address: SocketAddress) {
        socket.send(PacketKind.magic + [PacketKind.punch.rawValue], to: address)
    }

    // MARK: Receiving

    private func receive(_ bytes: [UInt8], from: SocketAddress) {
        if RelayMessage.isRelayPacket(bytes) {
            guard from == relayServer, let m = try? RelayMessage(decoding: bytes) else { return }
            if case let .relay(session, payload) = m {
                return receiveGame(payload, route: .relay(server: from, session: session))
            }
            onRelayMessage?(m)
            return
        }
        receiveGame(bytes, route: .direct(from))
    }

    private func receiveGame(_ bytes: [UInt8], route: Route) {
        guard let kind = PacketKind.of(bytes) else { return }
        switch kind {
        case .hello: handleHello(bytes, route: route)
        case .challenge: handleChallenge(bytes, route: route)
        case .refuse: handleRefuse(bytes)
        case .data: handleData(bytes, route: route)
        case .punch: break
        }
    }

    private func handleData(_ bytes: [UInt8], route: Route) {
        guard bytes.count >= PacketKind.dataHeader else { return }
        var r = ByteReader(slice: bytes[3..<11])
        guard let id = try? r.u64() else { return }
        if let link = links[id] {
            link.receive(bytes, from: route)
            if link.isClosed { links[id] = nil }
            if link.hasHeardFromPeer, let a = attempts.values.first(where: { $0.candidates[id] === link }) { checkCandidates(a) }
            return
        }
        // First packet of a new player: does it decrypt with the keys the right secret gives?
        guard let nonce = pendingByConnection[id], let p = pending[nonce] else { return }
        if let link = p.links.first(where: { $0.canOpen(bytes) }) {
            dropPending(nonce)
            links[id] = link
            onIncoming?(link)
            link.receive(bytes, from: route)
            if link.isClosed { links[id] = nil }
            return
        }
        // Only a failure from where the hello came from counts: the connection id travels in
        // the clear, so anyone else could send junk with it.
        guard route == p.route else { return }
        dropPending(nonce)
        if let reason = admitGuess?(route) { return refuse(clientNonce: nonce, reason: reason, route: route) }
        refuse(clientNonce: nonce, reason: "wrong join code", route: route)
        onBadSecret?(route)
    }

    private func dropPending(_ nonce: [UInt8]) {
        guard let p = pending.removeValue(forKey: nonce) else { return }
        pendingByConnection[p.links[0].connectionID] = nil
    }

    // MARK: Host handshake

    private func handleHello(_ bytes: [UInt8], route: Route) {
        guard acceptsConnections, bytes.count >= PacketKind.helloSize else { return }
        var r = ByteReader(slice: bytes[3...])
        guard let version = try? r.u16(), let clientPub = try? r.raw(32), let nonce = try? r.raw(16) else { return }
        if let p = pending[nonce] {
            // A resend: answer the same way so both ends agree on the keys.
            return transmit(p.challenge, route)
        }
        if version != Self.version {
            let which = version < Self.version ? "you have an older version of the game than the host" : "the host has an older version of the game"
            return refuse(clientNonce: nonce, reason: "version mismatch: \(which)", route: route)
        }
        if let reason = admit?(route) { return refuse(clientNonce: nonce, reason: reason, route: route) }
        let source = Self.sourceKey(route)
        guard pending.count < Self.maxPending,
              pending.values.filter({ $0.source == source }).count < Self.maxPendingPerSource,
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPub) else { return }

        let hostKey = Curve25519.KeyAgreement.PrivateKey()
        let hostNonce = randomBytes(16)
        var id = UInt64.random(in: 1...UInt64.max)
        while links[id] != nil || pendingByConnection[id] != nil { id = UInt64.random(in: 1...UInt64.max) }
        guard let shared = try? hostKey.sharedSecretFromKeyAgreement(with: peerKey) else { return }
        let hostPub = [UInt8](hostKey.publicKey.rawRepresentation)
        let secrets = requireSecret ? [joinSecret] : ["", joinSecret]
        let candidates = secrets.map { secret in
            let keys = SessionKeys(shared: shared, secret: secret, clientPublic: clientPub, hostPublic: hostPub,
                                   clientNonce: nonce, hostNonce: hostNonce, connectionID: id)
            return Link(connectionID: id, route: route, keys: keys, isHostSide: true) { [weak self] b, r in self?.transmit(b, r) }
        }

        var w = ByteWriter(capacity: 128)
        w.raw(PacketKind.magic)
        w.u8(PacketKind.challenge.rawValue)
        w.u16(Self.version)
        w.raw(nonce)
        w.raw(hostPub)
        w.raw(hostNonce)
        w.u64(id)
        w.bool(requireSecret)
        pending[nonce] = PendingHandshake(clientNonce: nonce, challenge: w.bytes, links: candidates, route: route,
                                          source: source, created: monotonicNow())
        pendingByConnection[id] = nonce
        transmit(w.bytes, route)
    }

    private func refuse(clientNonce: [UInt8], reason: String, route: Route) {
        var w = ByteWriter(capacity: 64)
        w.raw(PacketKind.magic)
        w.u8(PacketKind.refuse.rawValue)
        w.raw(clientNonce)
        w.string(String(reason.prefix(200)))
        transmit(w.bytes, route)
    }

    // MARK: Player handshake

    /// Connecting to a host, possibly over several routes at once (its LAN and public
    /// addresses, the relay). Challenges aren't authenticated, so every one that arrives gets a
    /// candidate link; the first whose peer proves it has the same keys (by acking a probe,
    /// encrypted) is the host. A forged challenge just leaves a candidate that never answers.
    public final class ConnectAttempt {
        public let secret: String
        public private(set) var routes: [Route]
        let key = Curve25519.KeyAgreement.PrivateKey()
        let nonce = randomBytes(16)
        let deadline: Double
        var lastSent = 0.0
        var lastProbe = 0.0
        var completion: ((Result<Link, ConnectError>) -> Void)?
        var candidates: [UInt64: Link] = [:]
        /// The candidate that turned out to be the host.
        var link: Link?
        static let maxCandidates = 8

        init(routes: [Route], secret: String, timeout: Double, completion: @escaping (Result<Link, ConnectError>) -> Void) {
            self.routes = routes
            self.secret = secret
            deadline = monotonicNow() + timeout
            self.completion = completion
        }

        public func add(_ route: Route) {
            if !routes.contains(route) { routes.append(route) }
        }
    }

    public enum ConnectError: Error, CustomStringConvertible {
        case refused(String)
        case needsCode
        case timedOut

        public var description: String {
            switch self {
            case let .refused(r): r
            case .needsCode: "this game needs its join code"
            case .timedOut: "no answer from the host"
            }
        }
    }

    @discardableResult
    public func connect(routes: [Route], secret: String, timeout: Double = 10,
                        completion: @escaping (Result<Link, ConnectError>) -> Void) -> ConnectAttempt {
        let a = ConnectAttempt(routes: routes, secret: secret, timeout: timeout, completion: completion)
        attempts[a.nonce] = a
        sendHellos(a, now: monotonicNow())
        return a
    }

    public func cancel(_ a: ConnectAttempt) {
        attempts[a.nonce] = nil
        a.completion = nil
    }

    private func sendHellos(_ a: ConnectAttempt, now: Double) {
        var w = ByteWriter(capacity: PacketKind.helloSize)
        w.raw(PacketKind.magic)
        w.u8(PacketKind.hello.rawValue)
        w.u16(Self.version)
        w.raw(a.key.publicKey.rawRepresentation)
        w.raw(a.nonce)
        w.raw([UInt8](repeating: 0, count: PacketKind.helloSize - w.count))
        for r in a.routes { transmit(w.bytes, r) }
        a.lastSent = now
    }

    private func handleChallenge(_ bytes: [UInt8], route: Route) {
        var r = ByteReader(slice: bytes[3...])
        guard let version = try? r.u16(), let nonce = try? r.raw(16), let a = attempts[nonce], a.link == nil,
              let hostPub = try? r.raw(32), let hostNonce = try? r.raw(16), let id = try? r.u64(),
              let needsCode = try? r.bool(), version == Self.version, a.candidates[id] == nil,
              a.candidates.count < ConnectAttempt.maxCandidates, links[id] == nil,
              let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostPub),
              let shared = try? a.key.sharedSecretFromKeyAgreement(with: peerKey) else { return }
        if needsCode && a.secret.isEmpty {
            // Unauthenticated, so a forger could fake this; but all they get is a "needs a
            // code" message, and the real answer is worth giving straight away.
            attempts[nonce] = nil
            dropCandidates(a)
            a.completion?(.failure(.needsCode))
            return
        }
        // The typed secret is always used, whatever the challenge says: a forged "no code
        // needed" must not talk the player into keys that anyone can derive.
        let keys = SessionKeys(shared: shared, secret: a.secret, clientPublic: [UInt8](a.key.publicKey.rawRepresentation),
                               hostPublic: hostPub, clientNonce: nonce, hostNonce: hostNonce, connectionID: id)
        let link = Link(connectionID: id, route: route, keys: keys, isHostSide: false) { [weak self] b, r in self?.transmit(b, r) }
        a.candidates[id] = link
        links[id] = link
        link.probe()
        a.lastProbe = monotonicNow()
    }

    /// A candidate heard back under its keys: that's the host.
    private func checkCandidates(_ a: ConnectAttempt) {
        guard a.link == nil, let winner = a.candidates.values.first(where: \.hasHeardFromPeer) else { return }
        a.link = winner
        for (id, l) in a.candidates where l !== winner {
            links[id] = nil
            l.close(reason: "")
        }
        a.candidates = [:]
        attempts[a.nonce] = nil
        let completion = a.completion
        a.completion = nil
        completion?(.success(winner))
    }

    private func dropCandidates(_ a: ConnectAttempt) {
        for (id, l) in a.candidates {
            links[id] = nil
            l.close(reason: "")
        }
        a.candidates = [:]
    }

    private func handleRefuse(_ bytes: [UInt8]) {
        var r = ByteReader(slice: bytes[3...])
        guard let nonce = try? r.raw(16), let reason = try? r.string(), let a = attempts[nonce], a.link == nil else { return }
        // Refusals aren't authenticated either; a forged one can only end a join that hasn't
        // reached the host yet (a denial of service, not a way in).
        attempts[nonce] = nil
        dropCandidates(a)
        a.completion?(.failure(.refused(reason)))
    }

    // MARK: Timer

    private func tick() {
        let now = monotonicNow()
        for (id, link) in links {
            link.tick(now: now)
            if link.isClosed { links[id] = nil }
        }
        for (nonce, p) in pending where now - p.created > Self.pendingLifetime { dropPending(nonce) }
        for (nonce, a) in attempts where a.link == nil {
            if now > a.deadline {
                attempts[nonce] = nil
                dropCandidates(a)
                a.completion?(.failure(.timedOut))
            } else {
                if now - a.lastSent >= 0.25 { sendHellos(a, now: now) }
                // Probes can be lost too.
                if !a.candidates.isEmpty, now - a.lastProbe >= 0.25 {
                    for l in a.candidates.values { l.probe() }
                    a.lastProbe = now
                }
            }
        }
    }
}

func randomBytes(_ n: Int) -> [UInt8] {
    var rng = SystemRandomNumberGenerator()
    return (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
}

extension Link {
    /// Lets the transport report a refusal to whoever owns the link.
    func onCloseForTransport(_ reason: String) { onClose?(reason) }
}
