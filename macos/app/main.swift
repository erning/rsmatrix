import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var startFullscreen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        parseArguments()

        let matrixView = MatrixView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Matrix"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
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

        if startFullscreen {
            window.toggleFullScreen(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func parseArguments() {
        let args = CommandLine.arguments
        for arg in args.dropFirst() {
            switch arg {
            case "--fullscreen", "-f":
                startFullscreen = true
            case "--ascii", "-a":
                rsmatrix_set_charset(1)
            case "--kana", "-k":
                rsmatrix_set_charset(2)
            default:
                break
            }
        }
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
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            withTitle: "Zoom In",
            action: #selector(MatrixView.zoomIn(_:)),
            keyEquivalent: "+"
        )
        viewMenu.addItem(
            withTitle: "Zoom Out",
            action: #selector(MatrixView.zoomOut(_:)),
            keyEquivalent: "-"
        )
        viewMenu.addItem(
            withTitle: "Actual Size",
            action: #selector(MatrixView.zoomReset(_:)),
            keyEquivalent: "0"
        )

        let charMenuItem = NSMenuItem()
        mainMenu.addItem(charMenuItem)
        let charMenu = NSMenu(title: "Characters")
        charMenuItem.submenu = charMenu
        charMenu.addItem(
            withTitle: "Combined (Kana + ASCII)",
            action: #selector(MatrixView.setCharsetCombined(_:)),
            keyEquivalent: "b"
        )
        charMenu.addItem(
            withTitle: "ASCII Only",
            action: #selector(MatrixView.setCharsetASCII(_:)),
            keyEquivalent: "a"
        )
        charMenu.addItem(
            withTitle: "Katakana Only",
            action: #selector(MatrixView.setCharsetKana(_:)),
            keyEquivalent: "k"
        )

        NSApplication.shared.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
