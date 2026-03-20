import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let matrixView = MatrixView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Matrix"
        window.contentView = matrixView
        window.contentMinSize = NSSize(
            width: matrixView.renderer.cellSize.width * 20,
            height: matrixView.renderer.cellSize.height * 10
        )
        window.tabbingMode = .disallowed
        window.collectionBehavior = .fullScreenPrimary
        window.backgroundColor = .black
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(matrixView)

        setupMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Quit Matrix",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(
            withTitle: "Toggle Fullscreen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )

        NSApplication.shared.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
