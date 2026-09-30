import SlicksCore
import SlicksNet
import SpriteKit
#if os(macOS)
import AppKit
#endif

/// Owns the SKView and switches between menu and race.
public final class GameCoordinator {
    public static let shared = GameCoordinator()

    private weak var view: SKView?
    public var settings = RaceSettings.load()
    private var textures: [String: SKTexture] = [:]

    public func start(in view: SKView) {
        self.view = view
        SoundSystem.shared.start()
        showMenu()
    }

    public func showMenu() {
        present(MenuScene(coordinator: self))
    }

    // MARK: Online

    /// The online game this machine is in, if any.
    var online: OnlineSession?

    /// Call when the app quits: says goodbye to other players and withdraws the Bonjour listing,
    /// so nobody is left looking at a game that's gone.
    public func shutdownOnline() {
        online?.closeForQuit()
    }

    var currentScene: SKScene? { view?.scene }

    /// Host/join screen. `message` explains why a previous game ended.
    func showOnlineMenu(message: String? = nil) {
        present(OnlineScene(coordinator: self, message: message))
    }

    func showLobby() {
        guard let online else { return showOnlineMenu() }
        present(LobbyScene(coordinator: self, session: online))
    }

    func hostOnline(name: String, localPlayers: Int, requireCode: Bool = true, relayServer: String?) {
        online = OnlineSession.host(coordinator: self, name: name, localPlayers: localPlayers,
                                    requireCode: requireCode, relayServer: relayServer)
        showLobby()
    }

    func joinOnline(_ target: NetClient.Target, label: String, secret: String, relayServer: String?,
                    name: String, localPlayers: Int) {
        online = OnlineSession.join(coordinator: self, target: target, label: label, secret: secret,
                                    relayServer: relayServer, name: name, localPlayers: localPlayers)
        showLobby()
    }

    public func startRace(persist: Bool = true) {
        if persist { settings.save() }
        present(localRace(settings, on: TrackLibrary.shared.track(at: settings.trackIndex), isTestDrive: false))
    }

    /// A race where every human is at this machine: local player p drives input slot p.
    private func localRace(_ s: RaceSettings, on track: Track, isTestDrive: Bool) -> RaceScene {
        let setup = s.raceSetup(track: track.definition, seed: RaceSetup.randomSeed())
        let controller = LocalRaceController(race: Race(setup: setup, track: track), localSlots: Array(0..<setup.inputSlotCount))
        return RaceScene(coordinator: self, controller: controller, mode: isTestDrive ? .testDrive : .local)
    }

    #if os(macOS)
    /// The open editor, kept alive while test driving so it comes back as it was left.
    private var editor: EditorScene?

    /// Opens the level editor on a track, or on a new one.
    public func showEditor(editing def: TrackDefinition? = nil) {
        let scene = EditorScene(coordinator: self, editing: def)
        editor = scene
        present(scene)
    }

    /// Leaves the editor for the menu, with `trackID` selected if given.
    func closeEditor(selecting trackID: String?) {
        editor = nil
        if let id = trackID, let i = TrackLibrary.shared.index(of: id) {
            settings.trackIndex = i
            settings.laps = TrackLibrary.shared.definitions[i].defaultLaps
        }
        showMenu()
    }

    /// Races the editor's current track, returning to the editor afterwards.
    func testDrive(_ def: TrackDefinition) {
        var d = def
        // A fixed id keeps test builds out of the texture cache entries of saved tracks.
        d.id = "editor-test"
        forgetTextures(for: d.id)
        raceTestTrack(Track(definition: d))
    }

    /// Starts, or restarts, a test drive on an editor track that's already built.
    func raceTestTrack(_ track: Track) {
        var s = settings
        s.humanPlayers = max(1, s.humanPlayers)
        s.aiOpponents = min(s.aiOpponents, GameInfo.maxCars - s.humanPlayers)
        s.laps = track.definition.defaultLaps
        present(localRace(s, on: track, isTestDrive: true))
    }

    func returnToEditor() {
        guard let editor else { return showMenu() }
        present(editor)
    }
    #endif

    /// Drops cached images of a track whose definition changed.
    func forgetTextures(for id: String) {
        textures = textures.filter { $0.key != id && !$0.key.hasPrefix(id + "#") }
        texturedDefinitions[id] = nil
    }

    /// Definition each cached track image was drawn from. A different track with the same id
    /// (an online host's custom track, an edited one) replaces the old images.
    private var texturedDefinitions: [String: TrackDefinition] = [:]

    private func checkTextureCache(_ track: Track) {
        let id = track.definition.id
        if let cached = texturedDefinitions[id], cached != track.definition { forgetTextures(for: id) }
        texturedDefinitions[id] = track.definition
    }

    /// Track with bridge decks baked in, for the menu preview.
    func previewTexture(for track: Track) -> SKTexture {
        checkTextureCache(track)
        let key = track.definition.id + "#preview"
        if let t = textures[key] { return t }
        let t = SKTexture(cgImage: TrackRenderer.makeCompositeImage(for: track))
        t.filteringMode = .linear
        textures[key] = t
        return t
    }

    func deckTexture(for track: Track, bridge: Bridge) -> SKTexture {
        checkTextureCache(track)
        let key = "\(track.definition.id)#deck\(bridge.centerSample)"
        if let t = textures[key] { return t }
        let t = SKTexture(cgImage: TrackRenderer.makeBridgeImage(for: track, bridge: bridge))
        t.filteringMode = .linear
        textures[key] = t
        return t
    }

    /// Ramps layer, or nil if the track has none.
    func rampTexture(for track: Track) -> SKTexture? {
        let key = track.definition.id + "#ramps"
        if let t = textures[key] { return t }
        guard let image = TrackRenderer.makeRampImage(for: track.definition) else { return nil }
        let t = SKTexture(cgImage: image)
        t.filteringMode = .linear
        textures[key] = t
        return t
    }

    /// Trees and buildings layer, or nil if the track has none.
    func objectTexture(for track: Track) -> SKTexture? {
        let key = track.definition.id + "#objects"
        if let t = textures[key] { return t }
        guard let image = TrackRenderer.makeObjectImage(for: track.definition) else { return nil }
        let t = SKTexture(cgImage: image)
        t.filteringMode = .linear
        textures[key] = t
        return t
    }

    /// Cached pixel-art texture for a track.
    func texture(for track: Track) -> SKTexture {
        checkTextureCache(track)
        if let t = textures[track.definition.id] { return t }
        let t = SKTexture(cgImage: TrackRenderer.makeImage(for: track))
        t.filteringMode = .nearest
        textures[track.definition.id] = t
        return t
    }

    func present(_ scene: SKScene) {
        Input.shared.releaseAll()
        view?.presentScene(scene, transition: .fade(withDuration: 0.2))
    }
}

/// Base scene: fixed logical size, letterboxed, with keyboard forwarding.
open class GameScene: SKScene {
    public override init() {
        super.init(size: GameInfo.sceneSize)
        scaleMode = .aspectFit
        backgroundColor = SKColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1)
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) { fatalError("not supported") }

    /// Called on key press. `isRepeat` is true for auto-repeat while held.
    open func keyPressed(_ key: Key, isRepeat: Bool) {}

    #if os(macOS)
    /// Scenes with a focused text field return true to take the key as typing.
    open func handleTyping(_ event: NSEvent) -> Bool { false }
    #endif

    #if os(macOS)
    open override func keyDown(with event: NSEvent) {
        // Leave Command shortcuts to the menu bar.
        if event.modifierFlags.contains(.command) { return super.keyDown(with: event) }
        // In full screen the pointer would sit over the track; hide it until the mouse moves.
        if isFullScreen { NSCursor.setHiddenUntilMouseMoves(true) }
        if handleTyping(event) { return }
        guard let key = Key(macKeyCode: event.keyCode) else { return }
        Input.shared.press(key)
        keyPressed(key, isRepeat: event.isARepeat)
    }

    open override func keyUp(with event: NSEvent) {
        guard let key = Key(macKeyCode: event.keyCode) else { return }
        Input.shared.release(key)
    }
    #endif

    func makeLabel(_ text: String, size: CGFloat, color: SKColor = .white,
                   align: SKLabelHorizontalAlignmentMode = .left) -> SKLabelNode {
        let l = SKLabelNode(fontNamed: "Menlo-Bold")
        l.text = text
        l.fontSize = size
        l.fontColor = color
        l.horizontalAlignmentMode = align
        l.verticalAlignmentMode = .center
        return l
    }
}

extension SKColor {
    static let accent = SKColor(red: 1.0, green: 0.82, blue: 0.2, alpha: 1)
    static let dim = SKColor(white: 0.62, alpha: 1)
}

func formatTime(_ t: Double) -> String {
    let m = Int(t) / 60
    let s = t - Double(m * 60)
    return m > 0 ? String(format: "%d:%05.2f", m, s) : String(format: "%.2f", s)
}
