import SlicksCore
import SpriteKit
#if os(macOS)
import AppKit
#endif

/// Race setup screen, fully keyboard/gamepad-free navigable with arrows and Enter.
final class MenuScene: GameScene {
    private enum Row: CaseIterable {
        case track, laps, players, name, opponents, skill, sound
        #if os(macOS)
        case display
        #endif
        case start, series, online
        #if os(macOS)
        case editor
        #endif

        var isAction: Bool {
            #if os(macOS)
            if self == .editor { return true }
            #endif
            return self == .start || self == .series || self == .online
        }

        /// Two-state rows ignore key repeat, so holding Left/Right doesn't flip them back and forth.
        var isToggle: Bool {
            #if os(macOS)
            return self == .display
            #else
            return false
            #endif
        }
    }

    static let skillLevels: [(name: String, value: Double)] = [
        ("Easy", 0.45), ("Normal", 0.75), ("Hard", 0.95),
    ]

    static func skillIndex(_ skill: Double) -> Int {
        skillLevels.enumerated().min { abs($0.element.value - skill) < abs($1.element.value - skill) }?.offset ?? 1
    }

    static func skillName(_ skill: Double) -> String { skillLevels[skillIndex(skill)].name }

    private unowned let coordinator: GameCoordinator
    private var settings: RaceSettings
    private var selected = Row.start
    private var namePlayer = 0
    private var replacingName = true
    private var rowLabels: [Row: SKLabelNode] = [:]
    private let preview = SKSpriteNode()
    private var previewCaption: SKLabelNode!
    private var fullScreenObservers: [NSObjectProtocol] = []

    init(coordinator: GameCoordinator) {
        self.coordinator = coordinator
        settings = coordinator.settings
        // Custom tracks can be deleted between launches.
        settings.trackIndex = clamp(settings.trackIndex, 0, TrackLibrary.shared.definitions.count - 1)
        super.init()
    }

    override func didMove(to view: SKView) {
        let title = makeLabel(GameInfo.title.uppercased(), size: 60, color: .accent, align: .center)
        title.position = CGPoint(x: 480, y: 568)
        addChild(title)
        let subtitle = makeLabel("top-down slidin' mayhem: 4 players per Mac, 8 online", size: 14, color: .dim, align: .center)
        subtitle.position = CGPoint(x: 480, y: 524)
        addChild(subtitle)

        // Up to twelve rows with the display, championship, online and editor entries: tighter
        // spacing keeps them clear of the help text.
        let spacing: CGFloat = Row.allCases.count > 11 ? 26 : Row.allCases.count > 10 ? 28 : Row.allCases.count > 9 ? 32 : Row.allCases.count > 8 ? 35 : 40
        for (i, row) in Row.allCases.enumerated() {
            let l = makeLabel("", size: 20)
            l.position = CGPoint(x: 60, y: 456 - CGFloat(i) * spacing - (row.isAction ? 12 : 0))
            addChild(l)
            rowLabels[row] = l
        }

        preview.position = CGPoint(x: 712, y: 350)
        preview.size = CGSize(width: 400, height: 250)
        addChild(preview)
        preview.color = .clear
        let frame = SKShapeNode(rect: CGRect(x: -202, y: -127, width: 404, height: 254))
        frame.strokeColor = SKColor(white: 1, alpha: 0.35)
        frame.lineWidth = 2
        frame.position = preview.position
        addChild(frame)
        previewCaption = makeLabel("", size: 13, color: .dim, align: .center)
        previewCaption.position = CGPoint(x: 712, y: 206)
        addChild(previewCaption)

        var help = [
            "P1 Arrows    P2 W A S D    P3 I J K L    P4 Numpad 8 4 5 6",
            "Game controllers drive players 1-4 in connection order",
            "Up/Down select   Left/Right change   Enter race   Esc pause",
        ]
        #if os(macOS)
        help[2] += "   Cmd+Return full screen"
        // The switch also happens from the View menu, the green button and Cmd+Return.
        let center = NotificationCenter.default
        fullScreenObservers = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification].map {
            center.addObserver(forName: $0, object: view.window, queue: .main) { [weak self] _ in self?.refresh() }
        }
        #endif
        for (i, line) in help.enumerated() {
            let l = makeLabel(line, size: 14, color: i == 0 ? .white : .dim, align: .center)
            l.position = CGPoint(x: 480, y: 120 - CGFloat(i) * 26)
            addChild(l)
        }
        refresh()
        coordinator.prewarmPreviews()
    }

    override func willMove(from view: SKView) {
        fullScreenObservers.forEach(NotificationCenter.default.removeObserver)
        fullScreenObservers = []
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

    private var skillIndex: Int { MenuScene.skillIndex(settings.aiSkill) }

    private var volumeText: String {
        let v = SoundSystem.shared.volume
        return v <= 0 ? "Off" : "\(Int((v * 100).rounded()))%"
    }

    private func refresh() {
        let lib = TrackLibrary.shared
        let def = lib.definitions[settings.trackIndex]
        var values: [Row: String] = [
            .track: "TRACK      < \(def.name) >",
            .laps: "LAPS       < \(settings.laps) >",
            .players: "PLAYERS    < \(settings.humanPlayers) >",
            .name: "P\(namePlayer + 1) NAME    < \(settings.playerName(for: namePlayer))\(selected == .name ? "_" : "") >",
            .opponents: "OPPONENTS  < \(settings.aiOpponents) >",
            .skill: "AI SKILL   < \(MenuScene.skillLevels[skillIndex].name) >",
            .sound: "SOUND      < \(volumeText) >",
            .start: "START RACE",
            .series: "CHAMPIONSHIP",
            .online: "ONLINE",
        ]
        #if os(macOS)
        values[.display] = "DISPLAY    < \(isFullScreen ? "Full screen" : "Window") >"
        values[.editor] = TrackStore.isCustom(def.id) ? "EDIT THIS TRACK" : "TRACK EDITOR"
        #endif
        for (row, label) in rowLabels {
            let isSel = row == selected
            label.text = (isSel ? "> " : "  ") + (values[row] ?? "")
            label.fontColor = isSel ? .accent : .white
        }
        showPreview(at: settings.trackIndex)
        let bridges = def.bridges.isEmpty ? "" : " - \(def.bridges.count) bridge\(def.bridges.count > 1 ? "s" : "")"
        previewCaption.text = "\(def.name) - \(def.theme.rawValue)\(bridges) - suggested \(def.defaultLaps) laps"
    }

    override func keyPressed(_ key: Key, isRepeat: Bool) {
        let rows = Row.allCases
        let idx = rows.firstIndex(of: selected)!
        switch key {
        case .up, .w:
            selected = rows[(idx - 1 + rows.count) % rows.count]
            SoundSystem.shared.play(.menuMove)
        case .down, .s, .tab:
            selected = rows[(idx + 1) % rows.count]
            SoundSystem.shared.play(.menuMove)
        case .left, .a:
            if isRepeat && selected.isToggle { return }
            change(by: -1)
            SoundSystem.shared.play(.menuMove)
        case .right, .d:
            if isRepeat && selected.isToggle { return }
            change(by: 1)
            SoundSystem.shared.play(.menuMove)
        case .enter, .space:
            if isRepeat { return }
            if selected == .name {
                selected = .opponents
                replacingName = true
                refresh()
                return
            }
            SoundSystem.shared.play(.menuSelect)
            coordinator.settings = settings
            if selected == .online {
                settings.save()
                return coordinator.showOnlineMenu()
            }
            if selected == .series {
                settings.save()
                return coordinator.showSeriesSetup()
            }
            #if os(macOS)
            if selected == .editor {
                // Custom tracks open for editing; with a built-in selected, start fresh.
                let def = TrackLibrary.shared.definitions[settings.trackIndex]
                return coordinator.showEditor(editing: TrackStore.isCustom(def.id) ? def : nil)
            }
            #endif
            coordinator.startRace()
            return
        default:
            return
        }
        replacingName = true
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
            settings.humanPlayers = clamp(settings.humanPlayers + delta, 0, 4)
            namePlayer = min(namePlayer, max(0, settings.humanPlayers - 1))
            let minimumOpponents = settings.humanPlayers == 0 ? 1 : 0
            settings.aiOpponents = clamp(settings.aiOpponents, minimumOpponents, GameInfo.maxCars - settings.humanPlayers)
        case .name:
            let count = max(1, settings.humanPlayers)
            namePlayer = (namePlayer + delta + count) % count
            replacingName = true
        case .opponents:
            let minimumOpponents = settings.humanPlayers == 0 ? 1 : 0
            settings.aiOpponents = clamp(settings.aiOpponents + delta, minimumOpponents, GameInfo.maxCars - settings.humanPlayers)
        case .skill:
            let i = clamp(skillIndex + delta, 0, MenuScene.skillLevels.count - 1)
            settings.aiSkill = MenuScene.skillLevels[i].value
        case .sound:
            let steps = SoundSystem.volumeSteps
            let current = steps.enumerated().min { abs($0.element - SoundSystem.shared.volume) < abs($1.element - SoundSystem.shared.volume) }?.offset ?? 0
            SoundSystem.shared.volume = steps[clamp(current + delta, 0, steps.count - 1)]
        #if os(macOS)
        case .display:
            // Only two choices, so either direction flips it. The label updates once the
            // window has finished switching.
            toggleFullScreen()
        #endif
        default:
            break
        }
        coordinator.settings = settings
    }

    #if os(macOS)
    override func handleTyping(_ event: NSEvent) -> Bool {
        guard selected == .name else { return false }
        switch event.keyCode {
        case 36, 76, 53, 48, 123, 124, 125, 126:
            return false
        case 51, 117:
            var name = settings.playerNames?.indices.contains(namePlayer) == true
                ? settings.playerNames![namePlayer] : settings.playerName(for: namePlayer)
            if !name.isEmpty { name.removeLast() }
            settings.setPlayerName(name, for: namePlayer)
        default:
            let typed = (event.characters ?? "").filter { $0.isLetter || $0.isNumber || " -_'.!".contains($0) }
            guard !typed.isEmpty else { return true }
            let current = replacingName ? "" : (settings.playerNames?[namePlayer] ?? "")
            settings.setPlayerName(current + typed, for: namePlayer)
        }
        replacingName = false
        coordinator.settings = settings
        settings.save()
        refresh()
        return true
    }
    #endif
}
