#if DEBUG && os(macOS)
import AppKit
import Foundation
import ImageIO
import SlicksCore
import SlicksLink
import SlicksNet
import SpriteKit
import UniformTypeIdentifiers

/// Debug-only smoke test: set SLIDEWAYS_SNAPSHOT_DIR to have the app capture the menu,
/// run a 1-lap AI-only race, save frames along the way, then quit.
public enum DebugHarness {
    @MainActor
    public static func runIfRequested(view: SKView) {
        guard let dir = ProcessInfo.processInfo.environment["SLIDEWAYS_SNAPSHOT_DIR"] else { return }
        // Line-buffered, so logs survive the process being killed.
        setvbuf(stdout, nil, _IOLBF, 0)
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let track = Int(ProcessInfo.processInfo.environment["SLIDEWAYS_TRACK"] ?? "") ?? 0

        func snap(_ name: String) {
            guard let scene = view.scene, let cg = view.texture(from: scene)?.cgImage(),
                  let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL,
                                                             UTType.png.identifier as CFString, 1, nil) else {
                print("snapshot \(name) failed")
                return
            }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
            print("snapshot \(name) saved")
        }

        func after(_ t: Double, _ block: @escaping () -> Void) {
            Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in block() }
        }

        if ProcessInfo.processInfo.environment["SLIDEWAYS_SHARING_TEST"] != nil {
            let coordinator = GameCoordinator.shared
            let track = BuiltInTracks.all.first { $0.id == "cloverleaf-crossing" }!
            let file = out.appendingPathComponent("renamed-download.slideways-track")
            do {
                try TrackStore.exportData(track).write(to: file)
            } catch {
                print("sharing test: export failed: \(error)")
                NSApplication.shared.terminate(nil)
                return
            }
            after(0.5) { coordinator.showEditor(editing: track) }
            after(1) {
                (coordinator.currentScene as? EditorScene)?.debugClick("Open")
                snap("sharing-browser")
            }
            after(1.5) { NSApp.delegate?.application?(NSApp, open: [file]) }
            after(2) { snap("sharing-preview") }
            after(2.5) { (coordinator.currentScene as? EditorScene)?.debugClick("Import") }
            after(3.5) {
                snap("sharing-imported")
                print("sharing test: \(TrackStore.loadAll().count) saved track(s)")
                NSApplication.shared.terminate(nil)
            }
            return
        }
        if ProcessInfo.processInfo.environment["SLIDEWAYS_EDITOR_TEST"] != nil {
            return runEditorScript(view: view, snap: snap, after: after)
        }
        if let role = ProcessInfo.processInfo.environment["SLIDEWAYS_NET_TEST"] {
            return runOnlineScript(role: role, snap: snap, after: after)
        }

        after(1) { snap("menu") }
        after(1.5) {
            var s = RaceSettings()
            s.trackIndex = track
            s.laps = 1
            s.humanPlayers = 0
            s.aiOpponents = 8
            GameCoordinator.shared.settings = s
            GameCoordinator.shared.startRace(persist: false)
        }
        after(3) { snap("countdown") }
        for (i, t) in [7.0, 8.5, 10.0, 11.5].enumerated() {
            after(t) { snap("racing\(i + 1)") }
        }
        after(34) { snap("results") }
        after(35) { NSApplication.shared.terminate(nil) }
    }

    /// `SLIDEWAYS_AUTOPILOT`: local players are driven by the AI, so scripted races finish.
    static let autopilot = ProcessInfo.processInfo.environment["SLIDEWAYS_AUTOPILOT"] != nil

    /// Two instances race each other: `SLIDEWAYS_NET_TEST=host` in one and `=join` in the other
    /// (joins 127.0.0.1, or `SLIDEWAYS_NET_JOIN`). Snapshots the online menu, lobby, race and
    /// results on both, then quits. Pair with `SLIDEWAYS_AUTOPILOT` and `SLIDEWAYS_NET_LAG_MS`.
    @MainActor
    static func runOnlineScript(role: String, snap: @escaping (String) -> Void,
                                after: @escaping (Double, @escaping () -> Void) -> Void) {
        let coordinator = GameCoordinator.shared
        let scene = { coordinator.currentScene }
        let prefix = role == "host" ? "host" : "join"
        var shots: Set<String> = []
        func once(_ name: String) {
            guard shots.insert(name).inserted else { return }
            snap("\(prefix)-\(name)")
        }
        after(0.5) { coordinator.showOnlineMenu() }
        after(2.5) { once("1-online-menu") }
        let env = ProcessInfo.processInfo.environment
        let relay = env["SLIDEWAYS_RELAY"]
        // The host writes its join code here; the joiner reads it, like a friend reading it out.
        let codeFile = URL(fileURLWithPath: env["SLIDEWAYS_SNAPSHOT_DIR"] ?? "/tmp").appendingPathComponent("joincode.txt")
        let browser = HostBrowser()
        after(3) {
            if role == "host" {
                coordinator.hostOnline(name: "Hosty", localPlayers: 1, requireCode: env["SLIDEWAYS_NET_OPEN"] == nil, relayServer: relay)
                if let s = coordinator.online {
                    s.persistsSettings = false
                    var settings = s.settings
                    settings.trackIndex = Int(env["SLIDEWAYS_TRACK"] ?? "") ?? 1
                    settings.laps = 1
                    settings.aiOpponents = 3
                    s.settings = settings
                }
                return
            }
            if env["SLIDEWAYS_NET_JOIN"] == "lan" { browser.start() }
            func tryJoin(_ attempt: Int) {
                guard let code = try? String(contentsOf: codeFile, encoding: .utf8), code.count >= 4 else {
                    if attempt < 40 { after(0.25) { tryJoin(attempt + 1) } } else { print("online test: no join code from host") }
                    return
                }
                let c = RoomCode.normalize(code) ?? ""
                let room = String(c.prefix(4)), secret = c.count == 8 ? String(c.suffix(4)) : ""
                // Wrong code on purpose, to see the refusal.
                let used = env["SLIDEWAYS_NET_BADCODE"] != nil ? "ZZZZ" : secret
                print("online test: joining with code \(room)-\(used) via \(env["SLIDEWAYS_NET_JOIN"] ?? "address")")
                switch env["SLIDEWAYS_NET_JOIN"] ?? "127.0.0.1" {
                case "code":
                    coordinator.joinOnline(.room(room, nearby: []), label: "game \(room)", secret: used, relayServer: relay,
                                           name: "Joiny", localPlayers: 1)
                case "lan":
                    guard let found = browser.host(room: room) else {
                        if attempt < 40 { after(0.25) { tryJoin(attempt + 1) } } else { print("online test: game not listed") }
                        return
                    }
                    coordinator.joinOnline(.room(room, nearby: found.addresses), label: found.name, secret: used, relayServer: nil,
                                           name: "Joiny", localPlayers: 1)
                case let address:
                    coordinator.joinOnline(.address(address), label: address, secret: used, relayServer: nil,
                                           name: "Joiny", localPlayers: 1)
                }
            }
            tryJoin(0)
        }

        // Poll the flow and snapshot each stage as it's reached.
        var started = Date()
        var raceSeen = false
        var resultsAt: Date?
        var lobbyAgainAt: Date?
        var lastSceneName = ""
        var lastCode = ""
        var lastStatus: [String] = []
        if role == "host" { try? FileManager.default.removeItem(at: codeFile) }
        func poll() {
            after(0.25, poll)
            do {
                let session = coordinator.online
                if role == "host", let host = session?.netHost, host.joinCode != lastCode {
                    lastCode = host.joinCode
                    try? host.joinCode.write(to: codeFile, atomically: true, encoding: .utf8)
                    print("online test: join code \(host.joinCode)")
                }
                if role == "host", let lines = session?.internetStatus.map(\.text), lines != lastStatus {
                    lastStatus = lines
                    print("online test: internet status \(lines)")
                }
                let sceneName = scene().map { String(describing: type(of: $0)) } ?? "none"
                if sceneName != lastSceneName {
                    lastSceneName = sceneName
                    print("online test: now on \(sceneName), session \(session == nil ? "none" : "open"), status \(session?.status ?? "-")")
                }
                if scene() is LobbyScene {
                    let players = session?.lobby?.players.count ?? 0
                    if !raceSeen {
                        once(players >= 2 ? "2-lobby-full" : "2-lobby")
                        if role == "host", players >= 2, session?.lobby?.inRace == false, Date().timeIntervalSince(started) > 5 {
                            print("online test: starting race with \(session?.lobby?.players.map(\.name) ?? [])")
                            session?.startRace()
                        }
                    } else {
                        if lobbyAgainAt == nil { lobbyAgainAt = Date() }
                        if Date().timeIntervalSince(lobbyAgainAt!) > 1.5 {
                            once("6-back-in-lobby")
                            after(1) { NSApplication.shared.terminate(nil) }
                        }
                    }
                } else if let race = scene() as? RaceScene {
                    if !raceSeen { raceSeen = true; started = Date() }
                    let t = Date().timeIntervalSince(started)
                    if t > 2 { once("3-countdown") }
                    if t > 7 { once("4-racing") }
                    // SLIDEWAYS_NET_QUIT_AT: vanish mid-race to test the other side's handling.
                    if let quit = Double(ProcessInfo.processInfo.environment["SLIDEWAYS_NET_QUIT_AT"] ?? ""), t > quit {
                        print("online test: quitting mid-race")
                        exit(0)
                    }
                    if race.debugShowingResults {
                        if resultsAt == nil {
                            resultsAt = Date()
                            print("online test: results \(race.debugStandings)")
                        }
                        if Date().timeIntervalSince(resultsAt!) > 1.5 { once("5-results") }
                        if role == "host", Date().timeIntervalSince(resultsAt!) > 3 { session?.returnToLobby() }
                    }
                } else if scene() is OnlineScene, raceSeen || session == nil && Date().timeIntervalSince(started) > 8 {
                    once("7-online-menu-after")
                    print("online test: ended up back on the online menu")
                    after(1) { NSApplication.shared.terminate(nil) }
                }
            }
        }
        after(1, poll)
        after(120) {
            print("online test: timed out")
            NSApplication.shared.terminate(nil)
        }
    }

    /// Walks the level editor through each tool with synthetic pointer input.
    @MainActor
    static func runEditorScript(view: SKView, snap: @escaping (String) -> Void,
                                after: @escaping (Double, @escaping () -> Void) -> Void) {
        let coordinator = GameCoordinator.shared
        var editor: EditorScene? { view.scene as? EditorScene }
        func log(_ what: String) { print("editor test: \(what) -> \(editor?.debugSummary ?? "no editor")") }
        var t = 0.5
        func step(_ gap: Double = 1.2, _ block: @escaping () -> Void) {
            t += gap
            after(t, block)
        }

        step(0.5) { coordinator.showEditor(editing: nil) }
        step { snap("editor-1-blank"); log("blank") }
        step {
            guard let e = editor else { return }
            e.debugClick("Road")
            e.pointerMoved(to: e.toScene(Vec2(470, 470)))
            snap("editor-2-road-hover")
            e.debugDrag(from: Vec2(470, 470), to: Vec2(480, 380))
            log("added road point")
        }
        step { snap("editor-3-road-added") }
        step {
            // Mid-drag frame: the quick vector preview stands in for the raster.
            guard let e = editor else { return }
            let a = e.toScene(Vec2(480, 380))
            e.pointerDown(at: a)
            for k in 1...6 { e.pointerDragged(to: e.toScene(Vec2(480 + Double(k) * 20, 380 + Double(k) * 10))) }
            snap("editor-3b-mid-drag")
            e.pointerUp(at: e.toScene(Vec2(600, 440)))
            log("dragged point")
        }
        step {
            guard let e = editor else { return }
            e.debugClick("Patch")
            e.debugClick("Ice")
            e.debugClick("Yes")
            e.debugDrag(from: Vec2(830, 300), to: Vec2(880, 300))
            // A freshly drawn patch stays selected, so deselect before picking the next look.
            e.debugClick("Done")
            e.debugClick("Wall")
            e.debugClick("No")
            e.debugClick("Capsule")
            e.debugDrag(from: Vec2(300, 260), to: Vec2(420, 260))
            e.debugClick("Done")
            e.debugClick("Sand")
            e.debugClick("Rect")
            e.debugDrag(from: Vec2(20, 20), to: Vec2(140, 110))
            log("patches")
        }
        step { snap("editor-4-patches") }
        step {
            guard let e = editor else { return }
            e.debugClick("Select")
            e.select(.none)
            e.debugClick("Winter")
            e.debugClick("Undo")
            e.debugClick("Redo")
            e.debugClick("Off")
            log("winter, no barrier")
        }
        step { snap("editor-5-theme"); log("theme settled") }
        step {
            guard let e = editor else { return }
            e.debugClick("Open")
            snap("editor-6-confirm")
            e.debugClick("Discard")
            snap("editor-7-open")
            e.debugClick("Overpass")
            e.debugClick("Bridge")
            log("opened overpass copy")
        }
        step { snap("editor-8-bridge-tool") }
        step {
            guard let e = editor else { return }
            let p = e.toScene(Vec2(440, 300))
            e.pointerMoved(to: p)
            e.pointerDown(at: p)
            e.pointerUp(at: p)
            log("flipped bridge")
        }
        step(1.8) { snap("editor-9-bridge-flipped") }
        step {
            guard let e = editor else { return }
            e.debugClick("Save")
            log("saved")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: TrackStore.directory.path)) ?? []
            print("editor test: track files \(files)")
        }
        step { editor?.debugClick("Test >") }
        step(4) { snap("editor-10-test-drive") }
        step { coordinator.returnToEditor() }
        step { snap("editor-11-back"); log("back from test drive") }
        step {
            guard let e = editor else { return }
            e.debugClick("Select")
            let p = e.toScene(Vec2(440, 300))
            e.pointerMoved(to: p)
            e.pointerDown(at: p)
            e.pointerUp(at: p)
            log("selected bridge point")
        }
        step { snap("editor-12-bridge-inspector") }
        step {
            // Widen the far right sweeper by dragging its edge handle, then narrow the bridge's
            // lower road with the stepper.
            guard let e = editor else { return }
            let p = e.toScene(e.def.controlPoints[3])
            e.pointerMoved(to: p)
            e.pointerDown(at: p)
            e.pointerUp(at: p)
            guard let h = e.debugWidthHandle else { return print("editor test: no width handle") }
            let out = h + (h - e.def.controlPoints[3]).normalized * 30
            e.debugDrag(from: h, to: out)
            log("widened point 4")
            let q = e.toScene(e.def.controlPoints[15])
            e.pointerMoved(to: q)
            e.pointerDown(at: q)
            e.pointerUp(at: q)
            // Point 16 shares its spot with the bridge point; step it down 10 times.
            for _ in 0..<10 { e.debugClick("-") }
            log("narrowed a point")
        }
        step(0.6) {
            // Mid-drag of the edge handle, to see the quick preview follow.
            guard let e = editor else { return }
            let p = e.toScene(e.def.controlPoints[11])
            e.pointerDown(at: p)
            e.pointerUp(at: p)
            guard let h = e.debugWidthHandle else { return }
            e.pointerMoved(to: e.toScene(h))
            e.pointerDown(at: e.toScene(h))
            e.pointerDragged(to: e.toScene(h + (h - e.def.controlPoints[11]).normalized * 25))
            snap("editor-14-width-mid-drag")
            e.pointerUp(at: e.toScene(h + (h - e.def.controlPoints[11]).normalized * 25))
            log("widened point 12")
        }
        step(2) { snap("editor-15-widths"); log("widths settled") }
        step {
            guard let e = editor else { return }
            e.debugClick("Test >")
        }
        step(4) { snap("editor-16-width-test-drive") }
        step { coordinator.returnToEditor() }

        // Extended bridges: a straight crossing three legs 250 apart, bridged over the middle.
        step {
            guard let e = editor else { return }
            let pts: [(Double, Double)] = [(870, 420), (880, 530), (720, 540), (720, 70), (470, 70), (470, 540),
                                           (220, 540), (220, 70), (80, 70), (80, 300), (860, 300)]
            var d = TrackDefinition.blank(id: TrackStore.newID(), name: "Comb")
            d.controlPoints = pts.map { Vec2($0.0, $0.1) }
            if let x = d.crossings().min(by: { $0.point.distance(to: Vec2(470, 300)) < $1.point.distance(to: Vec2(470, 300)) }) {
                d.addBridge(at: x, over: Int(floor(x.passA)) == 9 ? x.passA : x.passB)
            }
            e.debugLoad(d)
            e.debugClick("Bridge")
            e.select(.point(d.bridges[0].controlPoint))
            log("comb loaded")
        }
        step(6) {
            // Debug builds rebuild the track slowly; give the deck ends time to settle.
            guard let e = editor else { return }
            snap("editor-17-comb-bridge")
            print("editor test: comb covered crossings \(e.debugCoveredCrossings)")
            // Clicking the next crossing along stretches the bridge over it.
            e.debugMapClick(Vec2(720, 300))
            print("editor test: stretch click says \"\(e.debugFlash)\"")
            log("stretched ahead")
        }
        step(6) {
            // Debug builds rebuild the track slowly; give the deck ends time to settle.
            guard let e = editor else { return }
            snap("editor-18-comb-stretched")
            print("editor test: comb covered crossings \(e.debugCoveredCrossings)")
            // Drag the start of the deck back over the left leg.
            guard let h = e.debugDeckHandle(.back) else { return print("editor test: no deck handle") }
            e.pointerMoved(to: e.toScene(h))
            e.pointerDown(at: e.toScene(h))
            e.pointerDragged(to: e.toScene(Vec2(h.x - 60, h.y)))
            e.pointerDragged(to: e.toScene(Vec2(140, h.y)))
            snap("editor-19-deck-drag")
            e.pointerUp(at: e.toScene(Vec2(140, h.y)))
            log("dragged deck start")
        }
        step(6) {
            // Debug builds rebuild the track slowly; give the deck ends time to settle.
            guard let e = editor else { return }
            print("editor test: comb covered crossings \(e.debugCoveredCrossings)")
            // The left crossing is under the deck now: clicking it explains instead of adding.
            e.debugMapClick(Vec2(220, 300))
            print("editor test: covered click says \"\(e.debugFlash)\"")
            e.debugMapClick(Vec2(470, 300))
            print("editor test: swap click says \"\(e.debugFlash)\"")
            snap("editor-20-comb-inspector")
            log("comb done")
        }
        step { editor?.debugClick("< Menu"); editor?.debugClick("Discard") }
        step { snap("editor-13-menu") }
        step(0.5) { NSApplication.shared.terminate(nil) }
    }
}
#endif
