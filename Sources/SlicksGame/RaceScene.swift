import SlicksCore
import SlicksNet
import SpriteKit

/// How a race was started, which decides what pausing, restarting and leaving do.
enum RaceMode {
    case local
    /// From the editor: restart re-races the same track, exit returns to the editor.
    case testDrive
    /// Can't pause; the host sends everyone back to the lobby afterwards.
    case online(OnlineSession)
}

/// The race itself: whole track on one screen, HUD strip on top.
final class RaceScene: GameScene {
    private static let hudHeight: CGFloat = 40

    /// Draw order. Cars on a bridge deck render above it, cars below render under it.
    private enum Z {
        static let ground: CGFloat = 0
        static let skids: CGFloat = 1
        static let carShadow: CGFloat = 2
        static let car: CGFloat = 3
        static let deck: CGFloat = 5
        static let deckSkids: CGFloat = 5.5
        static let deckCarShadow: CGFloat = 6
        static let deckCar: CGFloat = 7
        static let tags: CGFloat = 8
        static let sparks: CGFloat = 9
    }

    private unowned let coordinator: GameCoordinator
    private let controller: RaceController
    private let mode: RaceMode
    private let track: Track
    private var race: Race { controller.race }

    private let world = SKNode()
    private let skids = SkidMarks()
    private let deckSkids = SkidMarks()
    private var carNodes: [SKSpriteNode] = []
    private var shadowNodes: [SKSpriteNode] = []
    private var frontTires: [[SKSpriteNode]] = []
    /// Smoothed visual steering angle per car, in radians.
    private var steerAngles: [CGFloat] = []
    private var playerTags: [Int: SKLabelNode] = [:]
    private var lastWheels: [Int: (CGPoint, CGPoint)] = [:]

    private var hudEntries: [(swatch: SKSpriteNode, label: SKLabelNode)] = []
    private var countdownLabel: SKLabelNode!
    private var overlay: SKNode?
    private var showingResults = false
    private var isPausedByPlayer = false

    private var lastUpdate: TimeInterval?
    private let audio: RaceAudio

    private var isTestDrive: Bool {
        if case .testDrive = mode { return true }
        return false
    }

    private var online: OnlineSession? {
        if case let .online(session) = mode { return session }
        return nil
    }

    /// - Parameter controller: steps the race; its track is what gets drawn.
    init(coordinator: GameCoordinator, controller: RaceController, mode: RaceMode) {
        self.coordinator = coordinator
        self.controller = controller
        self.mode = mode
        track = controller.race.track
        let isOnline: Bool
        if case .online = mode { isOnline = true } else { isOnline = false }
        audio = RaceAudio(race: controller.race, localSlots: isOnline ? Set(controller.localSlots) : nil)
        super.init()
    }

    override func willMove(from view: SKView) {
        SoundSystem.shared.setCars([])
    }

    override func didMove(to view: SKView) {
        addChild(world)

        let ground = SKSpriteNode(texture: coordinator.texture(for: track))
        ground.anchorPoint = .zero
        ground.size = CGSize(width: track.width, height: track.height)
        ground.zPosition = 0
        world.addChild(ground)

        let worldSize = CGSize(width: track.width, height: track.height)
        skids.configure(worldSize: worldSize)
        deckSkids.configure(worldSize: worldSize)
        skids.zPosition = Z.skids
        world.addChild(skids)

        for bridge in track.bridges {
            let rect = TrackRenderer.deckRect(bridge)
            let deck = SKSpriteNode(texture: coordinator.deckTexture(for: track, bridge: bridge), size: rect.size)
            deck.anchorPoint = .zero
            deck.position = rect.origin
            deck.zPosition = Z.deck
            world.addChild(deck)
        }
        deckSkids.zPosition = Z.deckSkids
        world.addChild(deckSkids)

        let spriteSize = CarArt.spriteSize()
        for car in race.cars {
            let shadow = SKSpriteNode(texture: CarArt.texture(colorIndex: car.colorIndex), size: spriteSize)
            shadow.color = .black
            shadow.colorBlendFactor = 1
            shadow.alpha = 0.35
            shadow.zPosition = Z.carShadow
            world.addChild(shadow)
            shadowNodes.append(shadow)

            let node = SKSpriteNode(texture: CarArt.texture(colorIndex: car.colorIndex), size: spriteSize)
            node.zPosition = Z.car
            world.addChild(node)
            carNodes.append(node)

            // Steerable front tires, on both the kart and its shadow.
            var tires: [SKSpriteNode] = []
            for parent in [node, shadow] {
                for offset in CarArt.frontTireOffsets {
                    let tire = SKSpriteNode(texture: CarArt.frontTireTexture(), size: CarArt.frontTireSize)
                    tire.position = offset
                    tire.zPosition = -0.1
                    if parent === shadow {
                        tire.color = .black
                        tire.colorBlendFactor = 1
                    }
                    parent.addChild(tire)
                    tires.append(tire)
                }
            }
            frontTires.append(tires)

            if car.playerIndex != nil {
                let tag = makeLabel(shortName(car, length: 8), size: 11, color: CarArt.color(car.colorIndex), align: .center)
                tag.zPosition = Z.tags
                world.addChild(tag)
                playerTags[car.id] = tag
            }
        }

        buildHUD()

        countdownLabel = makeLabel("", size: 84, color: .accent, align: .center)
        countdownLabel.position = CGPoint(x: 480, y: 300)
        countdownLabel.zPosition = 20
        addChild(countdownLabel)

        syncCars()
    }

    // MARK: Loop

    override func update(_ currentTime: TimeInterval) {
        defer { lastUpdate = currentTime }
        guard let last = lastUpdate else { return }
        let frameDt = min(currentTime - last, 0.1)

        var localInputs = controller.localSlots.indices.map { Input.shared.carInput(forPlayer: $0) }
        #if DEBUG && os(macOS)
        if DebugHarness.autopilot { localInputs = autopilotInputs(frameDt) }
        #endif
        var impacts: [ImpactEvent] = []
        // Online races can't pause: the host keeps running and clients must keep up.
        if !isPausedByPlayer {
            impacts = controller.advance(frameDt: frameDt, localInputs: localInputs)
            for impact in impacts { spawnSparks(impact) }
        }
        if let client = controller as? ClientRaceController, let error = client.error {
            online?.fail(error)
            return
        }

        let sound = audio.update(race: race, impacts: impacts, humanInputs: controller.slotInputs,
                                 paused: isPausedByPlayer, dt: frameDt)
        SoundSystem.shared.setCars(sound.cars)
        for effect in sound.effects { SoundSystem.shared.play(effect) }

        syncCars()
        updateSkids()
        updateHUD()
        updateCountdown()

        if controller.isFinished && !showingResults {
            showResults()
        }
    }

    #if DEBUG && os(macOS)
    private var autopilots: [Int: AIDriver] = [:]

    /// The AI drives the local players (debug harness only).
    private func autopilotInputs(_ dt: Double) -> [CarInput] {
        controller.localSlots.map { slot in
            guard race.phase == .racing, let car = race.cars.first(where: { $0.playerIndex == slot }) else { return .none }
            var bot = autopilots[slot] ?? AIDriver(skill: 0.7, lane: 0)
            let input = bot.input(for: car, track: track, dt: dt, elapsed: race.time)
            autopilots[slot] = bot
            return input
        }
    }

    var debugShowingResults: Bool { showingResults }
    var debugStandings: [String] { race.standings.map(\.name) }
    #endif

    /// Where to draw a car: the simulated pose plus any correction still being eased out.
    private func drawnPose(_ car: Car) -> (position: Vec2, heading: Double) {
        let offset = controller.displayOffset(carID: car.id)
        return (car.position + offset.position, car.heading + offset.heading)
    }

    private func shortName(_ car: Car, length: Int = 6) -> String {
        if car.isAI || online != nil { return String(car.name.prefix(length)) }
        return "P\((car.playerIndex ?? 0) + 1)"
    }

    private func syncCars() {
        for car in race.cars {
            let pose = drawnPose(car)
            let p = CGPoint(x: pose.position.x, y: pose.position.y)
            let node = carNodes[car.id]
            node.position = p
            node.zRotation = pose.heading
            let shadow = shadowNodes[car.id]
            shadow.position = CGPoint(x: p.x + 2, y: p.y - 2)
            shadow.zRotation = pose.heading
            let onDeck = car.level > 0
            node.zPosition = onDeck ? Z.deckCar : Z.car
            shadow.zPosition = onDeck ? Z.deckCarShadow : Z.carShadow

            // Ease the wheels toward the steering input so digital keys don't snap them.
            if steerAngles.count <= car.id { steerAngles.append(0) }
            let target = CGFloat(clamp(car.lastInput.steer, -1, 1)) * 0.5
            steerAngles[car.id] += (target - steerAngles[car.id]) * 0.35
            for tire in frontTires[car.id] { tire.zRotation = steerAngles[car.id] }
            if let tag = playerTags[car.id] {
                tag.position = CGPoint(x: p.x, y: p.y + 16)
                // Show "P1" (or the name online) until shortly after the start, and whenever the car is nearly stopped.
                let visible = race.time < 3 || car.speed < 20
                tag.alpha = visible ? 1 : max(0, tag.alpha - 0.05)
            }
        }
    }

    private func updateSkids() {
        guard race.phase == .racing || race.phase == .finished else { return }
        for car in race.cars {
            let pose = drawnPose(car)
            let fwd = Vec2(angle: pose.heading), left = fwd.perp
            // Rear tire contact patches (see CarArt geometry).
            let rearL = pose.position - fwd * 6.9 + left * 3.8
            let rearR = pose.position - fwd * 6.9 - left * 3.8
            let a = CGPoint(x: rearL.x, y: rearL.y), b = CGPoint(x: rearR.x, y: rearR.y)
            let sliding = car.slip > 22 || (car.isBraking && car.speed > 70) || car.isWheelspinning
            let color = SkidMarks.color(for: car.surface, theme: track.definition.theme)
            if sliding, let color, let prev = lastWheels[car.id] {
                let moved = hypot(a.x - prev.0.x, a.y - prev.0.y)
                if moved >= 2.5 {
                    let layer = car.level > 0 ? deckSkids : skids
                    layer.addSegment(from: prev.0, to: a, color: color)
                    layer.addSegment(from: prev.1, to: b, color: color)
                    lastWheels[car.id] = (a, b)
                }
            } else {
                lastWheels[car.id] = sliding ? (a, b) : nil
            }
        }
        skids.tick()
        deckSkids.tick()
    }

    private func spawnSparks(_ impact: ImpactEvent) {
        let count = min(8, Int(impact.strength / 25) + 2)
        for _ in 0..<count {
            let s = SKSpriteNode(color: impact.isCarToCar ? .white : .accent, size: CGSize(width: 2, height: 2))
            s.position = CGPoint(x: impact.position.x, y: impact.position.y)
            s.zPosition = Z.sparks
            world.addChild(s)
            let angle = Double.random(in: 0..<(2 * .pi))
            let dist = CGFloat.random(in: 6...18)
            s.run(.sequence([
                .group([.moveBy(x: cos(angle) * dist, y: sin(angle) * dist, duration: 0.25), .fadeOut(withDuration: 0.25)]),
                .removeFromParent(),
            ]))
        }
    }

    // MARK: HUD

    private func buildHUD() {
        let bar = SKSpriteNode(color: SKColor(white: 0.04, alpha: 1), size: CGSize(width: 960, height: RaceScene.hudHeight))
        bar.anchorPoint = .zero
        bar.position = CGPoint(x: 0, y: CGFloat(track.height))
        bar.zPosition = 10
        addChild(bar)

        let slots = race.cars.count
        let slotWidth = 960 / CGFloat(max(slots, 1))
        for i in 0..<slots {
            let x = CGFloat(i) * slotWidth + 8
            let y = CGFloat(track.height) + RaceScene.hudHeight / 2
            let swatch = SKSpriteNode(color: .white, size: CGSize(width: 10, height: 10))
            swatch.position = CGPoint(x: x + 5, y: y)
            swatch.zPosition = 11
            addChild(swatch)
            let label = makeLabel("", size: slots > 6 ? 11 : 13)
            label.position = CGPoint(x: x + 14, y: y)
            label.zPosition = 11
            addChild(label)
            hudEntries.append((swatch, label))
        }
    }

    private func updateHUD() {
        for (pos, car) in race.standings.enumerated() where pos < hudEntries.count {
            let entry = hudEntries[pos]
            entry.swatch.color = CarArt.color(car.colorIndex)
            let status = car.isFinished ? "FIN" : "L\(race.currentLap(of: car))/\(race.laps)"
            let text = "\(pos + 1) \(shortName(car)) \(status)"
            if entry.label.text != text { entry.label.text = text }
            entry.label.fontColor = car.isAI ? .dim : .white
        }
    }

    private func updateCountdown() {
        let t = race.time
        if t < 0 {
            countdownLabel.text = "\(Int(ceil(-t)))"
            countdownLabel.alpha = 1
        } else if t < 0.8 {
            countdownLabel.text = "GO!"
            countdownLabel.alpha = 1
        } else {
            countdownLabel.alpha = 0
        }
    }

    // MARK: Overlays

    private func makePanel(height: CGFloat) -> SKNode {
        let node = SKNode()
        node.zPosition = 30
        let bg = SKShapeNode(rect: CGRect(x: -300, y: -height / 2, width: 600, height: height), cornerRadius: 10)
        bg.fillColor = SKColor(white: 0, alpha: 0.82)
        bg.strokeColor = SKColor(white: 1, alpha: 0.25)
        node.addChild(bg)
        node.position = CGPoint(x: 480, y: 300)
        return node
    }

    private func closeOverlay() {
        isPausedByPlayer = false
        overlay?.removeFromParent()
        overlay = nil
    }

    private func togglePause() {
        if overlay != nil { return closeOverlay() }
        let panel = makePanel(height: 170)
        let title: SKLabelNode
        let help: SKLabelNode
        if let online {
            // The race keeps going underneath: nobody else is paused.
            title = makeLabel("RACE IN PROGRESS", size: 30, color: .accent, align: .center)
            let quit = online.isHost ? "Q end the race for everyone" : "Q leave the game"
            help = makeLabel("Esc/Enter keep racing   \(quit)", size: 15, color: .white, align: .center)
        } else {
            isPausedByPlayer = true
            title = makeLabel("PAUSED", size: 36, color: .accent, align: .center)
            let quit = isTestDrive ? "Q back to editor" : "Q quit to menu"
            help = makeLabel("Esc/Enter resume   R restart   \(quit)", size: 15, color: .white, align: .center)
        }
        title.position = CGPoint(x: 0, y: 40)
        panel.addChild(title)
        help.position = CGPoint(x: 0, y: -25)
        panel.addChild(help)
        addChild(panel)
        overlay = panel
    }

    private func showResults() {
        showingResults = true
        overlay?.removeFromParent()
        let standings = race.standings
        let rowHeight: CGFloat = 30
        let height = CGFloat(standings.count) * rowHeight + 150
        let panel = makePanel(height: height)
        let top = height / 2

        let title = makeLabel("RESULTS - \(track.definition.name.uppercased())", size: 24, color: .accent, align: .center)
        title.position = CGPoint(x: 0, y: top - 34)
        panel.addChild(title)

        func columns(_ pos: String, _ name: String, _ time: String, _ best: String) -> String {
            func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
                let p = String(repeating: " ", count: max(0, w - s.count))
                return right ? p + s : s + p
            }
            return pad(pos, 4) + pad(name, 12) + pad(time, 10, right: true) + pad(best, 11, right: true)
        }

        let header = makeLabel(columns("POS", "DRIVER", "TIME", "BEST LAP"), size: 15, color: .dim)
        header.position = CGPoint(x: -250, y: top - 72)
        panel.addChild(header)

        let leader = standings.first
        for (i, car) in standings.enumerated() {
            let y = top - 104 - CGFloat(i) * rowHeight
            let swatch = SKSpriteNode(color: CarArt.color(car.colorIndex), size: CGSize(width: 12, height: 12))
            swatch.position = CGPoint(x: -266, y: y)
            panel.addChild(swatch)

            let time: String
            if let t = car.finishTime {
                time = formatTime(t)
            } else if let leader, leader.lapsCompleted > car.lapsCompleted {
                let down = leader.lapsCompleted - car.lapsCompleted
                time = "+\(down) lap\(down > 1 ? "s" : "")"
            } else {
                time = "DNF"
            }
            let best = car.bestLap.map(formatTime) ?? "-"
            let row = makeLabel(columns("\(i + 1).", car.name, time, best), size: 15, color: car.isAI ? .white : .accent)
            row.position = CGPoint(x: -250, y: y)
            panel.addChild(row)
        }

        let helpText: String
        if let online {
            helpText = online.isHost ? "Enter back to the lobby   Esc end the game" : "Waiting for the host...   Esc leave the game"
        } else {
            helpText = "Enter race again   Esc \(isTestDrive ? "editor" : "menu")"
        }
        let help = makeLabel(helpText, size: 14, color: .dim, align: .center)
        help.position = CGPoint(x: 0, y: -top + 26)
        panel.addChild(help)
        addChild(panel)
        overlay = panel
    }

    // MARK: Keys

    private func restart() {
        if let online {
            // Online, "again" means back to the lobby, and only the host decides that.
            if online.isHost { online.returnToLobby() }
            return
        }
        #if os(macOS)
        if isTestDrive { return coordinator.raceTestTrack(track) }
        #endif
        coordinator.startRace()
    }

    private func exit() {
        if let online {
            // The host leaving mid-race sends everyone to the lobby; afterwards it ends the game.
            if online.isHost && !showingResults { return online.returnToLobby() }
            return online.leave()
        }
        #if os(macOS)
        if isTestDrive { return coordinator.returnToEditor() }
        #endif
        coordinator.showMenu()
    }

    override func keyPressed(_ key: Key, isRepeat: Bool) {
        guard !isRepeat else { return }
        if showingResults {
            switch key {
            case .enter, .space: restart()
            case .escape, .q: exit()
            default: break
            }
            return
        }
        if overlay != nil {
            switch key {
            case .escape, .enter, .p: closeOverlay()
            case .r where online == nil: restart()
            case .q: exit()
            default: break
            }
            return
        }
        if key == .escape || key == .p {
            togglePause()
        }
    }
}
