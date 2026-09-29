import SlicksCore
import SpriteKit

/// Race setup screen, fully keyboard/gamepad-free navigable with arrows and Enter.
final class MenuScene: GameScene {
    private enum Row: CaseIterable {
        case track, laps, players, opponents, skill, start
    }

    private static let skillLevels: [(name: String, value: Double)] = [
        ("Easy", 0.45), ("Normal", 0.75), ("Hard", 0.95),
    ]

    private unowned let coordinator: GameCoordinator
    private var settings: RaceSettings
    private var selected = Row.start
    private var rowLabels: [Row: SKLabelNode] = [:]
    private let preview = SKSpriteNode()
    private var previewCaption: SKLabelNode!

    init(coordinator: GameCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
        super.init()
    }

    override func didMove(to view: SKView) {
        let title = makeLabel(GameInfo.title.uppercased(), size: 60, color: .accent, align: .center)
        title.position = CGPoint(x: 480, y: 568)
        addChild(title)
        let subtitle = makeLabel("top-down slidin' mayhem for up to 4 players", size: 14, color: .dim, align: .center)
        subtitle.position = CGPoint(x: 480, y: 524)
        addChild(subtitle)

        for (i, row) in Row.allCases.enumerated() {
            let l = makeLabel("", size: 20)
            l.position = CGPoint(x: 60, y: 450 - CGFloat(i) * 48 - (row == .start ? 14 : 0))
            addChild(l)
            rowLabels[row] = l
        }

        preview.position = CGPoint(x: 712, y: 350)
        preview.size = CGSize(width: 400, height: 250)
        addChild(preview)
        let frame = SKShapeNode(rect: CGRect(x: -202, y: -127, width: 404, height: 254))
        frame.strokeColor = SKColor(white: 1, alpha: 0.35)
        frame.lineWidth = 2
        frame.position = preview.position
        addChild(frame)
        previewCaption = makeLabel("", size: 13, color: .dim, align: .center)
        previewCaption.position = CGPoint(x: 712, y: 206)
        addChild(previewCaption)

        let help = [
            "P1 Arrows    P2 W A S D    P3 I J K L    P4 Numpad 8 4 5 6",
            "Game controllers drive players 1-4 in connection order",
            "Up/Down select   Left/Right change   Enter race   Esc pause",
        ]
        for (i, line) in help.enumerated() {
            let l = makeLabel(line, size: 14, color: i == 0 ? .white : .dim, align: .center)
            l.position = CGPoint(x: 480, y: 120 - CGFloat(i) * 26)
            addChild(l)
        }
        refresh()
    }

    private var skillIndex: Int {
        let idx = MenuScene.skillLevels.enumerated().min { abs($0.element.value - settings.aiSkill) < abs($1.element.value - settings.aiSkill) }
        return idx?.offset ?? 1
    }

    private func refresh() {
        let lib = TrackLibrary.shared
        let def = lib.definitions[settings.trackIndex]
        let values: [Row: String] = [
            .track: "TRACK      < \(def.name) >",
            .laps: "LAPS       < \(settings.laps) >",
            .players: "PLAYERS    < \(settings.humanPlayers) >",
            .opponents: "OPPONENTS  < \(settings.aiOpponents) >",
            .skill: "AI SKILL   < \(MenuScene.skillLevels[skillIndex].name) >",
            .start: "START RACE",
        ]
        for (row, label) in rowLabels {
            let isSel = row == selected
            label.text = (isSel ? "> " : "  ") + (values[row] ?? "")
            label.fontColor = isSel ? .accent : .white
        }
        preview.texture = coordinator.previewTexture(for: lib.track(at: settings.trackIndex))
        let bridges = def.bridges.isEmpty ? "" : " - \(def.bridges.count) bridge\(def.bridges.count > 1 ? "s" : "")"
        previewCaption.text = "\(def.name) - \(def.theme.rawValue)\(bridges) - suggested \(def.defaultLaps) laps"
    }

    override func keyPressed(_ key: Key, isRepeat: Bool) {
        let rows = Row.allCases
        let idx = rows.firstIndex(of: selected)!
        switch key {
        case .up, .w:
            selected = rows[(idx - 1 + rows.count) % rows.count]
        case .down, .s, .tab:
            selected = rows[(idx + 1) % rows.count]
        case .left, .a:
            change(by: -1)
        case .right, .d:
            change(by: 1)
        case .enter, .space:
            if isRepeat { return }
            coordinator.settings = settings
            coordinator.startRace()
            return
        default:
            return
        }
        refresh()
    }

    private func change(by delta: Int) {
        let trackCount = TrackLibrary.shared.definitions.count
        switch selected {
        case .track:
            settings.trackIndex = (settings.trackIndex + delta + trackCount) % trackCount
            settings.laps = TrackLibrary.shared.definitions[settings.trackIndex].defaultLaps
        case .laps:
            settings.laps = clamp(settings.laps + delta, 1, 20)
        case .players:
            settings.humanPlayers = clamp(settings.humanPlayers + delta, 1, 4)
            settings.aiOpponents = min(settings.aiOpponents, GameInfo.maxCars - settings.humanPlayers)
        case .opponents:
            settings.aiOpponents = clamp(settings.aiOpponents + delta, 0, GameInfo.maxCars - settings.humanPlayers)
        case .skill:
            let i = clamp(skillIndex + delta, 0, MenuScene.skillLevels.count - 1)
            settings.aiSkill = MenuScene.skillLevels[i].value
        case .start:
            break
        }
        coordinator.settings = settings
    }
}
