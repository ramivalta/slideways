import Foundation
import SlicksCore
import SlicksLink
import SlicksNet

/// An online game, hosted here or joined. Owns the connection and moves everyone between the
/// lobby and the race screen.
final class OnlineSession {
    enum Role {
        case host(NetHost)
        case client(NetClient)
    }

    let role: Role
    let name: String
    let localPlayers: Int
    /// Race options. Only the host's are used; clients show what the lobby says.
    var settings: RaceSettings {
        didSet { publishLobby() }
    }
    /// Latest lobby: built here when hosting, received when joined.
    private(set) var lobby: LobbyInfo?
    /// One-line state for the lobby screen ("Connecting...", listening port).
    private(set) var status: String?
    /// Save the host's race picks as the menu defaults. Off for scripted test runs.
    var persistsSettings = true

    /// Host: the next start begins a championship instead of a single race.
    var seriesMode = false {
        didSet { publishLobby() }
    }
    /// Host: rounds for the next championship.
    var seriesTrackIDs: [String] {
        didSet { publishLobby() }
    }
    /// Laps for every championship round instead of each track's own. For scripted test runs.
    var seriesLaps: Int?
    /// Host: the championship being run, if any.
    private(set) var series: Series?
    /// Who drives each series entrant; nil for computer drivers.
    private var seats: [Seat?] = []
    /// Round of the race on screen (or last raced), nil when it's not a championship round.
    private(set) var raceRound: (round: Int, of: Int)?

    private struct Seat {
        /// 0 for the host, nil after the player left (the car is then driven by the AI).
        var clientID: Int?
        /// The machine's player name, so someone who drops out can take their seat back.
        let name: String
        let localIndex: Int
    }

    private unowned let coordinator: GameCoordinator
    private var clientRace: ClientRaceController?
    /// Last track built for an online race, so racing it again doesn't rebuild it.
    private var trackCache: Track?
    private var closed = false

    var isHost: Bool {
        if case .host = role { return true }
        return false
    }

    private init(coordinator: GameCoordinator, role: Role, name: String, localPlayers: Int) {
        self.coordinator = coordinator
        self.role = role
        self.name = name
        self.localPlayers = localPlayers
        var s = coordinator.settings
        s.humanPlayers = localPlayers
        settings = s
        let known = Set(TrackLibrary.shared.definitions.map(\.id))
        let saved = (s.seriesTrackIDs ?? []).filter(known.contains)
        seriesTrackIDs = saved.isEmpty ? BuiltInTracks.all.map(\.id) : saved
    }

    /// - Parameter relayServer: "host[:port]" of a rendezvous/relay server, or nil.
    static func host(coordinator: GameCoordinator, name: String, localPlayers: Int, requireCode: Bool,
                     relayServer: String?) -> OnlineSession {
        let host = NetHost(name: name, localPlayers: localPlayers, requireCode: requireCode, relayServer: relayServer)
        let session = OnlineSession(coordinator: coordinator, role: .host(host), name: name, localPlayers: localPlayers)
        session.status = "Starting..."
        host.onListening = { [weak session] port in
            session?.status = "Listening on UDP port \(port)"
            session?.refresh()
        }
        host.onError = { [weak session] in session?.fail($0) }
        host.onChange = { [weak session] in session?.publishLobby() }
        host.admitPlayer = { [weak session] name, count in session?.seriesRefusal(name: name, localPlayers: count) }
        host.start()
        session.publishLobby()
        return session
    }

    /// - Parameters:
    ///   - secret: the part of the join code after the dash, or "" for open games.
    ///   - label: shown while connecting.
    static func join(coordinator: GameCoordinator, target: NetClient.Target, label: String, secret: String,
                     relayServer: String?, name: String, localPlayers: Int) -> OnlineSession {
        let client = NetClient(target: target, name: name, localPlayers: localPlayers, secret: secret, relayServer: relayServer)
        let session = OnlineSession(coordinator: coordinator, role: .client(client), name: name, localPlayers: localPlayers)
        session.status = "Connecting to \(label)..."
        client.onStatus = { [weak session] text in
            guard let session, session.lobby == nil else { return }
            session.status = text
            session.refresh()
        }
        client.onWelcome = { [weak session] in
            session?.status = client.route?.isRelayed == true ? "Connected through the relay server" : nil
            session?.refresh()
        }
        client.onLobby = { [weak session] info in
            session?.lobby = info
            session?.refresh()
        }
        client.onStart = { [weak session] id, setup, slots in session?.clientStart(raceID: id, setup: setup, slots: slots) }
        client.onSnapshot = { [weak session] id, ack, state in
            guard let race = session?.clientRace, race.raceID == id else { return }
            race.receive(ack: ack, state: state)
        }
        client.onSand = { [weak session] id, delta in
            guard let race = session?.clientRace, race.raceID == id else { return }
            race.receiveSand(delta)
        }
        client.onRubber = { [weak session] id, delta in
            guard let race = session?.clientRace, race.raceID == id else { return }
            race.receiveRubber(delta)
        }
        client.onRaceEnded = { [weak session] id in
            guard let session, session.clientRace?.raceID == id else { return }
            session.clientRace = nil
            session.coordinator.showLobby()
        }
        client.onClose = { [weak session] in session?.fail($0) }
        client.connect()
        return session
    }

    // MARK: Lobby

    var netHost: NetHost? {
        if case let .host(h) = role { return h }
        return nil
    }

    /// Addresses others on this network can type to join.
    var joinAddresses: [String] {
        guard let host = netHost, let port = host.port else { return [] }
        let suffix = port == NetProtocol.defaultPort ? "" : ":\(port)"
        return SocketAddress.localAddresses(port: port).filter(\.isIPv4).prefix(3).map { $0.host + suffix }
    }

    /// How players outside this network can get in, one line each, for the lobby.
    var internetStatus: [(text: String, good: Bool)] {
        guard let host = netHost else { return [] }
        var lines: [(String, Bool)] = []
        var reachable = false
        switch host.relayState {
        case .off: break
        case .connecting: lines.append(("Contacting the relay server...", true))
        case .registered:
            reachable = true
            lines.append(("Anyone with the code can join over the internet", true))
        case let .failed(reason): lines.append(("Relay server: \(reason)", false))
        }
        switch host.portMapping {
        case .off: break
        case .trying: lines.append(("Asking your router to open a port...", true))
        case let .mapped(external, method):
            reachable = true
            lines.append(("Your router opened UDP port \(external.port) (\(method)): internet address \(external)", true))
        case let .unavailable(reason):
            if !reachable { lines.append(("Router: \(reason)", false)) }
        }
        if !reachable, host.relayState == .off, host.portMapping != .trying {
            lines.append(("Internet players can't reach you yet: set a relay server on the Online screen,", false))
            lines.append(("or forward UDP port \(host.port ?? NetProtocol.defaultPort) on your router", false))
        }
        return lines
    }

    var humanCount: Int {
        switch role {
        case let .host(host): host.humanCount
        case .client: lobby?.humanCount ?? localPlayers
        }
    }

    private func publishLobby() {
        guard case let .host(host) = role else { return refresh() }
        claimSeats()
        let lib = TrackLibrary.shared
        var def = lib.definitions[clamp(settings.trackIndex, 0, lib.definitions.count - 1)]
        var laps = settings.laps
        var ai = min(settings.aiOpponents, GameInfo.maxCars - host.humanCount)
        var lobbySeries: LobbySeries?
        if let series {
            if let id = series.nextTrackID, let i = lib.index(of: id) { def = lib.definitions[i] }
            laps = seriesLaps ?? def.defaultLaps
            ai = series.entrants.filter { $0.playerIndex == nil }.count
            let last = series.roundsCompleted - 1
            lobbySeries = LobbySeries(roundsCompleted: series.roundsCompleted, rounds: series.trackIDs.count,
                                      standings: series.standings.map { s in
                                          let e = series.entrants[s.entrant]
                                          return .init(name: e.name, colorIndex: e.colorIndex, points: s.points, wins: s.wins,
                                                       last: last >= 0 ? series.points(of: s.entrant, inRound: last) : nil,
                                                       isHuman: e.playerIndex != nil)
                                      })
        } else if seriesMode {
            if let id = seriesTrackIDs.first, let i = lib.index(of: id) { def = lib.definitions[i] }
            laps = seriesLaps ?? def.defaultLaps
            lobbySeries = LobbySeries(roundsCompleted: 0, rounds: seriesTrackIDs.count, standings: [])
        }
        let info = LobbyInfo(players: host.lobbyPlayers, trackName: def.name, laps: laps, aiOpponents: max(0, ai),
                             aiSkillName: MenuScene.skillName(settings.aiSkill), inRace: host.raceID != nil,
                             series: lobbySeries)
        lobby = info
        host.updateLobby(info)
        refresh()
    }

    /// The lobby screen while it's up. Registered by the scene itself: during a scene
    /// transition the view still reports the old scene, and updates would be lost.
    weak var lobbyScene: LobbyScene?

    private func refresh() {
        lobbyScene?.refresh()
    }

    // MARK: Access (host)

    var requireCode: Bool {
        get { netHost?.requireCode ?? true }
        set { netHost?.requireCode = newValue }
    }

    func newCode() { netHost?.newCode() }

    func kick(clientID: Int) { netHost?.kick(clientID: clientID) }

    // MARK: Races

    /// Host: puts everyone in the lobby onto the grid, for a single race or the championship's next round.
    func startRace() {
        guard case let .host(host) = role, host.raceID == nil else { return }
        if seriesMode, series == nil { beginSeries(host) }
        let seed = RaceSetup.randomSeed()
        let track: Track
        let setup: RaceSetup
        var slots: [Int: [Int]] = [:]
        if let series {
            guard let id = series.nextTrackID, let index = TrackLibrary.shared.index(of: id) else { return }
            claimSeats()
            track = TrackLibrary.shared.track(at: index)
            var entrants = series.entrants
            for (i, seat) in seats.enumerated() {
                guard let seat, let slot = entrants[i].playerIndex else { continue }
                if let owner = seat.clientID {
                    slots[owner, default: []].append(slot)
                } else {
                    entrants[i].playerIndex = nil
                    entrants[i].aiSkill = settings.aiSkill
                }
            }
            setup = RaceSetup(track: track.definition, entrants: entrants, laps: seriesLaps ?? track.definition.defaultLaps, seed: seed)
            raceRound = (series.roundsCompleted + 1, series.trackIDs.count)
        } else {
            let grid = humanGrid(host)
            for (slot, owner) in grid.owners.enumerated() { slots[owner.clientID ?? 0, default: []].append(slot) }
            track = TrackLibrary.shared.track(at: settings.trackIndex)
            setup = RaceSetup(track: track.definition, entrants: settings.entrants(seed: seed, humans: grid.names),
                              laps: settings.laps, seed: seed)
            raceRound = nil
        }
        let hostSlots = slots.removeValue(forKey: 0) ?? []
        // Clients read the round number from the lobby, so it goes out ahead of the start.
        publishLobby()
        host.startRace(setup: setup, slots: slots)
        if persistsSettings {
            // Remember the host's picks for next time, like the local menu does.
            coordinator.settings.trackIndex = settings.trackIndex
            coordinator.settings.laps = settings.laps
            coordinator.settings.aiOpponents = settings.aiOpponents
            coordinator.settings.aiSkill = settings.aiSkill
            if seriesMode { coordinator.settings.seriesTrackIDs = seriesTrackIDs }
            coordinator.settings.save()
        }
        publishLobby()
        let controller = HostRaceController(race: Race(setup: setup, track: track), host: host, localSlots: hostSlots)
        coordinator.present(RaceScene(coordinator: coordinator, controller: controller, mode: .online(self)))
    }

    /// Everyone in the lobby, in input slot order: the host's players, then each client's.
    private func humanGrid(_ host: NetHost) -> (names: [String], owners: [Seat]) {
        var names: [String] = []
        var owners: [Seat] = []
        func add(_ name: String, id: Int, count: Int) {
            for k in 0..<count {
                names.append(count > 1 ? "\(name.prefix(NetProtocol.maxNameLength - 2)) \(k + 1)" : name)
                owners.append(Seat(clientID: id, name: name, localIndex: k))
            }
        }
        add(name, id: 0, count: localPlayers)
        for c in host.clients { add(c.name, id: c.id, count: c.localPlayers) }
        return (names, owners)
    }

    private func beginSeries(_ host: NetHost) {
        let known = Set(TrackLibrary.shared.definitions.map(\.id))
        let rounds = seriesTrackIDs.filter(known.contains)
        guard !rounds.isEmpty else { return }
        let grid = humanGrid(host)
        let entrants = settings.entrants(seed: RaceSetup.randomSeed(), humans: grid.names)
        series = Series(trackIDs: rounds, entrants: entrants)
        seats = entrants.map { e in e.playerIndex.map { grid.owners[$0] } }
    }

    /// Seats of players who left go to the AI; players who come back by the same name get theirs back.
    private func claimSeats() {
        guard let host = netHost, series != nil else { return }
        let present = Set(host.clients.map(\.id)).union([0])
        for i in seats.indices {
            if let id = seats[i]?.clientID, !present.contains(id) { seats[i]?.clientID = nil }
        }
        for c in host.clients where !seats.contains(where: { $0?.clientID == c.id }) {
            for i in seats.indices {
                guard let seat = seats[i], seat.clientID == nil, seat.name == c.name, seat.localIndex < c.localPlayers else { continue }
                seats[i]?.clientID = c.id
            }
        }
    }

    /// Mid-championship, only players with a seat to come back to get in.
    private func seriesRefusal(name: String, localPlayers: Int) -> String? {
        guard let series, !series.isComplete else { return nil }
        claimSeats()
        let free = Set(seats.compactMap { $0 }.filter { $0.clientID == nil && $0.name == name }.map(\.localIndex))
        return free.isSuperset(of: 0..<localPlayers) ? nil : "a championship is in progress, try again when it's over"
    }

    /// Host: scores the round just finished. `finishingOrder` holds car ids, winner first.
    func recordSeriesRound(finishingOrder: [Int]) {
        series?.record(finishingOrder: finishingOrder)
        publishLobby()
    }

    /// Host: drops the championship, back to picking races.
    func endSeries() {
        series = nil
        seats = []
        publishLobby()
    }

    /// Host: race over (or abandoned), everyone back to the lobby.
    func returnToLobby() {
        guard case let .host(host) = role else { return }
        host.endRace()
        publishLobby()
        coordinator.showLobby()
    }

    private func clientStart(raceID: UInt32, setup: RaceSetup, slots: [Int]) {
        guard case let .client(client) = role else { return }
        if let problem = OnlineRules.problem(with: setup, slots: slots, localPlayers: localPlayers) {
            return fail("the host started a race this game can't run: \(problem)")
        }
        let track: Track
        if let cached = trackCache, cached.definition == setup.track {
            track = cached
        } else if let i = TrackLibrary.shared.index(of: setup.track.id),
                  TrackLibrary.shared.definitions[i] == setup.track {
            track = TrackLibrary.shared.track(at: i)
        } else {
            track = Track(definition: setup.track)
            guard track.sampleCount >= 20 else { return fail("the host's track is too small to race on") }
        }
        trackCache = track
        if let s = lobby?.series, !s.isComplete {
            raceRound = (s.roundsCompleted + 1, s.rounds)
        } else {
            raceRound = nil
        }
        let controller = ClientRaceController(race: Race(setup: setup, track: track), raceID: raceID,
                                              localSlots: slots, client: client)
        clientRace = controller
        coordinator.present(RaceScene(coordinator: coordinator, controller: controller, mode: .online(self)))
    }

    // MARK: Leaving

    /// This player walks away (the host ends the game for everyone).
    func leave() {
        close(reason: isHost ? "the host closed the game" : "left the game")
        coordinator.showOnlineMenu(message: nil)
    }

    /// The app is quitting: hang up without changing screens.
    func closeForQuit() {
        close(reason: isHost ? "the host quit the game" : "left the game", quitting: true)
    }

    /// Something went wrong: back to the online menu with the reason.
    func fail(_ reason: String) {
        guard !closed else { return }
        #if DEBUG
        print("online: \(reason)")
        #endif
        close(reason: "connection problem")
        coordinator.showOnlineMenu(message: reason.prefix(1).uppercased() + reason.dropFirst())
    }

    private func close(reason: String, quitting: Bool = false) {
        guard !closed else { return }
        closed = true
        switch role {
        case let .host(host):
            host.onChange = nil
            host.onError = nil
            host.stop(reason: reason, quitting: quitting)
        case let .client(client):
            client.onClose = nil
            client.disconnect(reason: reason)
        }
        clientRace = nil
        coordinator.online = nil
    }
}

/// Checks on what a host sends before this machine acts on it: a broken or hostile setup must
/// not crash the game or lock it up building an absurd track.
enum OnlineRules {
    static func problem(with setup: RaceSetup, slots: [Int], localPlayers: Int) -> String? {
        let e = setup.entrants
        guard (1...GameInfo.maxCars).contains(e.count) else { return "\(e.count) cars" }
        guard (1...20).contains(setup.laps) else { return "\(setup.laps) laps" }
        let humanSlots = e.compactMap(\.playerIndex)
        guard Set(humanSlots).count == humanSlots.count, humanSlots.allSatisfy({ (0..<GameInfo.maxCars).contains($0) }) else {
            return "bad player slots"
        }
        guard slots.count == localPlayers, slots.allSatisfy(humanSlots.contains) else { return "no seat for this machine" }
        guard e.allSatisfy({ $0.spec == CarSpec() && $0.aiSkill.isFinite && $0.name.count <= 32 && (0..<64).contains($0.colorIndex) }) else {
            return "modified cars"
        }
        return trackProblem(setup.track)
    }

    static func trackProblem(_ d: TrackDefinition) -> String? {
        let map = EditorLimits.mapSize
        guard d.width == Int(map.width), d.height == Int(map.height) else { return "unsupported map size" }
        let pts = d.controlPoints
        guard (TrackDefinition.minControlPoints...400).contains(pts.count) else { return "\(pts.count) control points" }
        guard pts.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 10_000 && abs($0.y) < 10_000 }) else {
            return "control point off the map"
        }
        var perimeter = 0.0
        for i in pts.indices { perimeter += pts[i].distance(to: pts[(i + 1) % pts.count]) }
        guard perimeter > 200 else { return "track too short" }
        guard d.roadWidth.isFinite, (10...400).contains(d.roadWidth),
              d.pointWidths.count <= pts.count, d.pointWidths.allSatisfy({ $0.map { $0.isFinite && (10...400).contains($0) } ?? true })
        else { return "road width" }
        if let b = d.barrierDistance, !(b.isFinite && (0...400).contains(b)) { return "barrier distance" }
        guard d.barrierThickness.isFinite, (0...100).contains(d.barrierThickness) else { return "barrier thickness" }
        guard d.patches.count <= 500 else { return "too many patches" }
        for p in d.patches {
            let ok: Bool
            switch p.shape {
            case let .circle(c, r): ok = c.x.isFinite && c.y.isFinite && r.isFinite && (0...2000).contains(r)
            case let .rect(o, s): ok = [o.x, o.y, s.x, s.y].allSatisfy { $0.isFinite && abs($0) < 10_000 }
            case let .capsule(a, b, r): ok = [a.x, a.y, b.x, b.y, r].allSatisfy { $0.isFinite && abs($0) < 10_000 } && r >= 0
            }
            if !ok { return "bad patch" }
        }
        guard d.bridges.count <= EditorLimits.maxBridges,
              d.bridges.allSatisfy({ b in
                  pts.indices.contains(b.controlPoint)
                      && [b.back, b.ahead].allSatisfy { $0.map { $0.isFinite && (0...2000).contains($0) } ?? true }
              })
        else { return "bad bridge" }
        func onMap(_ p: Vec2) -> Bool { p.x.isFinite && p.y.isFinite && abs(p.x) < 10_000 && abs(p.y) < 10_000 }
        guard d.lines.count <= EditorLimits.maxLines * 2,
              d.lines.allSatisfy({ $0.points.count <= EditorLimits.maxLinePoints * 2 && $0.points.allSatisfy(onMap)
                  && $0.width.isFinite && (0...100).contains($0.width) })
        else { return "bad paint lines" }
        guard d.objects.count <= EditorLimits.maxObjects * 2,
              d.objects.allSatisfy({ onMap($0.position) && $0.angle.isFinite
                  && [$0.size.x, $0.size.y].allSatisfy { $0.isFinite && (0...1000).contains($0) } })
        else { return "bad track objects" }
        return nil
    }
}
