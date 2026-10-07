import SlicksCore
import SlicksNet
import SpriteKit

/// How a race was started, which decides what pausing, restarting and leaving do.
enum RaceMode {
    case local
    /// From the editor: restart re-races the same track, exit returns to the editor.
    case testDrive
    /// A championship round: results score points, then the standings come up.
    case series
    /// Can't pause; the host sends everyone back to the lobby afterwards.
    case online(OnlineSession)
}

/// The race itself: whole track on one screen, HUD strip on top.
final class RaceScene: GameScene {
    private static let hudHeight: CGFloat = 40

    /// Draw order. Cars on a bridge deck render above it, cars below render under it.
    private enum Z {
        static let ground: CGFloat = 0
        /// Rubber is on the road itself: spilled sand covers it.
        static let rubber: CGFloat = 0.4
        static let looseSand: CGFloat = 0.5
        /// Ramps stand on the ground, over any sand spilled around them.
        static let ramps: CGFloat = 0.6
        static let skids: CGFloat = 1
        static let carShadow: CGFloat = 2
        static let car: CGFloat = 3
        static let deck: CGFloat = 5
        static let deckSkids: CGFloat = 5.5
        static let deckCarShadow: CGFloat = 6
        static let deckCar: CGFloat = 7
        static let splash: CGFloat = 7.2
        /// Cars in the air fly over bridge decks too.
        static let jumpingCar: CGFloat = 7.3
        /// Trees and buildings stand above everything on the ground: cars pass under canopies.
        static let objects: CGFloat = 7.5
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
    private var looseSandLayer: LooseSandLayer?
    private var rubberLayer: RubberLayer?
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

    private var isSeries: Bool {
        if case .series = mode { return true }
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

        if race.rubber != nil {
            let layer = RubberLayer(track: track)
            layer.zPosition = Z.rubber
            world.addChild(layer)
            rubberLayer = layer
        }

        if race.looseSand != nil {
            let layer = LooseSandLayer(width: track.width, height: track.height, theme: track.definition.theme)
            layer.zPosition = Z.looseSand
            world.addChild(layer)
            looseSandLayer = layer
        }

        let worldSize = CGSize(width: track.width, height: track.height)
        skids.configure(worldSize: worldSize)
        deckSkids.configure(worldSize: worldSize)
        skids.zPosition = Z.skids
        world.addChild(skids)

        if let texture = coordinator.rampTexture(for: track) {
            let ramps = SKSpriteNode(texture: texture, size: worldSize)
            ramps.anchorPoint = .zero
            ramps.zPosition = Z.ramps
            world.addChild(ramps)
        }

        for bridge in track.bridges {
            let rect = TrackRenderer.deckRect(bridge)
            let deck = SKSpriteNode(texture: coordinator.deckTexture(for: track, bridge: bridge), size: rect.size)
            deck.anchorPoint = .zero
            deck.position = rect.origin
            deck.zPosition = Z.deck
            world.addChild(deck)
        }
        if let texture = coordinator.rampTexture(for: track, onDeck: true) {
            let ramps = SKSpriteNode(texture: texture, size: worldSize)
            ramps.anchorPoint = .zero
            ramps.zPosition = Z.deck + 0.1
            world.addChild(ramps)
        }
        deckSkids.zPosition = Z.deckSkids
        world.addChild(deckSkids)

        if let texture = coordinator.objectTexture(for: track) {
            let objects = SKSpriteNode(texture: texture, size: worldSize)
            objects.anchorPoint = .zero
            objects.zPosition = Z.objects
            world.addChild(objects)
        }

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
        if let rubber = race.rubber { rubberLayer?.update(from: rubber) }
        if let sand = race.looseSand { looseSandLayer?.update(from: sand) }
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
            // Height reads as a slightly bigger kart with its shadow left further behind.
            let lift = CGFloat(car.height)
            node.setScale(1 + lift * 0.012)
            let reach = 2 + lift * 0.7
            shadow.position = CGPoint(x: p.x + reach, y: p.y - reach)
            shadow.alpha = 0.35 * max(0.45, 1 - lift / 40)
            shadow.zRotation = pose.heading
            let onDeck = car.level > 0
            node.zPosition = car.isAboveObstacles ? Z.jumpingCar : onDeck ? Z.deckCar : Z.car
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
            let sliding = Rubber.isMarking(car)
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
            if car.surface == .water, !car.isAirborne, car.speed > 40, Double.random(in: 0..<1) < car.speed / 500 {
                spawnSplash(at: Bool.random() ? rearL : rearR, car: car)
            }
            if !isPausedByPlayer, car.slipstream > 0.1, Double.random(in: 0..<1) < min(0.9, car.slipstream * 0.8) {
                spawnDraftStreak(car: car, pose: pose)
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

    /// Spray thrown up behind and to the side of a wheel driving through water.
    private func spawnSplash(at p: Vec2, car: Car) {
        let s = SKSpriteNode(color: SKColor(red: 0.8, green: 0.9, blue: 1, alpha: 1), size: CGSize(width: 2, height: 2))
        s.position = CGPoint(x: p.x, y: p.y)
        s.zPosition = Z.splash
        s.alpha = 0.85
        world.addChild(s)
        let back = -car.velocity.normalized
        let side = car.left * Double.random(in: -1...1)
        let d = (back * 0.6 + side).normalized * Double.random(in: 5...12)
        s.run(.sequence([
            .group([.moveBy(x: d.x, y: d.y, duration: 0.35), .fadeOut(withDuration: 0.35), .scale(to: 1.8, duration: 0.35)]),
            .removeFromParent(),
        ]))
    }

    /// Air peeling off a drafting car's rear spoiler and trailing away behind it.
    private func spawnDraftStreak(car: Car, pose: (position: Vec2, heading: Double)) {
        let fwd = Vec2(angle: pose.heading), left = fwd.perp
        let side = Bool.random() ? 1.0 : -1.0
        let half = car.spec.width / 2
        let p = pose.position - fwd * (car.spec.length / 2 - 1) + left * (side * (half - Double.random(in: 0...2.5)))
        let strength = CGFloat(min(car.slipstream, 1))
        let s = SKSpriteNode(color: .white, size: CGSize(width: CGFloat.random(in: 7...12), height: 1))
        // Anchored at its front end so it stretches back from the spoiler.
        s.anchorPoint = CGPoint(x: 1, y: 0.5)
        s.xScale = 0.2
        s.position = CGPoint(x: p.x, y: p.y)
        s.zRotation = pose.heading
        s.zPosition = carNodes[car.id].zPosition - 0.05
        s.alpha = 0.35 + 0.4 * strength
        world.addChild(s)
        let duration = 0.3
        // Keep most of the car's pace so the streak peels away behind it rather than vanishing at once.
        let d = car.velocity * (duration * 0.8) - fwd * car.spec.length
        s.run(.sequence([
            .group([.moveBy(x: d.x, y: d.y, duration: duration), .scaleX(to: 1, duration: duration * 0.5),
                    .fadeOut(withDuration: duration)]),
            .removeFromParent(),
        ]))
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
            let quit = isTestDrive ? "Q back to editor" : isSeries ? "Q quit series" : "Q quit to menu"
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
        if isSeries { coordinator.recordSeriesRound(finishingOrder: standings.map(\.id)) }
        let onlineRound = online?.raceRound
        if let online, online.isHost, onlineRound != nil { online.recordSeriesRound(finishingOrder: standings.map(\.id)) }
        let showsPoints = isSeries || onlineRound != nil
        let rowHeight: CGFloat = 30
        let height = CGFloat(standings.count) * rowHeight + 150
        let panel = makePanel(height: height)
        let top = height / 2

        var titleText = "RESULTS - \(track.definition.name.uppercased())"
        if isSeries, let series = coordinator.series {
            titleText = "ROUND \(series.roundsCompleted)/\(series.trackIDs.count) - \(track.definition.name.uppercased())"
        } else if let onlineRound {
            titleText = "ROUND \(onlineRound.round)/\(onlineRound.of) - \(track.definition.name.uppercased())"
        }
        let title = makeLabel(titleText, size: 24, color: .accent, align: .center)
        title.position = CGPoint(x: 0, y: top - 34)
        panel.addChild(title)

        func columns(_ pos: String, _ name: String, _ time: String, _ best: String, _ points: String = "") -> String {
            func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
                let p = String(repeating: " ", count: max(0, w - s.count))
                return right ? p + s : s + p
            }
            return pad(pos, 4) + pad(name, 12) + pad(time, 10, right: true) + pad(best, 11, right: true)
                + (showsPoints ? pad(points, 6, right: true) : "")
        }

        let header = makeLabel(columns("POS", "DRIVER", "TIME", "BEST LAP", "PTS"), size: 15, color: .dim)
        header.position = CGPoint(x: showsPoints ? -272 : -250, y: top - 72)
        panel.addChild(header)

        let leader = standings.first
        for (i, car) in standings.enumerated() {
            let y = top - 104 - CGFloat(i) * rowHeight
            let swatch = SKSpriteNode(color: CarArt.color(car.colorIndex), size: CGSize(width: 12, height: 12))
            swatch.position = CGPoint(x: showsPoints ? -288 : -266, y: y)
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
            let points = Series.points(forPlace: i)
            let row = makeLabel(columns("\(i + 1).", car.name, time, best, points > 0 ? "+\(points)" : "-"),
                                size: 15, color: car.isAI ? .white : .accent)
            row.position = CGPoint(x: showsPoints ? -272 : -250, y: y)
            panel.addChild(row)
        }

        let helpText: String
        if let online {
            let back = onlineRound != nil ? "Enter standings" : "Enter back to the lobby"
            helpText = online.isHost ? "\(back)   Esc end the game" : "Waiting for the host...   Esc leave the game"
        } else if isSeries {
            helpText = "Enter series standings"
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
        if isSeries {
            // Once scored, the round is over: carry on to the standings.
            return showingResults ? coordinator.showSeriesStandings() : coordinator.startSeriesRound()
        }
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
        if isSeries {
            return showingResults ? coordinator.showSeriesStandings() : coordinator.endSeries()
        }
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
