import SlicksCore
import SpriteKit

/// Picks the tracks for a championship. Rounds run in track list order.
final class SeriesSetupScene: GameScene {
    private static let visibleRows = 11
    private static let rowSpacing: CGFloat = 27

    private unowned let coordinator: GameCoordinator
    /// Picking for an online game's lobby rather than starting a local series.
    private let online: OnlineSession?
    private let definitions = TrackLibrary.shared.definitions
    private var chosen: Set<String>
    /// Tracks first, then START and BACK.
    private var selected = 0
    private var scroll = 0
    private var trackLabels: [SKLabelNode] = []
    private var startLabel: SKLabelNode!
    private var backLabel: SKLabelNode!
    private var moreAbove: SKLabelNode!
    private var moreBelow: SKLabelNode!
    private let preview = SKSpriteNode()
    private var previewCaption: SKLabelNode!

    private var startRow: Int { definitions.count }
    private var backRow: Int { definitions.count + 1 }

    init(coordinator: GameCoordinator, online: OnlineSession? = nil) {
        self.coordinator = coordinator
        self.online = online
        let known = Set(definitions.map(\.id))
        let saved = (online?.seriesTrackIDs ?? coordinator.settings.seriesTrackIDs ?? []).filter(known.contains)
        chosen = Set(saved.isEmpty ? BuiltInTracks.all.map(\.id) : saved)
        super.init()
        selected = startRow
    }

    override func didMove(to view: SKView) {
        let title = makeLabel("CHAMPIONSHIP", size: 44, color: .accent, align: .center)
        title.position = CGPoint(x: 480, y: 575)
        addChild(title)
        let points = Series.pointsTable.map(String.init).joined(separator: " ")
        let subtitle = makeLabel("Race every track you pick. Points per place: \(points)", size: 14, color: .dim, align: .center)
        subtitle.position = CGPoint(x: 480, y: 536)
        addChild(subtitle)

        for i in 0..<SeriesSetupScene.visibleRows {
            let l = makeLabel("", size: 18)
            l.position = CGPoint(x: 60, y: 480 - CGFloat(i) * SeriesSetupScene.rowSpacing)
            addChild(l)
            trackLabels.append(l)
        }
        moreAbove = makeLabel("...", size: 14, color: .dim)
        moreAbove.position = CGPoint(x: 88, y: 500)
        addChild(moreAbove)
        moreBelow = makeLabel("...", size: 14, color: .dim)
        moreBelow.position = CGPoint(x: 88, y: 480 - CGFloat(SeriesSetupScene.visibleRows) * SeriesSetupScene.rowSpacing + 8)
        addChild(moreBelow)

        startLabel = makeLabel("", size: 20)
        startLabel.position = CGPoint(x: 60, y: 140)
        addChild(startLabel)
        backLabel = makeLabel("", size: 20)
        backLabel.position = CGPoint(x: 60, y: 108)
        addChild(backLabel)

        preview.position = CGPoint(x: 712, y: 350)
        preview.size = CGSize(width: 400, height: 250)
        preview.color = .clear
        addChild(preview)
        let frame = SKShapeNode(rect: CGRect(x: -202, y: -127, width: 404, height: 254))
        frame.strokeColor = SKColor(white: 1, alpha: 0.35)
        frame.lineWidth = 2
        frame.position = preview.position
        addChild(frame)
        previewCaption = makeLabel("", size: 13, color: .dim, align: .center)
        previewCaption.position = CGPoint(x: 712, y: 206)
        addChild(previewCaption)

        let help = makeLabel("Up/Down select   Enter pick track / start   Esc back", size: 14, color: .dim, align: .center)
        help.position = CGPoint(x: 480, y: 50)
        addChild(help)
        refresh()
        coordinator.prewarmPreviews()
    }

    private var rounds: [String] { definitions.map(\.id).filter(chosen.contains) }

    private func refresh() {
        let visible = SeriesSetupScene.visibleRows
        if selected < startRow {
            scroll = clamp(scroll, selected - visible + 1, selected)
        }
        scroll = clamp(scroll, 0, max(0, definitions.count - visible))
        for (i, label) in trackLabels.enumerated() {
            let index = scroll + i
            guard definitions.indices.contains(index) else { label.text = ""; continue }
            let def = definitions[index]
            let isSel = index == selected
            let mark = chosen.contains(def.id) ? "[x]" : "[ ]"
            label.text = (isSel ? "> " : "  ") + "\(mark) \(def.name)"
            label.fontColor = isSel ? .accent : chosen.contains(def.id) ? .white : .dim
        }
        moreAbove.isHidden = scroll == 0
        moreBelow.isHidden = scroll + visible >= definitions.count

        let count = rounds.count
        let action = online == nil ? "START SERIES" : "USE THESE TRACKS"
        startLabel.text = (selected == startRow ? "> " : "  ") + "\(action) (\(count) race\(count == 1 ? "" : "s"))"
        startLabel.fontColor = selected == startRow ? .accent : count == 0 ? .dim : .white
        backLabel.text = (selected == backRow ? "> " : "  ") + "BACK"
        backLabel.fontColor = selected == backRow ? .accent : .white

        let shown = selected < startRow ? selected : definitions.firstIndex { chosen.contains($0.id) } ?? 0
        let def = definitions[shown]
        showPreview(at: shown)
        previewCaption.text = "\(def.name) - \(def.theme.rawValue) - \(def.defaultLaps) laps"
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

    private func leave() {
        online == nil ? coordinator.showMenu() : coordinator.showLobby()
    }

    override func keyPressed(_ key: Key, isRepeat: Bool) {
        let rowCount = definitions.count + 2
        switch key {
        case .up, .w:
            selected = (selected - 1 + rowCount) % rowCount
            SoundSystem.shared.play(.menuMove)
        case .down, .s, .tab:
            selected = (selected + 1) % rowCount
            SoundSystem.shared.play(.menuMove)
        case .enter, .space:
            if isRepeat { return }
            if selected == backRow {
                SoundSystem.shared.play(.menuSelect)
                return leave()
            }
            if selected == startRow {
                guard !rounds.isEmpty else { return }
                SoundSystem.shared.play(.menuSelect)
                guard let online else { return coordinator.startSeries(trackIDs: rounds) }
                online.seriesTrackIDs = rounds
                return coordinator.showLobby()
            }
            let id = definitions[selected].id
            if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
            SoundSystem.shared.play(.menuMove)
        case .escape:
            if isRepeat { return }
            return leave()
        default:
            return
        }
        refresh()
    }
}

/// Championship table between rounds, and the final result.
final class SeriesStandingsScene: GameScene {
    private unowned let coordinator: GameCoordinator
    private let series: Series

    init(coordinator: GameCoordinator, series: Series) {
        self.coordinator = coordinator
        self.series = series
        super.init()
    }

    override func didMove(to view: SKView) {
        let library = TrackLibrary.shared
        let standings = series.standings
        let rounds = series.trackIDs.count

        let title = makeLabel(series.isComplete ? "FINAL STANDINGS" : "CHAMPIONSHIP STANDINGS", size: 40, color: .accent, align: .center)
        title.position = CGPoint(x: 480, y: 575)
        addChild(title)
        let subtitle = makeLabel("After round \(series.roundsCompleted) of \(rounds)", size: 15, color: .dim, align: .center)
        subtitle.position = CGPoint(x: 480, y: 538)
        addChild(subtitle)

        func columns(_ pos: String, _ name: String, _ wins: String, _ last: String, _ points: String) -> String {
            func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
                let p = String(repeating: " ", count: max(0, w - s.count))
                return right ? p + s : s + p
            }
            return pad(pos, 4) + pad(name, 13) + pad(wins, 5, right: true) + pad(last, 7, right: true) + pad(points, 6, right: true)
        }

        let tableX: CGFloat = 60
        let header = makeLabel(columns("POS", "DRIVER", "WINS", "LAST", "PTS"), size: 17, color: .dim)
        header.position = CGPoint(x: tableX, y: 490)
        addChild(header)

        let lastRound = series.roundsCompleted - 1
        let rowSpacing: CGFloat = standings.count > 6 ? 34 : 40
        for (i, standing) in standings.enumerated() {
            let entrant = series.entrants[standing.entrant]
            let y = 454 - CGFloat(i) * rowSpacing
            let swatch = SKSpriteNode(color: CarArt.color(entrant.colorIndex), size: CGSize(width: 12, height: 12))
            swatch.position = CGPoint(x: tableX - 18, y: y)
            addChild(swatch)
            let last = lastRound >= 0 ? "+\(series.points(of: standing.entrant, inRound: lastRound))" : "-"
            let isHuman = entrant.playerIndex != nil
            let row = makeLabel(columns("\(i + 1).", entrant.name, "\(standing.wins)", last, "\(standing.points)"),
                                size: 17, color: isHuman ? .accent : .white)
            row.position = CGPoint(x: tableX, y: y)
            addChild(row)
        }

        let help: String
        if let champion = series.champion {
            let banner = makeLabel("\(series.entrants[champion.entrant].name.uppercased()) WINS THE CHAMPIONSHIP!",
                                   size: 26, color: .accent, align: .center)
            banner.position = CGPoint(x: 480, y: 140)
            addChild(banner)
            let detail = makeLabel("\(champion.points) points - \(champion.wins) win\(champion.wins == 1 ? "" : "s") from \(rounds) race\(rounds == 1 ? "" : "s")",
                                   size: 15, color: .white, align: .center)
            detail.position = CGPoint(x: 480, y: 104)
            addChild(detail)
            help = "Enter back to the menu"
        } else if let id = series.nextTrackID, let index = library.index(of: id) {
            let def = library.definitions[index]
            let caption = makeLabel("NEXT: ROUND \(series.roundsCompleted + 1) - \(def.name.uppercased())", size: 17, color: .accent, align: .center)
            caption.position = CGPoint(x: 712, y: 490)
            addChild(caption)
            let preview = SKSpriteNode(color: .clear, size: CGSize(width: 400, height: 250))
            coordinator.loadPreview(at: index) { preview.texture = $0 }
            preview.position = CGPoint(x: 712, y: 330)
            addChild(preview)
            let frame = SKShapeNode(rect: CGRect(x: -202, y: -127, width: 404, height: 254))
            frame.strokeColor = SKColor(white: 1, alpha: 0.35)
            frame.lineWidth = 2
            frame.position = preview.position
            addChild(frame)
            let laps = makeLabel("\(def.theme.rawValue) - \(def.defaultLaps) laps", size: 13, color: .dim, align: .center)
            laps.position = CGPoint(x: 712, y: 186)
            addChild(laps)
            help = "Enter start next race   Q quit series"
        } else {
            help = "Enter back to the menu"
        }
        let helpLabel = makeLabel(help, size: 14, color: .dim, align: .center)
        helpLabel.position = CGPoint(x: 480, y: 50)
        addChild(helpLabel)
    }

    private var canContinue: Bool {
        guard let id = series.nextTrackID else { return false }
        return TrackLibrary.shared.index(of: id) != nil
    }

    override func keyPressed(_ key: Key, isRepeat: Bool) {
        guard !isRepeat else { return }
        switch key {
        case .enter, .space:
            SoundSystem.shared.play(.menuSelect)
            canContinue ? coordinator.startSeriesRound() : coordinator.endSeries()
        case .q:
            coordinator.endSeries()
        case .escape where !canContinue:
            coordinator.endSeries()
        default:
            break
        }
    }
}
