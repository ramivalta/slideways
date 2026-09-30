import Foundation
import SlicksCore
import SlicksLink
import SlicksNet
import SpriteKit
#if os(macOS)
import AppKit
#endif

/// Host a game or join one. Games on the local network are listed; any game can be joined
/// with its code (through the relay server when it's elsewhere) or by the host's address.
final class OnlineScene: GameScene {
    private enum Row: Equatable {
        case name, players, host, found(Int), code, address, server, back

        var isTextField: Bool { self == .name || self == .code || self == .address || self == .server }
    }

    enum Prefs {
        static let name = "online.name"
        static let players = "online.localPlayers"
        static let address = "online.address"
        static let server = "online.server"

        /// Relay server: the player's setting, else `SLIDEWAYS_RELAY`, else none.
        static var relayServer: String? {
            let saved = UserDefaults.standard.string(forKey: server) ?? ProcessInfo.processInfo.environment["SLIDEWAYS_RELAY"] ?? ""
            return saved.trimmingCharacters(in: .whitespaces).isEmpty ? nil : saved
        }
    }

    private unowned let coordinator: GameCoordinator
    private let browser = HostBrowser()
    private var message: String?
    private var playerName: String
    private var localPlayers: Int
    private var code = ""
    private var address: String
    private var server: String
    private var selected = Row.host
    private var dynamic: [SKNode] = []
    static let maxListed = 3

    init(coordinator: GameCoordinator, message: String?) {
        self.coordinator = coordinator
        self.message = message
        let d = UserDefaults.standard
        playerName = d.string(forKey: Prefs.name) ?? OnlineScene.defaultName
        localPlayers = clamp(d.integer(forKey: Prefs.players), 1, 4)
        address = d.string(forKey: Prefs.address) ?? ""
        server = Prefs.relayServer ?? ""
        super.init()
    }

    private static var defaultName: String {
        #if os(macOS)
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        if !first.isEmpty { return String(first.prefix(NetProtocol.maxNameLength)) }
        #endif
        return "Player"
    }

    override func didMove(to view: SKView) {
        let title = makeLabel("ONLINE", size: 44, color: .accent, align: .center)
        title.position = CGPoint(x: 480, y: 584)
        addChild(title)
        let subtitle = makeLabel("join nearby games, or any game with its code", size: 14, color: .dim, align: .center)
        subtitle.position = CGPoint(x: 480, y: 548)
        addChild(subtitle)
        let help = makeLabel("Up/Down select   Left/Right change   type to edit   Enter choose   Esc back", size: 14, color: .dim, align: .center)
        help.position = CGPoint(x: 480, y: 30)
        addChild(help)

        browser.onChange = { [weak self] in self?.refresh() }
        browser.start()
        refresh()
    }

    override func willMove(from view: SKView) {
        browser.stop()
        save()
    }

    private var listed: [HostBrowser.Found] { Array(browser.hosts.prefix(Self.maxListed)) }

    private var rows: [Row] {
        [.name, .players, .host] + listed.indices.map { .found($0) } + [.code, .address, .server, .back]
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(playerName, forKey: Prefs.name)
        d.set(localPlayers, forKey: Prefs.players)
        d.set(address, forKey: Prefs.address)
        d.set(server.trimmingCharacters(in: .whitespaces), forKey: Prefs.server)
    }

    func refresh() {
        for n in dynamic { n.removeFromParent() }
        dynamic.removeAll()
        if !rows.contains(selected) { selected = .host }

        func add(_ text: String, x: CGFloat = 80, y: CGFloat, size: CGFloat = 19, color: SKColor = .white,
                 align: SKLabelHorizontalAlignmentMode = .left) {
            let l = makeLabel(text, size: size, color: color, align: align)
            l.position = CGPoint(x: x, y: y)
            addChild(l)
            dynamic.append(l)
        }
        func row(_ r: Row, _ text: String, y: CGFloat) {
            let isSel = r == selected
            add((isSel ? "> " : "  ") + text, y: y, color: isSel ? .accent : .white)
        }
        func field(_ r: Row, _ value: String, placeholder: String) -> String {
            if selected == r { return value + "_" }
            return value.isEmpty ? placeholder : value
        }

        var y: CGFloat = 494
        row(.name, "YOUR NAME      \(field(.name, playerName, placeholder: ""))", y: y)
        y -= 34
        row(.players, "PLAYERS HERE   < \(localPlayers) >", y: y)
        y -= 46
        row(.host, "HOST A GAME", y: y)
        y -= 46

        add("GAMES NEARBY", y: y, size: 14, color: .dim)
        y -= 30
        if listed.isEmpty {
            add(browser.error ?? "  none found yet, still looking...", y: y, size: 15, color: .dim)
            y -= 30
        }
        for (i, h) in listed.enumerated() {
            let note = !h.isCompatible ? "  (different game version)" : h.needsCode ? "  (needs code)" : ""
            row(.found(i), "JOIN  \(h.name)\(note)", y: y)
            y -= 30
        }
        y -= 16
        add("JOIN ANY GAME", y: y, size: 14, color: .dim)
        y -= 30
        row(.code, "CODE           \(field(.code, code, placeholder: "(type the host's code)"))", y: y)
        y -= 34
        row(.address, "ADDRESS        \(field(.address, address, placeholder: "(or the host's IP address)"))", y: y)
        y -= 34
        row(.server, "RELAY SERVER   \(field(.server, server, placeholder: "none: codes work on this network only"))", y: y)
        y -= 42
        row(.back, "BACK", y: y)

        if let message {
            add(message, x: 480, y: 58, size: 14, color: SKColor(red: 1, green: 0.45, blue: 0.4, alpha: 1), align: .center)
        } else if selected == .server {
            add("A relay lets players join over the internet with just the code, no port forwarding.", x: 480, y: 58,
                size: 13, color: .dim, align: .center)
        }
    }

    // MARK: Codes

    /// "ABCD-EFGH" gives room ABCD, secret EFGH. Four characters alone are just a room (open game).
    private func parsedCode() -> (room: String, secret: String)? {
        guard let c = RoomCode.normalize(code) else { return nil }
        switch c.count {
        case 8: return (String(c.prefix(4)), String(c.suffix(4)))
        case 4: return (c, "")
        default: return nil
        }
    }

    /// The secret to use when the room is already known (a listed game or an address): the
    /// last four characters of whatever's in the code row.
    private var typedSecret: String {
        guard let c = RoomCode.normalize(code), c.count == 4 || c.count == 8 else { return "" }
        return String(c.suffix(4))
    }

    // MARK: Actions

    private func choose() {
        let trimmed = playerName.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? OnlineScene.defaultName : trimmed
        let relay = server.trimmingCharacters(in: .whitespaces).isEmpty ? nil : server
        switch selected {
        case .host:
            save()
            coordinator.hostOnline(name: name, localPlayers: localPlayers, relayServer: relay)
        case let .found(i) where listed.indices.contains(i):
            let h = listed[i]
            guard h.isCompatible else {
                message = "\(h.name) runs a different version of the game"
                return refresh()
            }
            if h.needsCode && typedSecret.isEmpty {
                message = "\(h.name) needs its code: type it in the CODE row, then pick the game again"
                selected = .code
                return refresh()
            }
            save()
            coordinator.joinOnline(.addresses(h.addresses), label: h.name, secret: h.needsCode ? typedSecret : "",
                                   relayServer: relay, name: name, localPlayers: localPlayers)
        case .code:
            guard let (room, secret) = parsedCode() else {
                message = "Codes look like ABCD-EFGH (or four characters for open games)"
                return refresh()
            }
            let nearby = browser.host(room: room)?.addresses ?? []
            if nearby.isEmpty && relay == nil {
                message = "No game \(room) on this network. To join over the internet, set a relay server."
                return refresh()
            }
            save()
            coordinator.joinOnline(.room(room, nearby: nearby), label: "game \(room)", secret: secret,
                                   relayServer: relay, name: name, localPlayers: localPlayers)
        case .address:
            guard SocketAddress.split(address, defaultPort: NetProtocol.defaultPort) != nil else {
                message = "Type the host's address, like 192.168.1.20 (add :port if it isn't \(NetProtocol.defaultPort))"
                return refresh()
            }
            save()
            coordinator.joinOnline(.address(address), label: address, secret: typedSecret, relayServer: relay,
                                   name: name, localPlayers: localPlayers)
        case .back:
            coordinator.showMenu()
        case .name, .server:
            save()
            selected = rows[(rows.firstIndex(of: selected)! + 1) % rows.count]
            refresh()
        default:
            break
        }
    }

    override func keyPressed(_ key: Key, isRepeat: Bool) {
        let rows = rows
        let idx = rows.firstIndex(of: selected) ?? 0
        switch key {
        case .up:
            selected = rows[(idx - 1 + rows.count) % rows.count]
            SoundSystem.shared.play(.menuMove)
        case .down, .tab:
            selected = rows[(idx + 1) % rows.count]
            SoundSystem.shared.play(.menuMove)
        case .left, .right:
            if selected == .players {
                localPlayers = clamp(localPlayers + (key == .left ? -1 : 1), 1, 4)
                SoundSystem.shared.play(.menuMove)
            }
        case .enter:
            if isRepeat { return }
            SoundSystem.shared.play(.menuSelect)
            return choose()
        case .escape:
            return coordinator.showMenu()
        default:
            // Off a text field, letters still navigate like the main menu.
            switch key {
            case .w: return keyPressed(.up, isRepeat: isRepeat)
            case .s: return keyPressed(.down, isRepeat: isRepeat)
            case .a: return keyPressed(.left, isRepeat: isRepeat)
            case .d: return keyPressed(.right, isRepeat: isRepeat)
            case .space: return keyPressed(.enter, isRepeat: isRepeat)
            default: return
            }
        }
        refresh()
    }

    #if os(macOS)
    override func handleTyping(_ event: NSEvent) -> Bool {
        guard selected.isTextField else { return false }
        switch event.keyCode {
        case 36, 76, 53, 48, 123, 124, 125, 126:
            return false // Enter, Esc, Tab and arrows keep their menu meaning.
        case 51, 117:
            switch selected {
            case .name: if !playerName.isEmpty { playerName.removeLast() }
            case .code: if !code.isEmpty { code.removeLast() }
            case .address: if !address.isEmpty { address.removeLast() }
            case .server: if !server.isEmpty { server.removeLast() }
            default: break
            }
        default:
            let typed = event.characters ?? ""
            switch selected {
            case .name:
                let ok = typed.filter { $0.isLetter || $0.isNumber || " -_'.!".contains($0) }
                playerName = String((playerName + ok).prefix(NetProtocol.maxNameLength))
            case .code:
                let ok = typed.uppercased().filter { RoomCode.alphabet.contains($0) || $0 == "-" }
                var next = code + ok
                // Add the dash after the room part as the player types.
                if next.count == 4, !ok.isEmpty, !next.contains("-") { next += "-" }
                code = String(next.prefix(9))
            case .address:
                let ok = typed.filter { $0.isLetter || $0.isNumber || ".:-[]".contains($0) }
                address = String((address + ok).prefix(64))
            case .server:
                let ok = typed.filter { $0.isLetter || $0.isNumber || ".:-[]".contains($0) }
                server = String((server + ok).prefix(64))
            default:
                break
            }
        }
        message = nil
        refresh()
        return true
    }
    #endif
}
