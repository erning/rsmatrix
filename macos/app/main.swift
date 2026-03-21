import AppKit
import Metal

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    private var matrixView: MatrixView!
    private var effectView: NSVisualEffectView!
    private var startFullscreen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        parseArguments()

        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        matrixView = MatrixView(frame: frame, metalDevice: device)

        // Container view holds the blur effect view behind the Metal view
        let containerView = NSView(frame: frame)

        effectView = NSVisualEffectView(frame: frame)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.autoresizingMask = [.width, .height]
        effectView.isHidden = true

        matrixView.autoresizingMask = [.width, .height]
        matrixView.backgroundEffectView = effectView

        containerView.addSubview(effectView)
        containerView.addSubview(matrixView)

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Matrix"
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.contentView = containerView
        window.contentMinSize = NSSize(
            width: matrixView.metalRenderer.cellSize.width * 20,
            height: matrixView.metalRenderer.cellSize.height * 10
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

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Quit Matrix",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // View menu
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

        // Characters menu
        let charMenuItem = NSMenuItem()
        mainMenu.addItem(charMenuItem)
        let charMenu = NSMenu(title: "Characters")
        charMenuItem.submenu = charMenu
        charMenu.addItem(
            withTitle: "Combined (Kana + ASCII)",
            action: #selector(MatrixView.setCharsetCombined(_:)),
            keyEquivalent: "b"
        ).image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        charMenu.addItem(
            withTitle: "ASCII Only",
            action: #selector(MatrixView.setCharsetASCII(_:)),
            keyEquivalent: "a"
        ).image = NSImage(systemSymbolName: "textformat.abc", accessibilityDescription: nil)
        charMenu.addItem(
            withTitle: "Katakana Only",
            action: #selector(MatrixView.setCharsetKana(_:)),
            keyEquivalent: "k"
        ).image = NSImage(systemSymbolName: "character", accessibilityDescription: nil)

        // Effects menu
        let effectsMenuItem = NSMenuItem()
        mainMenu.addItem(effectsMenuItem)
        let effectsMenu = NSMenu(title: "Effects")
        effectsMenuItem.submenu = effectsMenu
        effectsMenu.addItem(
            withTitle: "Toggle Bloom",
            action: #selector(MatrixView.toggleBloom(_:)),
            keyEquivalent: "g"
        ).image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        effectsMenu.addItem(
            withTitle: "Toggle CRT",
            action: #selector(MatrixView.toggleCRT(_:)),
            keyEquivalent: "r"
        ).image = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)
        effectsMenu.addItem(
            withTitle: "Toggle Background Blur",
            action: #selector(MatrixView.toggleBackgroundBlur(_:)),
            keyEquivalent: "t"
        ).image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)

        NSApplication.shared.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
