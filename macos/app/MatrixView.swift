import MetalKit
import QuartzCore

class MatrixView: MTKView, MTKViewDelegate, NSMenuItemValidation {
    private(set) var metalRenderer: MetalRenderer
    private var simulation: OpaquePointer?
    private var lastFrameTime: TimeInterval = 0
    private var gridWidth: UInt32 = 0
    private var gridHeight: UInt32 = 0
    private var fontSize: CGFloat = 14
    private var currentCharset: UInt32 = 0
    private var isInFullscreen = false

    /// Set by AppDelegate for background blur toggle
    var backgroundEffectView: NSVisualEffectView?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .init(
            image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero))
    }

    init(frame: NSRect, metalDevice: MTLDevice) {
        self.metalRenderer = MetalRenderer(device: metalDevice, fontSize: fontSize)
        super.init(frame: frame, device: metalDevice)

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        updatePreferredFrameRate()
        delegate = self

        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = CGColor.clear

        recalculateGrid()
        lastFrameTime = CACurrentMediaTime()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let sim = simulation {
            rsmatrix_destroy(sim)
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        metalRenderer.resizeOffscreenTextures(
            width: Int(size.width), height: Int(size.height))
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let delta = now - lastFrameTime
        lastFrameTime = now
        let deltaMs = UInt32(min(delta * 1000.0, 1000.0))

        if let sim = simulation, deltaMs > 0 {
            rsmatrix_tick(sim, deltaMs)
        }

        guard let sim = simulation else { return }
        let grid = rsmatrix_get_grid(sim)
        metalRenderer.updateInstances(
            grid: grid,
            width: rsmatrix_grid_width(sim),
            height: rsmatrix_grid_height(sim))
        metalRenderer.render(in: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            lastFrameTime = CACurrentMediaTime()
            updatePreferredFrameRate()
            NotificationCenter.default.addObserver(
                self, selector: #selector(screenDidChange),
                name: NSWindow.didChangeScreenNotification, object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(didEnterFullscreen),
                name: NSWindow.didEnterFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(didExitFullscreen),
                name: NSWindow.didExitFullScreenNotification, object: window)
        } else {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeScreenNotification, object: nil)
        }
    }

    @objc private func screenDidChange(_ notification: Notification) {
        updatePreferredFrameRate()
    }

    // MARK: - Frame Rate

    private func updatePreferredFrameRate() {
        let screen = window?.screen ?? NSScreen.main
        var fps = 60
        if let screen = screen {
            let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")]
            if let displayID = screenNumber as? CGDirectDisplayID,
               let mode = CGDisplayCopyDisplayMode(displayID),
               mode.refreshRate > 0 {
                fps = Int(mode.refreshRate)
            } else {
                fps = screen.maximumFramesPerSecond
                if fps <= 0 { fps = 60 }
            }
        }
        preferredFramesPerSecond = fps
        isPaused = false
        enableSetNeedsDisplay = false
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateGrid()
    }

    private func recalculateGrid() {
        let cs = metalRenderer.cellSize
        let newWidth = max(UInt32(bounds.width / cs.width), 1)
        let newHeight = max(UInt32(bounds.height / cs.height), 1)

        if newWidth == gridWidth && newHeight == gridHeight { return }

        gridWidth = newWidth
        gridHeight = newHeight

        if let sim = simulation {
            rsmatrix_resize(sim, gridWidth, gridHeight)
        } else {
            simulation = rsmatrix_create(gridWidth, gridHeight)
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers else { return }
        switch chars {
        case "c":
            if let sim = simulation { rsmatrix_clear(sim) }
        case "\u{1b}":  // Escape
            if let w = window, w.styleMask.contains(.fullScreen) {
                w.toggleFullScreen(nil)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Charset

    @objc func setCharsetCombined(_ sender: Any?) { currentCharset = 0; rsmatrix_set_charset(0) }
    @objc func setCharsetASCII(_ sender: Any?)    { currentCharset = 1; rsmatrix_set_charset(1) }
    @objc func setCharsetKana(_ sender: Any?)     { currentCharset = 2; rsmatrix_set_charset(2) }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(setCharsetCombined):
            menuItem.state = currentCharset == 0 ? .on : .off
        case #selector(setCharsetASCII):
            menuItem.state = currentCharset == 1 ? .on : .off
        case #selector(setCharsetKana):
            menuItem.state = currentCharset == 2 ? .on : .off
        case #selector(toggleBloom):
            menuItem.state = metalRenderer.bloomEnabled ? .on : .off
        case #selector(toggleCRT):
            menuItem.state = metalRenderer.crtEnabled ? .on : .off
        case #selector(toggleBackgroundBlur):
            menuItem.state = metalRenderer.backgroundBlurEnabled ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) {
        fontSize = min(fontSize + 2, 28)
        rebuildRenderer()
    }

    @objc func zoomOut(_ sender: Any?) {
        fontSize = max(fontSize - 2, 6)
        rebuildRenderer()
    }

    @objc func zoomReset(_ sender: Any?) {
        fontSize = 14
        rebuildRenderer()
    }

    private func rebuildRenderer() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        metalRenderer.rebuildForFontSize(fontSize, scaleFactor: scale)
        recalculateGrid()
        // Re-create offscreen textures for the new cell size
        metalRenderer.resizeOffscreenTextures(
            width: Int(drawableSize.width), height: Int(drawableSize.height))
        window?.contentMinSize = NSSize(
            width: metalRenderer.cellSize.width * 20,
            height: metalRenderer.cellSize.height * 10
        )
    }

    // MARK: - Effects

    @objc func toggleBloom(_ sender: Any?) {
        metalRenderer.bloomEnabled.toggle()
    }

    @objc func toggleCRT(_ sender: Any?) {
        metalRenderer.crtEnabled.toggle()
    }

    @objc func toggleBackgroundBlur(_ sender: Any?) {
        metalRenderer.backgroundBlurEnabled.toggle()
        applyBlurVisualState()
    }

    @objc private func didEnterFullscreen(_ notification: Notification) {
        isInFullscreen = true
        applyBlurVisualState()
    }

    @objc private func didExitFullscreen(_ notification: Notification) {
        isInFullscreen = false
        applyBlurVisualState()
    }

    private func applyBlurVisualState() {
        let active = metalRenderer.backgroundBlurEnabled && !isInFullscreen
        metalRenderer.isFullscreen = isInFullscreen

        backgroundEffectView?.isHidden = !active
        layer?.isOpaque = !active
        layer?.backgroundColor = active ? CGColor.clear : NSColor.black.cgColor

        if let window = window {
            window.isOpaque = !active
            window.backgroundColor = active ? .clear : .black
        }
    }
}
