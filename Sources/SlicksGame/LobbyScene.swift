import Foundation
import SlicksCore
import SlicksNet
import SpriteKit

/// Waiting room before an online race. The host picks the race and controls who gets in;
/// everyone sees who's there.
final class LobbyScene: GameScene {
    private enum Row: Hashable {
        case mode, track, rounds, laps, opponents, skill, access, newCode, start, endSeries, leave
        /// A joined player (client id), which the host can remove.
        case player(Int)
    }

    private unowned let coordinator: GameCoordinator
    private let session: OnlineSession
    private var selected: Row
    /// Asked "remove this player?" and waiting for a second Enter.
    private var confirmingKick: Int?
    /// Asked "end the championship?" and waiting for a second Enter.
    private var confirmingEnd = false
    private var dynamic: [SKNode] = []
    private let preview = SKSpriteNode()
    private let previewFrame = SKShapeNode(rect: CGRect(x: -130, y: -82, width: 260, height: 164))

    init(coordinator: GameCoordinator, session: OnlineSession) {
        self.coordinator = coordinator
        self.session = session
        selected = session.isHost ? .start : .leave
        super.init()
    }

    override func didMove(to view: SKView) {
        let title = makeLabel(session.isHost ? "HOSTING" : "LOBBY", size: 40, color: .accent, align: .center)
        title.position = CGPoint(x: 480, y: 596)
        addChild(title)

        let help = session.isHost
            ? "Up/Down select   Left/Right change   Enter choose   Esc close the game"
            : "The host picks the track and starts the race   Esc leave"
        let helpLabel = makeLabel(help, size: 14, color: .dim, align: .center)
        helpLabel.position = CGPoint(x: 480, y: 24)
        addChild(helpLabel)

        if session.isHost {
            preview.position = CGPoint(x: 752, y: 452)
            preview.size = CGSize(width: 256, height: 160)
            preview.color = .clear
            addChild(preview)
            previewFrame.strokeColor = SKColor(white: 1, alpha: 0.35)
            previewFrame.lineWidth = 2
            previewFrame.position = preview.position
            addChild(previewFrame)
        }
        session.lobbyScene = self
        refresh()
    }

    override func willMove(from view: SKView) {
        if session.lobbyScene === self { session.lobbyScene = nil }
    }

    private var previewIndex: Int?

    private func showPreview(at index: Int) {
        guard index != previewIndex else { return }
        previewIndex = index
        preview.alpha = 0.3
        coordinator.loadPreview(at: index) { [weak self] texture in
            guard let self, self.previewIndex == index else { return }
            self.preview.texture = texture
            self.preview.alpha = 1
        }
    }

    private var playerRows: [Row] {
        guard session.isHost else { return [] }
        return (session.lobby?.players ?? []).dropFirst().map { .player($0.id) }
    }

    private var hostRows: [Row] {
        if let series = session.series {
            return [.access, .newCode] + (series.isComplete ? [] : [.start]) + [.endSeries, .leave]
        }
        return [.mode] + (session.seriesMode ? [.rounds] : [.track, .laps]) + [.opponents, .skill, .access, .newCode, .start, .leave]
    }

    private var rows: [Row] {
        session.isHost ? hostRows + playerRows : [.leave]
    }

    func refresh() {
        for n in dynamic { n.removeFromParent() }
        dynamic.removeAll()
        let rows = rows
        if !rows.contains(selected) { selected = rows.contains(.start) ? .start : rows.contains(.endSeries) ? .endSeries : .leave }
        if case let .player(id) = selected, confirmingKick != id { confirmingKick = nil }
        if selected != .endSeries { confirmingEnd = false }

        func add(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 19, color: SKColor = .white,
                 align: SKLabelHorizontalAlignmentMode = .left) {
            let l = makeLabel(text, size: size, color: color, align: align)
            l.position = CGPoint(x: x, y: y)
            addChild(l)
            dynamic.append(l)
        }
        func row(_ r: Row, _ text: String, x: CGFloat = 50, y: CGFloat, size: CGFloat = 19, color: SKColor = .white) {
            let isSel = r == selected
            add((isSel ? "> " : "  ") + text, x: x, y: y, size: size, color: isSel ? .accent : color)
        }

        let lobby = session.lobby
        let s = session.settings
        let lib = TrackLibrary.shared
        let humans = session.humanCount
        let maxAI = max(0, GameInfo.maxCars - humans)
        let bad = SKColor(red: 1, green: 0.45, blue: 0.4, alpha: 1)
        let lobbySeries = lobby?.series
        let standings = lobbySeries?.standings ?? []
        var y: CGFloat = 530

        /// Championship lines above the rows: the round, and the next track or the champion.
        func seriesLines(_ ls: LobbySeries, spacing: CGFloat) {
            if ls.isComplete {
                add("  CHAMPIONSHIP OVER", x: 50, y: y)
                y -= spacing
                if let champion = ls.standings.first {
                    add("  CHAMPION   \(champion.name)", x: 50, y: y, color: .accent)
                    y -= spacing
                }
            } else {
                add("  ROUND      \(ls.roundsCompleted + 1) of \(ls.rounds)", x: 50, y: y)
                y -= spacing
            }
        }

        if let host = session.netHost {
            // The code, big: it's what the host reads out to friends.
            add("CODE", x: 50, y: y + 6, size: 14, color: .dim)
            add(host.joinCode, x: 110, y: y, size: 34, color: .accent)
            add(host.requireCode ? "players type this to join" : "open: anyone who finds the game can join",
                x: 110, y: y - 30, size: 13, color: .dim)
            y -= 72

            let def = lib.definitions[clamp(s.trackIndex, 0, lib.definitions.count - 1)]
            let rounds = session.seriesTrackIDs.count
            var values: [Row: String] = [
                .mode: "MODE       < \(session.seriesMode ? "Championship" : "Single race") >",
                .track: "TRACK      < \(def.name) >",
                .rounds: "TRACKS     \(rounds) race\(rounds == 1 ? "" : "s") (Enter)",
                .laps: "LAPS       < \(s.laps) >",
                .opponents: "OPPONENTS  < \(min(s.aiOpponents, maxAI)) >",
                .skill: "AI SKILL   < \(MenuScene.skillName(s.aiSkill)) >",
                .access: "ACCESS     < \(host.requireCode ? "Code needed" : "Open") >",
                .newCode: "NEW CODE",
                .start: session.seriesMode ? "START CHAMPIONSHIP" : "START RACE",
                .leave: "CLOSE GAME",
            ]
            if let series = session.series, let lobby, let lobbySeries {
                seriesLines(lobbySeries, spacing: 33)
                if !series.isComplete {
                    add("  TRACK      \(lobby.trackName)", x: 50, y: y)
                    y -= 33
                    add("  LAPS       \(lobby.laps)", x: 50, y: y)
                    y -= 41
                }
                values[.start] = "START ROUND \(series.roundsCompleted + 1)"
                values[.endSeries] = series.isComplete ? "DONE" : confirmingEnd ? "Enter again to end the championship" : "END CHAMPIONSHIP"
            }
            for r in hostRows {
                if r == .start { y -= 8 }
                row(r, values[r] ?? "", y: y)
                y -= 33
            }
            let previewID = session.seriesMode ? session.seriesTrackIDs.first : nil
            showPreview(at: previewID.flatMap(lib.index(of:)) ?? s.trackIndex)
            preview.isHidden = !standings.isEmpty
            previewFrame.isHidden = !standings.isEmpty
        } else if let lobby {
            if let lobbySeries {
                add("  MODE       Championship", x: 50, y: y)
                y -= 34
                seriesLines(lobbySeries, spacing: 34)
            }
            var lines = ["TRACK      \(lobby.trackName)", "LAPS       \(lobby.laps)",
                         "OPPONENTS  \(lobby.aiOpponents)", "AI SKILL   \(lobby.aiSkillName)"]
            if lobbySeries?.isComplete == true { lines.removeFirst(2) }
            for line in lines {
                add("  " + line, x: 50, y: y)
                y -= lobbySeries == nil ? 38 : 34
            }
            y -= 12
            add(lobby.inRace ? "  Race in progress, you're in the next one" : "  Waiting for the host to start...", x: 50, y: y, color: .dim)
            y -= 38
            row(.leave, "LEAVE", y: y)
            if let status = session.status { add("  " + status, x: 50, y: y - 40, size: 14, color: .dim) }
        } else {
            add("  " + (session.status ?? "Connecting..."), x: 50, y: y, color: .dim)
            y -= 50
            row(.leave, "CANCEL", y: y)
        }

        // Championship table, where the host's track preview would be.
        let listX: CGFloat = 560
        if let lobbySeries, !standings.isEmpty {
            func columns(_ pos: String, _ name: String, _ wins: String, _ last: String, _ points: String) -> String {
                func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
                    let p = String(repeating: " ", count: max(0, w - s.count))
                    return right ? p + s : s + p
                }
                return pad(pos, 4) + pad(name, 13) + pad(wins, 5, right: true) + pad(last, 5, right: true) + pad(points, 5, right: true)
            }
            let done = lobbySeries.roundsCompleted
            add(lobbySeries.isComplete ? "FINAL STANDINGS" : done == 0 ? "CHAMPIONSHIP" : "STANDINGS AFTER ROUND \(done) OF \(lobbySeries.rounds)",
                x: listX, y: 545, size: 14, color: lobbySeries.isComplete ? .accent : .dim)
            add(columns("POS", "DRIVER", "WINS", "LAST", "PTS"), x: listX, y: 522, size: 13, color: .dim)
            for (i, st) in standings.enumerated() {
                let sy = 500 - CGFloat(i) * 20
                let swatch = SKSpriteNode(color: CarArt.color(st.colorIndex), size: CGSize(width: 10, height: 10))
                swatch.position = CGPoint(x: listX - 12, y: sy)
                addChild(swatch)
                dynamic.append(swatch)
                let last = st.last.map { "+\($0)" } ?? "-"
                add(columns("\(i + 1).", String(st.name.prefix(12)), "\(st.wins)", last, "\(st.points)"),
                    x: listX, y: sy, size: 14, color: st.isHuman ? .accent : .white)
            }
        }

        // Who's in. The host can walk down into this list to remove someone.
        var ly: CGFloat = session.isHost || !standings.isEmpty ? 340 : 530
        add("PLAYERS \(humans)/\(GameInfo.maxCars)", x: listX, y: ly, size: 14, color: .dim)
        ly -= 28
        for (i, p) in (lobby?.players ?? []).enumerated() {
            let count = p.localPlayers > 1 ? " x\(p.localPlayers)" : ""
            let role = i == 0 ? " (host)" : ""
            let ping = p.pingMs.map { "\($0) ms" } ?? ""
            if session.isHost, i > 0 {
                let asking = confirmingKick == p.id
                row(.player(p.id), asking ? "Enter again to remove \(p.name)" : "\(p.name)\(count)", x: listX - 24, y: ly, size: 17,
                    color: CarArt.color(i))
            } else {
                add("\(p.name)\(count)\(role)", x: listX, y: ly, size: 17, color: CarArt.color(i))
            }
            add(ping, x: 930, y: ly, size: 14, color: .dim, align: .right)
            ly -= 25
        }

        // How others get in.
        if session.isHost {
            var hy: CGFloat = 96
            let addresses = session.joinAddresses
            if !addresses.isEmpty {
                add("On this network: listed on their ONLINE screen, or address \(addresses.joined(separator: "  "))",
                    x: 50, y: hy, size: 13, color: .dim)
                hy -= 20
            }
            for line in session.internetStatus.prefix(3) {
                add(line.text, x: 50, y: hy, size: 13, color: line.good ? .dim : bad)
                hy -= 20
            }
        }
    }

    override func keyPressed(_ key: Key, isRepeat: Bool) {
        if key == .escape || key == .q {
            if confirmingKick != nil || confirmingEnd {
                confirmingKick = nil
                confirmingEnd = false
                return refresh()
            }
            return session.leave()
        }
        guard session.isHost else {
            if key == .enter || key == .space { session.leave() }
            return
        }
        let rows = rows
        let idx = rows.firstIndex(of: selected) ?? 0
        switch key {
        case .up, .w:
            selected = rows[(idx - 1 + rows.count) % rows.count]
            SoundSystem.shared.play(.menuMove)
        case .down, .s, .tab:
            selected = rows[(idx + 1) % rows.count]
            SoundSystem.shared.play(.menuMove)
        case .left, .a:
            change(by: -1)
        case .right, .d:
            change(by: 1)
        case .enter, .space:
            if isRepeat { return }
            SoundSystem.shared.play(.menuSelect)
            switch selected {
            case .start: return session.startRace()
            case .leave: return session.leave()
            case .mode: session.seriesMode.toggle()
            case .rounds: return coordinator.showSeriesSetup(online: session)
            case .endSeries:
                if session.series?.isComplete == true || confirmingEnd {
                    confirmingEnd = false
                    session.endSeries()
                } else {
                    confirmingEnd = true
                }
            case .newCode: session.newCode()
            case .access: session.requireCode.toggle()
            case let .player(id):
                if confirmingKick == id {
                    confirmingKick = nil
                    session.kick(clientID: id)
                } else {
                    confirmingKick = id
                }
            default: return
            }
        default:
            return
        }
        refresh()
    }

    private func change(by delta: Int) {
        var s = session.settings
        let lib = TrackLibrary.shared
        switch selected {
        case .mode:
            SoundSystem.shared.play(.menuMove)
            session.seriesMode.toggle()
            return
        case .track:
            s.trackIndex = (s.trackIndex + delta + lib.definitions.count) % lib.definitions.count
            s.laps = lib.definitions[s.trackIndex].defaultLaps
        case .laps:
            s.laps = clamp(s.laps + delta, 1, 20)
        case .opponents:
            s.aiOpponents = clamp(min(s.aiOpponents, GameInfo.maxCars - session.humanCount) + delta, 0,
                                  max(0, GameInfo.maxCars - session.humanCount))
        case .skill:
            let i = clamp(MenuScene.skillIndex(s.aiSkill) + delta, 0, MenuScene.skillLevels.count - 1)
            s.aiSkill = MenuScene.skillLevels[i].value
        case .access:
            SoundSystem.shared.play(.menuMove)
            session.requireCode.toggle()
            return
        default:
            return
        }
        SoundSystem.shared.play(.menuMove)
        session.settings = s
    }
}
