import CryptoKit
import Foundation
import SlicksCore
import SlicksLink
import SlicksNet

/// Runs the main run loop (where all networking callbacks land) until `done` or the timeout.
@discardableResult
private func wait(_ timeout: Double, until done: () -> Bool) -> Bool {
    let end = Date(timeIntervalSinceNow: timeout)
    while !done() {
        if Date() > end { return false }
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
    }
    return true
}

private func pump(_ seconds: Double) {
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: seconds))
}

/// One player's machine in the test: a client with its predicted race.
private final class TestClient {
    let client: NetClient
    var closedReason: String?
    var welcomed = false
    var lobby: LobbyInfo?
    var lobbyUpdates = 0
    var controller: ClientRaceController?
    var setup: RaceSetup?
    var endedRace: UInt32?
    var snapshots = 0
    var sandDeltas = 0
    var sandBytes = 0
    var rubberDeltas = 0
    var rubberBytes = 0
    var bot = AIDriver(skill: 0.7, lane: 0)

    init(_ target: NetClient.Target, name: String, secret: String, localPlayers: Int = 1, relay: String? = nil,
             conditions: NetConditions = .none) {
        client = NetClient(target: target, name: name, localPlayers: localPlayers, secret: secret, relayServer: relay)
        client.onWelcome = { [unowned self] in welcomed = true }
        client.onLobby = { [unowned self] in lobby = $0; lobbyUpdates += 1 }
        client.onClose = { [unowned self] in closedReason = $0 }
        client.onStart = { [unowned self] id, setup, slots in
            self.setup = setup
            let race = Race(setup: setup, track: Track(definition: setup.track))
            controller = ClientRaceController(race: race, raceID: id, localSlots: slots, client: client)
        }
        client.onSnapshot = { [unowned self] id, ack, state in
            snapshots += 1
            if id == controller?.raceID { controller?.receive(ack: ack, state: state) }
        }
        client.onSand = { [unowned self] id, delta in
            sandDeltas += 1
            sandBytes += delta.count
            if id == controller?.raceID { controller?.receiveSand(delta) }
        }
        client.onRubber = { [unowned self] id, delta in
            rubberDeltas += 1
            rubberBytes += delta.count
            if id == controller?.raceID { controller?.receiveRubber(delta) }
        }
        client.onRaceEnded = { [unowned self] in endedRace = $0 }
        client.connect()
        client.networkConditions = conditions
    }

    convenience init(port: UInt16, name: String, secret: String, localPlayers: Int = 1, conditions: NetConditions = .none) {
        self.init(.address("127.0.0.1:\(port)"), name: name, secret: secret, localPlayers: localPlayers, conditions: conditions)
    }

    /// Drives this machine's car with the AI's judgment, from the client's own (predicted) view.
    func advance(_ dt: Double) {
        guard let c = controller, let slot = c.localSlots.first,
              let car = c.race.cars.first(where: { $0.playerIndex == slot }) else { return }
        let input = c.race.phase == .racing
            ? bot.input(for: car, track: c.race.track, sand: c.race.looseSand, rubber: c.race.rubber, dt: dt, elapsed: c.race.time) : .none
        _ = c.advance(frameDt: dt, localInputs: [input])
    }
}

/// Sits between a player and the host and misbehaves: flips bits in some encrypted packets
/// and replays others, like a hostile network would.
private final class EvilProxy {
    let socket: UDPSocket
    let target: SocketAddress
    var player: SocketAddress?
    var tamperEvery = 7
    var dataPackets = 0
    var tampered = 0
    var replayed = 0

    init(to target: SocketAddress) throws {
        self.target = target
        socket = try UDPSocket(port: 0, conditions: .none)
        socket.onReceive = { [unowned self] bytes, from in
            let dest: SocketAddress
            if from == target {
                guard let p = player else { return }
                dest = p
            } else {
                player = from
                dest = target
            }
            var b = bytes
            if b.count > 40, b[0] == 0x53, b[1] == 0x57, b[2] == 3 {
                dataPackets += 1
                if dataPackets % tamperEvery == 0 {
                    b[b.count - 20] ^= 0x40
                    tampered += 1
                } else if dataPackets % 3 == 0 {
                    // Send it again a moment later, as an attacker replaying traffic would.
                    replayed += 1
                    let copy = b
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.socket.send(copy, to: dest) }
                }
            }
            socket.send(b, to: dest)
        }
    }
}

private func startHost(_ name: String, requireCode: Bool = true, relay: String? = nil, localPlayers: Int = 1) -> (NetHost, UInt16)? {
    let host = NetHost(name: name, localPlayers: localPlayers, requireCode: requireCode, advertise: false, relayServer: relay, mapPort: false)
    var port: UInt16 = 0
    var error: String?
    host.onListening = { port = $0 }
    host.onError = { error = $0 }
    host.start(port: 0)
    guard wait(3, until: { port != 0 || error != nil }), port != 0 else {
        print("  FAIL: host didn't start: \(error ?? "timeout")")
        return nil
    }
    return (host, port)
}

/// Real hosts, players and a relay server talking over encrypted UDP on localhost, with
/// simulated packet loss, reordering, duplication, tampering and lag.
func loopbackChecks() -> Int {
    var problems = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { print("  FAIL: \(what)"); problems += 1 }
    }
    print("== Online loopback")

    // Wire format.
    do {
        let messages: [NetMessage] = [
            .hello(version: 1, name: "Añá 🏎", localPlayers: 2),
            .input(seq: 77, inputs: [CarInput(throttle: 1, brake: 0, steer: -1), CarInput(throttle: 0.5, brake: 0.25, steer: 0.3).quantized]),
            .welcome(clientID: 3), .endRace(raceID: 9), .ping(123), .pong(456),
            .lobby(LobbyInfo(players: [LobbyPlayer(id: 0, name: "H", localPlayers: 1, pingMs: 12)], trackName: "T", laps: 3,
                             aiOpponents: 2, aiSkillName: "Hard", inRace: false)),
        ]
        for m in messages {
            check((try? NetMessage(decoding: m.encoded())) == m, "message doesn't survive encoding: \(m)")
        }
        check((try? NetMessage(decoding: [200])) == nil, "unknown message type accepted")
        check((try? NetMessage(decoding: Array(messages[1].encoded().dropLast()))) == nil, "truncated input accepted")
        let odd = CarInput(throttle: 0.123, brake: 2, steer: -0.777)
        check(odd.quantized == odd.quantized.quantized, "quantizing isn't stable")
        check(odd.quantized.brake == 1, "brake isn't clamped")

        let settings = RaceSettingsLite(humans: 2, ai: 6)
        let setup = settings.setup(trackID: "twin-bridges", seed: 5)
        let race = Race(setup: setup, track: Track(definition: setup.track))
        for _ in 0..<1500 { race.step(dt: Race.tickDuration, humanInputs: [CarInput(throttle: 1, brake: 0, steer: 0.2), .none]) }
        race.handOverToAI(carID: race.cars.first { $0.playerIndex == 1 }!.id)
        for _ in 0..<10 { race.step(dt: Race.tickDuration, humanInputs: [.none, .none]) }
        // The sand grid has its own stream; the wire snapshot carries only its fingerprint.
        let snap = race.snapshot(includingGrids: false)
        var w = ByteWriter()
        snap.write(to: &w)
        var r = ByteReader(w.bytes)
        let back = try? RaceSnapshot(reading: &r, for: race)
        check(back == snap, "binary snapshot doesn't round-trip")
        check(r.isAtEnd, "binary snapshot has leftover bytes")
        print("   binary snapshot: \(w.bytes.count) bytes for \(race.cars.count) cars")
        var short = ByteReader(Array(w.bytes.dropLast(3)))
        check((try? RaceSnapshot(reading: &short, for: race)) == nil, "truncated snapshot accepted")
        for corrupt: (inout RaceSnapshot) -> Void in [
            { $0.cars[0].pathIndex = 60000 },
            { $0.cars[1].position.x = .nan },
            { $0.cars[2].bridgeZone = 99 },
        ] {
            var bad = snap
            corrupt(&bad)
            var bw = ByteWriter()
            bad.write(to: &bw)
            var br = ByteReader(bw.bytes)
            check((try? RaceSnapshot(reading: &br, for: race)) == nil, "corrupt snapshot accepted")
        }
        let other = Race(setup: settings.setup(trackID: "twin-bridges", seed: 5, ai: 3), track: race.track)
        var mismatched = ByteReader(w.bytes)
        check((try? RaceSnapshot(reading: &mismatched, for: other)) == nil, "snapshot for a different grid accepted")

        // Grid deltas: exact round trips, and nothing outside the grid or 0...1 gets through.
        let cells: [(index: Int, value: Float)] = [(3, 0.25), (4, 1), (900, 0.0001), (70_000, 0.5)]
        var sw = ByteWriter()
        SandDelta(tick: 9, rngState: 0xABCD, cells: cells).write(to: &sw)
        var sr = ByteReader(sw.bytes)
        check((try? SandDelta(reading: &sr, cellCount: 100_000)) == SandDelta(tick: 9, rngState: 0xABCD, cells: cells) && sr.isAtEnd,
              "sand delta doesn't round-trip")
        let rubberCells = Array(cells.prefix(3))
        var rw = ByteWriter()
        RubberDelta(tick: 11, cells: rubberCells).write(to: &rw)
        var rr = ByteReader(rw.bytes)
        check((try? RubberDelta(reading: &rr, cellCount: 1000)) == RubberDelta(tick: 11, cells: rubberCells) && rr.isAtEnd,
              "rubber delta doesn't round-trip")
        var outside = ByteReader(rw.bytes)
        check((try? RubberDelta(reading: &outside, cellCount: 900)) == nil, "rubber delta outside the grid accepted")
        var tooMuch = ByteWriter()
        RubberDelta(tick: 1, cells: [(0, 1.5)]).write(to: &tooMuch)
        var tm = ByteReader(tooMuch.bytes)
        check((try? RubberDelta(reading: &tm, cellCount: 10)) == nil, "rubber amount over 1 accepted")

        for m: RelayMessage in [
            .register(hostKey: [UInt8](repeating: 7, count: 16), local: [SocketAddress(numeric: "10.0.0.2", port: 5)!]),
            .registered(room: "ABCD", publicAddress: SocketAddress(numeric: "::1", port: 9)!), .lookup(room: "XY23"),
            .peer(room: "XY23", session: 99, hostPublic: SocketAddress(numeric: "1.2.3.4", port: 7)!, hostLocal: []),
            .relay(session: 5, payload: [1, 2, 3]), .notFound(room: "ZZZZ"), .refused(reason: "no"),
        ] {
            check((try? RelayMessage(decoding: m.encoded())) == m, "relay message doesn't survive encoding: \(m)")
        }
        check((try? RelayMessage(decoding: RelayMessage.lookup(room: "abcd").encoded())) == nil, "bad room code accepted")
        check(RoomCode.normalize("abcd-efgh") == "ABCDEFGH" && RoomCode.normalize("AB0D") == nil, "code normalizing")
        check(SocketAddress.split("[::1]:99", defaultPort: 1)! == ("::1", 99) && SocketAddress.split("host", defaultPort: 7)! == ("host", 7),
              "address parsing")
    }

    // Lobby: codes, refusals.
    guard let (host, hostPort) = startHost("Host") else { return problems + 1 }
    let secret = String(host.joinCode.suffix(4))
    check(host.joinCode.count == 9 && host.joinCode.contains("-"), "join code looks wrong: \(host.joinCode)")
    let lobbyInfo = LobbyInfo(players: [], trackName: "Twin Bridges", laps: 1, aiOpponents: 4, aiSkillName: "Normal", inRace: false)
    host.updateLobby(lobbyInfo)

    let alice = TestClient(port: hostPort, name: "Alice", secret: secret)
    let bob = TestClient(port: hostPort, name: "Bob\n\tthe Builder of Very Long Names", secret: secret)
    check(wait(4) { alice.welcomed && bob.welcomed && alice.lobby != nil }, "clients weren't welcomed: \(alice.closedReason ?? bob.closedReason ?? "timeout")")
    check(alice.lobby == lobbyInfo, "client didn't get the lobby")
    let names = host.clients.map(\.name)
    check(names.contains("Alice") && names.allSatisfy { $0.count <= NetProtocol.maxNameLength && !$0.contains { $0.isNewline || $0 == "\t" } },
          "names not cleaned up: \(names)")

    // A hello from a newer version is refused before any keys are made.
    do {
        let raw = try! UDPSocket(port: 0, conditions: .none)
        var refusal: String?
        raw.onReceive = { bytes, _ in
            guard bytes.count > 19, bytes[2] == 4 else { return }
            var r = ByteReader(slice: bytes[19...])
            refusal = try? r.string()
        }
        var w = ByteWriter()
        w.raw([0x53, 0x57, 1])
        w.u16(NetProtocol.version + 1)
        w.raw([UInt8](repeating: 9, count: 48))
        w.raw([UInt8](repeating: 0, count: 1200 - w.count))
        raw.send(w.bytes, to: SocketAddress(numeric: "127.0.0.1", port: hostPort)!)
        check(wait(2) { refusal != nil } && refusal!.contains("version"), "newer version not refused: \(refusal ?? "-")")
        var small = w.bytes
        small.removeLast(600)
        refusal = nil
        raw.send(small, to: SocketAddress(numeric: "127.0.0.1", port: hostPort)!)
        pump(0.3)
        check(refusal == nil, "host answered an undersized hello (amplification risk)")
        raw.close()
    }

    let crowd = TestClient(port: hostPort, name: "Crowd", secret: secret, localPlayers: 4)
    check(wait(4) { crowd.welcomed }, "four players on one machine not welcomed")
    let overflow = TestClient(port: hostPort, name: "Overflow", secret: secret, localPlayers: 3)
    check(wait(4) { overflow.closedReason != nil }, "full game not refused")
    check(overflow.closedReason?.contains("full") == true, "wrong refusal for a full game: \(overflow.closedReason ?? "-")")
    crowd.client.disconnect()
    check(wait(4) { host.clients.count == 2 }, "host didn't notice a player leaving")

    // Race over a bad network: 10% loss, 5% duplicates, up to 30 ms reordering, both ways.
    // Bob drops out partway and the AI takes his car.
    let bad = NetConditions(loss: 0.10, lag: 0.005, jitter: 0.03, duplicate: 0.05)
    host.networkConditions = bad
    alice.client.networkConditions = bad
    bob.client.networkConditions = bad
    // A jump ramp and sand across the road, so heights and loose sand get synced too.
    let setup = RaceSettingsLite(humans: 3, ai: 4).setup(track: sandyRiverside(), seed: 21)
    let track = Track(definition: setup.track)
    let hostRace = Race(setup: setup, track: track)
    let aliceID = host.clients.first { $0.name == "Alice" }!.id
    let bobID = host.clients.first { $0.name.hasPrefix("Bob") }!.id
    host.startRace(setup: setup, slots: [aliceID: [1], bobID: [2]])
    let hostCtl = HostRaceController(race: hostRace, host: host, localSlots: [0])
    check(wait(4) { alice.controller != nil && bob.controller != nil }, "clients didn't get the race")
    let late = TestClient(port: hostPort, name: "Late", secret: secret)
    check(wait(4) { late.closedReason != nil } && late.closedReason!.contains("race"), "joining mid-race not refused: \(late.closedReason ?? "-")")

    var hostBot = AIDriver(skill: 0.7, lane: 0)
    let dt = Race.tickDuration
    var ticks = 0
    let bobCar = hostRace.cars.first { $0.playerIndex == 2 }!
    var bobProgressAtExit = 0.0
    var bobHandoverTime: Double?
    let started = Date()
    while !(alice.controller?.isFinished ?? true) && ticks < 200 * Race.tickRate {
        let hostCar = hostRace.cars.first { $0.playerIndex == 0 }!
        let input = hostRace.phase == .racing
            ? hostBot.input(for: hostCar, track: track, sand: hostRace.looseSand, rubber: hostRace.rubber, dt: dt, elapsed: hostRace.time) : .none
        _ = hostCtl.advance(frameDt: dt, localInputs: [input])
        if bobHandoverTime == nil, hostRace.isComputerDriven(bobCar) { bobHandoverTime = hostRace.time }
        alice.advance(dt)
        if ticks < 1500 { bob.advance(dt) }
        if ticks == 1500 {
            bob.client.disconnect()
            bobProgressAtExit = bobCar.progress
        }
        // Real time runs about 4x faster than the race here, so the network's delays count for more.
        pump(0.002)
        ticks += 1
    }
    // Keep both ends going briefly, as the results screen does: the last sand changes may
    // still be being resent over the lossy network, and the host keeps resending its final
    // state, which settles the client onto it.
    let settle = Date(timeIntervalSinceNow: 1.5)
    while Date() < settle {
        _ = hostCtl.advance(frameDt: dt, localInputs: [.none])
        alice.advance(dt)
        pump(0.004)
    }
    if let c = alice.controller {
        let aliceRace = c.race
        check(c.error == nil, "client error: \(c.error ?? "")")
        check(hostRace.phase == .finished && c.isFinished, "race over a lossy network didn't finish on both ends")
        check(hostRace.isComputerDriven(bobCar), "departed player's car wasn't handed to the AI")
        // Bob left 12.5 s in (race time 9.5 s); the host should notice at once from his goodbye.
        check((bobHandoverTime ?? .infinity) < 11, "departed player's car handed over late: \(bobHandoverTime.map { "\($0)" } ?? "never")")
        // Whether the AI then gets the car home depends on where Bob left it (the AI can't
        // always recover a car left spun around on grass), so that isn't checked here.
        _ = bobProgressAtExit
        check(aliceRace.isComputerDriven(aliceRace.cars[bobCar.id]), "client doesn't know the car is AI-driven now")
        check(aliceRace.stateHash == hostRace.stateHash, "client's final state differs from the host's")
        check(aliceRace.standings.map(\.id) == hostRace.standings.map(\.id), "client and host disagree on the results")
        // The whole sand grid, cell for cell, not just its checksum.
        check(aliceRace.looseSand?.amount == hostRace.looseSand?.amount, "client's loose sand differs from the host's")
        let sandCells = hostRace.looseSand?.amount.filter { $0 > 0 }.count ?? 0
        let jumps = hostRace.cars.reduce(0) { $0 + $1.jumps }
        check(sandCells > 0, "no loose sand moved, so sand sync went untested")
        // And the rubber, cell for cell.
        check(aliceRace.rubber?.amount == hostRace.rubber?.amount, "client's tire rubber differs from the host's")
        let rubberCells = hostRace.rubber?.amount.filter { $0 > 0 }.count ?? 0
        check(rubberCells > 0, "no rubber laid, so rubber sync went untested")
        print(String(format: "   lossy race: %d frames in %.1fs, %d snapshots applied, %d jumps, %d sand cells (%d deltas, %d KB), %d rubber cells (%d deltas, %d KB), results %@",
                     ticks, Date().timeIntervalSince(started), c.snapshotsApplied, jumps, sandCells, alice.sandDeltas,
                     alice.sandBytes / 1024, rubberCells, alice.rubberDeltas, alice.rubberBytes / 1024,
                     hostRace.standings.map(\.name).joined(separator: ", ")))
    }
    host.endRace()
    check(wait(4) { alice.endedRace != nil }, "client wasn't sent back to the lobby")
    host.networkConditions = .none
    alice.client.networkConditions = .none

    // A hostile network in the middle: flipped bits and replayed packets must be dropped, and
    // a big race setup (a track full of patches) must still arrive intact.
    do {
        let proxy = try! EvilProxy(to: SocketAddress(numeric: "127.0.0.1", port: hostPort)!)
        let carol = TestClient(port: proxy.socket.port, name: "Carol", secret: secret)
        check(wait(6) { carol.welcomed && carol.lobby != nil }, "player behind a tampering network didn't get in: \(carol.closedReason ?? "timeout")")
        var big = BuiltInTracks.all[0]
        big.patches = (0..<200).map { (k: Int) -> Patch in
            let x = Double(40 + (k * 37) % 880)
            let y = Double(40 + (k * 53) % 520)
            return Patch(.sand, .circle(center: Vec2(x, y), radius: 6 + Double(k % 5)))
        }
        let bigSetup = RaceSetup(track: big, entrants: RaceSettingsLite(humans: 3, ai: 2).setup(trackID: big.id, seed: 3).entrants,
                                 laps: 2, seed: 3)
        let setupBytes = (try? JSONEncoder().encode(bigSetup))?.count ?? 0
        let carolID = host.clients.first { $0.name == "Carol" }!.id
        let updatesBefore = carol.lobbyUpdates
        for k in 0..<5 {
            host.updateLobby(LobbyInfo(players: [], trackName: "update \(k)", laps: k + 1, aiOpponents: 0, aiSkillName: "", inRace: false))
        }
        host.startRace(setup: bigSetup, slots: [aliceID: [1], carolID: [2]])
        let bigRace = Race(setup: bigSetup, track: Track(definition: bigSetup.track))
        let bigHost = HostRaceController(race: bigRace, host: host, localSlots: [0])
        check(wait(8) { carol.setup != nil }, "big setup didn't make it through the hostile network")
        check(carol.setup == bigSetup, "big setup arrived damaged")
        check(carol.lobbyUpdates - updatesBefore == 5 && carol.lobby?.trackName == "update 4",
              "reliable messages lost, duplicated or reordered (\(carol.lobbyUpdates - updatesBefore) updates, last \(carol.lobby?.trackName ?? "-"))")
        for _ in 0..<(3 * Race.tickRate) {
            _ = bigHost.advance(frameDt: dt, localInputs: [.none])
            carol.advance(dt)
            alice.advance(dt)
            pump(0.001)
        }
        check(carol.snapshots > 30, "race state didn't flow through the hostile network (\(carol.snapshots) snapshots)")
        check(carol.controller?.error == nil, "tampered packets got through: \(carol.controller?.error ?? "")")
        check(carol.closedReason == nil, "hostile network broke the connection: \(carol.closedReason ?? "")")
        print("   hostile network: \(proxy.tampered) tampered and \(proxy.replayed) replayed packets dropped, \(setupBytes / 1024) KB setup delivered")
        host.endRace()
        carol.client.disconnect()
        check(wait(4) { host.clients.count == 1 }, "host didn't notice Carol leaving")
        _ = proxy
    }

    // With 40 ms each way, the client's own car should still track the host's closely.
    host.networkConditions = NetConditions(lag: 0.04)
    alice.client.networkConditions = NetConditions(lag: 0.04)
    let lagSetup = RaceSettingsLite(humans: 2, ai: 2).setup(trackID: "proving-grounds", seed: 8)
    let lagRace = Race(setup: lagSetup, track: Track(definition: lagSetup.track))
    alice.controller = nil
    host.startRace(setup: lagSetup, slots: [aliceID: [1]])
    let lagHost = HostRaceController(race: lagRace, host: host, localSlots: [0])
    check(wait(3) { alice.controller != nil }, "client didn't get the lag race")
    var corrections: [Double] = []
    var hostBot2 = AIDriver(skill: 0.7, lane: 0)
    var last = Date()
    let end = Date(timeIntervalSinceNow: Race.countdownDuration + 5)
    while Date() < end, let c = alice.controller {
        let now = Date()
        let frame = min(now.timeIntervalSince(last), 0.05)
        last = now
        let hostCar = lagRace.cars.first { $0.playerIndex == 0 }!
        let input = lagRace.phase == .racing ? hostBot2.input(for: hostCar, track: lagRace.track, dt: frame, elapsed: lagRace.time) : .none
        _ = lagHost.advance(frameDt: frame, localInputs: [input])
        let before = c.snapshotsApplied
        alice.advance(frame)
        if c.snapshotsApplied > before, c.race.time > 1 { corrections.append(c.lastOwnCorrection) }
        pump(1.0 / 240)
    }
    let sorted = corrections.sorted()
    let median = sorted.isEmpty ? .infinity : sorted[sorted.count / 2]
    let p95 = sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
    print(String(format: "   80 ms round trip: %d corrections, own car median %.2f px, 95th percentile %.2f px, ping %.0f ms",
                 corrections.count, median, p95, (alice.client.rtt ?? 0) * 1000))
    check(corrections.count > 60, "too few snapshots arrived under lag")
    check(median < 3, "own car jumps too much under lag")
    host.endRace()
    host.stop()
    check(wait(4) { alice.closedReason != nil }, "client didn't notice the host leaving")

    problems += accessChecks()
    problems += relayChecks()
    if problems == 0 { print("  online loopback OK") }
    return problems
}

/// Join codes, open games, rate limiting and kicking.
private func accessChecks() -> Int {
    var problems = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { print("  FAIL: \(what)"); problems += 1 }
    }
    guard let (host, port) = startHost("Guarded") else { return 1 }
    let secret = String(host.joinCode.suffix(4))

    let noCode = TestClient(port: port, name: "NoCode", secret: "")
    check(wait(4) { noCode.closedReason != nil } && noCode.closedReason!.contains("code"), "joining without a code not refused: \(noCode.closedReason ?? "-")")
    check(host.clients.isEmpty, "someone got in without the code")

    let old = secret
    host.newCode()
    let newSecret = String(host.joinCode.suffix(4))
    check(newSecret != old, "new code is the same as the old one")
    let stale = TestClient(port: port, name: "Stale", secret: old)
    check(wait(4) { stale.closedReason != nil } && stale.closedReason!.contains("wrong"), "old code still works: \(stale.closedReason ?? "-")")
    let fresh = TestClient(port: port, name: "Fresh", secret: newSecret)
    check(wait(4) { fresh.welcomed }, "new code doesn't work: \(fresh.closedReason ?? "timeout")")

    // Guessing: a few wrong codes and even the right one is turned away for a while.
    for k in 0..<4 {
        let guess = TestClient(port: port, name: "Guess\(k)", secret: "ZZZ\(k + 2)")
        wait(4) { guess.closedReason != nil }
    }
    let afterGuesses = TestClient(port: port, name: "Patient", secret: newSecret)
    check(wait(4) { afterGuesses.closedReason != nil } && afterGuesses.closedReason!.contains("too many"),
          "wrong guesses aren't rate limited: \(afterGuesses.closedReason ?? "got in")")

    // Kicked players can't come back.
    let freshID = host.clients.first { $0.name == "Fresh" }!.id
    host.kick(clientID: freshID)
    check(wait(4) { fresh.closedReason != nil } && fresh.closedReason!.contains("removed"), "kicked player not told: \(fresh.closedReason ?? "-")")
    check(host.clients.isEmpty, "kicked player still listed")
    host.stop()

    // A forged host answers every hello first and claims no code is needed. The player must
    // neither fall for the downgrade nor get stuck on the fake: the real host wins.
    do {
        guard let (real, realPort) = startHost("Real") else { return problems + 1 }
        let fake = try! UDPSocket(port: 0, conditions: .none)
        var forged = 0
        fake.onReceive = { bytes, from in
            guard bytes.count >= 1200, bytes[2] == 1 else { return }
            var w = ByteWriter()
            w.raw([0x53, 0x57, 2])
            w.u16(NetProtocol.version)
            w.raw(bytes[37..<53])
            w.raw(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            w.raw([UInt8](repeating: 1, count: 16))
            w.u64(UInt64.random(in: 1...UInt64.max))
            w.bool(false)
            fake.send(w.bytes, to: from)
            forged += 1
        }
        let fakeAddr = SocketAddress(numeric: "127.0.0.1", port: fake.port)!
        let realAddr = SocketAddress(numeric: "127.0.0.1", port: realPort)!
        let target = TestClient(.addresses([fakeAddr, realAddr]), name: "Target", secret: String(real.joinCode.suffix(4)))
        check(wait(6) { target.welcomed }, "a forged host blocked the real one: \(target.closedReason ?? "timeout")")
        check(target.client.route == .direct(realAddr), "player ended up on the forged host")
        check(forged > 0, "the forged host never got to answer")
        real.stop()
        fake.close()
    }

    // An open game lets in anyone without a code, and anyone who knows the secret.
    guard let (open, openPort) = startHost("Open", requireCode: false) else { return problems + 1 }
    check(open.joinCode.count == 4, "open game shows a secret: \(open.joinCode)")
    let a = TestClient(port: openPort, name: "A", secret: "")
    let b = TestClient(port: openPort, name: "B", secret: String(open.secret))
    check(wait(4) { a.welcomed && b.welcomed }, "open game refused someone: \(a.closedReason ?? b.closedReason ?? "timeout")")
    let wrong = TestClient(port: openPort, name: "C", secret: "WXYZ")
    check(wait(4) { wrong.closedReason != nil }, "a wrong secret got into an open game")
    // Kicks ban by IP, and everyone here is 127.0.0.1: so kick in this game, last.
    open.kick(clientID: open.clients[0].id)
    let back = TestClient(port: openPort, name: "Again", secret: "")
    check(wait(4) { back.closedReason != nil } && back.closedReason!.contains("removed"), "kicked player got back in: \(back.closedReason ?? "-")")
    open.stop()
    pump(0.3)
    if problems == 0 { print("   access: code required, new code, guess limit, kick and ban, open games OK") }
    return problems
}

/// Joining by code through a rendezvous/relay server: direct when possible, relayed when not.
private func relayChecks() -> Int {
    var problems = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok { print("  FAIL: \(what)"); problems += 1 }
    }
    let server: RelayServer
    do {
        server = try RelayServer(port: 0)
    } catch {
        print("  FAIL: relay server didn't start: \(error)")
        return 1
    }
    server.log = { _ in }
    let relay = "127.0.0.1:\(server.socket.port)"
    guard let (host, _) = startHost("Relayed", relay: relay) else { return 1 }
    check(wait(3) { if case .registered = host.relayState { return true }; return false }, "host didn't register with the relay: \(host.relayState)")
    let room = String(host.joinCode.prefix(4)), secret = String(host.joinCode.suffix(4))
    check(server.roomCount == 1, "relay has \(server.roomCount) rooms")

    NetClient.relayOnly = true
    let relayed = TestClient(.room(room, nearby: []), name: "Far", secret: secret, relay: relay)
    check(wait(6) { relayed.welcomed }, "couldn't join through the relay: \(relayed.closedReason ?? "timeout")")
    check(relayed.client.route?.isRelayed == true, "relay-only player isn't relayed: \(relayed.client.route.map { "\($0)" } ?? "-")")
    NetClient.relayOnly = false

    let direct = TestClient(.room(room, nearby: []), name: "Near", secret: secret, relay: relay)
    check(wait(6) { direct.welcomed }, "couldn't join by code: \(direct.closedReason ?? "timeout")")
    check(direct.client.route?.isRelayed == false, "player that could go direct went through the relay")

    // Race state flows over the relayed link too.
    let setup = RaceSettingsLite(humans: 3, ai: 1).setup(trackID: "proving-grounds", seed: 4)
    let farID = host.clients.first { $0.name == "Far" }!.id, nearID = host.clients.first { $0.name == "Near" }!.id
    host.startRace(setup: setup, slots: [farID: [1], nearID: [2]])
    let ctl = HostRaceController(race: Race(setup: setup, track: Track(definition: setup.track)), host: host, localSlots: [0])
    for _ in 0..<(2 * Race.tickRate) {
        _ = ctl.advance(frameDt: Race.tickDuration, localInputs: [.none])
        relayed.advance(Race.tickDuration)
        direct.advance(Race.tickDuration)
        pump(0.001)
    }
    check(relayed.snapshots > 20, "race state didn't flow through the relay (\(relayed.snapshots))")
    check(server.relayedBytes > 20_000, "relay forwarded only \(server.relayedBytes) bytes")

    let lost = TestClient(.room("QQQQ", nearby: []), name: "Lost", secret: "ABCD", relay: relay)
    check(wait(6) { lost.closedReason != nil } && lost.closedReason!.contains("no game"), "unknown code not reported: \(lost.closedReason ?? "-")")

    print("   relay: room \(room), relayed and direct joins, \(server.relayedBytes / 1024) KB relayed")
    host.stop()
    check(wait(3) { relayed.closedReason != nil && direct.closedReason != nil }, "players didn't notice the host closing")
    pump(0.3)
    return problems
}

/// Minimal grid builder so these checks don't depend on the menu's settings type.
private struct RaceSettingsLite {
    var humans: Int
    var ai: Int

    func setup(trackID: String, seed: UInt64, ai aiOverride: Int? = nil) -> RaceSetup {
        setup(track: BuiltInTracks.all.first { $0.id == trackID }!, seed: seed, ai: aiOverride)
    }

    func setup(track def: TrackDefinition, seed: UInt64, ai aiOverride: Int? = nil) -> RaceSetup {
        let ai = aiOverride ?? self.ai
        var entrants = (0..<ai).map { Entrant(name: "AI\($0)", colorIndex: humans + $0, playerIndex: nil, aiSkill: 0.7) }
        entrants += (0..<humans).map { Entrant(name: "H\($0)", colorIndex: $0, playerIndex: $0) }
        return RaceSetup(track: def, entrants: entrants, laps: 1, seed: seed)
    }
}
