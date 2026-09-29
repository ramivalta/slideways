import AppKit
import SlicksGame
import SpriteKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scene = GameInfo.sceneSize
        let scale: CGFloat = 1.4
        let rect = NSRect(x: 0, y: 0, width: scene.width * scale, height: scene.height * scale)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = GameInfo.title
        window.contentAspectRatio = scene
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self

        let view = GameView(frame: rect)
        view.ignoresSiblingOrder = true
        view.preferredFramesPerSecond = 120
        #if DEBUG
        view.showsFPS = true
        view.showsNodeCount = true
        #endif
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)

        GameCoordinator.shared.start(in: view)
        NSApp.activate()
        #if DEBUG
        DebugHarness.runIfRequested(view: view)
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidResignActive(_ notification: Notification) {
        Input.shared.releaseAll()
    }

    func windowDidResignKey(_ notification: Notification) {
        Input.shared.releaseAll()
    }
}

func buildMainMenu() -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About \(GameInfo.title)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide \(GameInfo.title)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit \(GameInfo.title)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let viewItem = NSMenuItem()
    main.addItem(viewItem)
    let viewMenu = NSMenu(title: "View")
    let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fullScreen.keyEquivalentModifierMask = [.command, .control]
    viewItem.submenu = viewMenu

    let windowItem = NSMenuItem()
    main.addItem(windowItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowItem.submenu = windowMenu
    NSApp.windowsMenu = windowMenu

    return main
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = buildMainMenu()
app.run()
