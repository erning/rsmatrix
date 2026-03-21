import MetalKit
import QuartzCore

enum RendererMode {
    case metal
    case coreText
}

class MatrixView: MTKView, MTKViewDelegate, NSMenuItemValidation {
    private(set) var metalRenderer: MetalRenderer
    private var simulation: OpaquePointer?
    private var lastFrameTime: TimeInterval = 0
    private var gridWidth: UInt32 = 0
    private var gridHeight: UInt32 = 0
    private var fontSize: CGFloat = 14
    var currentCharset: UInt32 = 0
    private var isInFullscreen = false
    private var lastBackingScale: CGFloat = 0

    // Renderer switching
    private var rendererMode: RendererMode = .metal
    private var coreTextRenderer: MatrixRenderer?
    private var bitmapContext: CGContext?
    private var bitmapWidth: Int = 0
    private var bitmapHeight: Int = 0

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
        if rendererMode == .coreText {
            bitmapWidth = 0
            bitmapHeight = 0
        }
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
        let w = rsmatrix_grid_width(sim)
        let h = rsmatrix_grid_height(sim)

        switch rendererMode {
        case .metal:
            metalRenderer.updateInstances(grid: grid, width: w, height: h)
            metalRenderer.render(in: self)

        case .coreText:
            guard let ctRenderer = coreTextRenderer else { return }
            ensureBitmapContext()
            guard let ctx = bitmapContext else { return }

            // Clear to black
            ctx.saveGState()
            ctx.resetClip()
            let unscaledRect = CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight)
            // Reset CTM to identity for pixel-level clear
            let ctm = ctx.ctm
            ctx.concatenate(ctm.inverted())
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(unscaledRect)
            // Restore scaled CTM
            ctx.concatenate(ctm)
            ctx.restoreGState()

            // Render glyphs
            ctRenderer.render(context: ctx, grid: grid, width: w, height: h)

            // Upload bitmap to Metal texture and present
            if let data = ctx.data {
                metalRenderer.ensureBlitTexture(width: bitmapWidth, height: bitmapHeight)
                metalRenderer.advanceBlitTexture()
                let region = MTLRegionMake2D(0, 0, bitmapWidth, bitmapHeight)
                metalRenderer.blitTexture?.replace(
                    region: region, mipmapLevel: 0,
                    withBytes: data, bytesPerRow: bitmapWidth * 4)
                metalRenderer.renderBlit(in: self)
            }
        }
    }

    private func ensureBitmapContext() {
        let dw = Int(drawableSize.width)
        let dh = Int(drawableSize.height)
        guard dw > 0 && dh > 0 else { return }
        guard dw != bitmapWidth || dh != bitmapHeight else { return }

        bitmapWidth = dw
        bitmapHeight = dh
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        bitmapContext = CGContext(
            data: nil, width: dw, height: dh,
            bitsPerComponent: 8, bytesPerRow: dw * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)

        // Scale for Retina so CoreText draws in points
        let scale = window?.backingScaleFactor ?? 2.0
        bitmapContext?.scaleBy(x: scale, y: scale)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            lastFrameTime = CACurrentMediaTime()
            lastBackingScale = window.backingScaleFactor
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
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didEnterFullScreenNotification, object: nil)
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didExitFullScreenNotification, object: nil)
        }
    }

    @objc private func screenDidChange(_ notification: Notification) {
        updatePreferredFrameRate()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if scale != lastBackingScale && lastBackingScale != 0 {
            metalRenderer.buildAtlas(scaleFactor: scale)
            if rendererMode == .coreText {
                bitmapWidth = 0
                bitmapHeight = 0
            }
            recalculateGrid()
        }
        lastBackingScale = scale
        if isInFullscreen && metalRenderer.backgroundBlurEnabled {
            captureAndBlurDesktop()
        }
    }

    // MARK: - Frame Rate

    private func updatePreferredFrameRate() {
        preferredFramesPerSecond = MetalRenderer.displayRefreshRate(
            for: window?.screen ?? NSScreen.main)
        isPaused = false
        enableSetNeedsDisplay = false
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateGrid()
    }

    private func recalculateGrid() {
        let cs = rendererMode == .coreText
            ? (coreTextRenderer?.cellSize ?? metalRenderer.cellSize)
            : metalRenderer.cellSize
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
        case #selector(setRendererMetal):
            menuItem.state = rendererMode == .metal ? .on : .off
        case #selector(setRendererCoreText):
            menuItem.state = rendererMode == .coreText ? .on : .off
        case #selector(toggleBloom):
            menuItem.state = metalRenderer.bloomEnabled ? .on : .off
            return rendererMode == .metal
        case #selector(toggleCRT):
            menuItem.state = metalRenderer.crtEnabled ? .on : .off
            return rendererMode == .metal
        case #selector(toggleBackgroundBlur):
            menuItem.state = metalRenderer.backgroundBlurEnabled ? .on : .off
            return rendererMode == .metal
        default:
            break
        }
        return true
    }

    // MARK: - Renderer Switching

    @objc func setRendererMetal(_ sender: Any?) {
        guard rendererMode != .metal else { return }
        rendererMode = .metal
        coreTextRenderer = nil
        bitmapContext = nil
        recalculateGrid()
        updateContentMinSize()
        applyBlurVisualState()
    }

    @objc func setRendererCoreText(_ sender: Any?) {
        guard rendererMode != .coreText else { return }
        rendererMode = .coreText
        coreTextRenderer = MatrixRenderer(fontSize: fontSize)
        bitmapWidth = 0
        bitmapHeight = 0
        recalculateGrid()
        updateContentMinSize()
        applyBlurVisualState()
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
        if rendererMode == .coreText {
            coreTextRenderer = MatrixRenderer(fontSize: fontSize)
            bitmapWidth = 0
            bitmapHeight = 0
        }
        recalculateGrid()
        metalRenderer.resizeOffscreenTextures(
            width: Int(drawableSize.width), height: Int(drawableSize.height))
        updateContentMinSize()
    }

    private func updateContentMinSize() {
        let cs = rendererMode == .coreText
            ? (coreTextRenderer?.cellSize ?? metalRenderer.cellSize)
            : metalRenderer.cellSize
        window?.contentMinSize = NSSize(
            width: cs.width * 20, height: cs.height * 10)
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
        if isInFullscreen {
            if metalRenderer.backgroundBlurEnabled {
                captureAndBlurDesktop()
            } else {
                metalRenderer.backgroundTexture = nil
            }
        }
        applyBlurVisualState()
    }

    @objc private func didEnterFullscreen(_ notification: Notification) {
        isInFullscreen = true
        applyBlurVisualState()
        if metalRenderer.backgroundBlurEnabled {
            captureAndBlurDesktop()
        }
    }

    @objc private func didExitFullscreen(_ notification: Notification) {
        isInFullscreen = false
        metalRenderer.backgroundTexture = nil
        applyBlurVisualState()
    }

    // MARK: - Wallpaper capture

    private func captureAndBlurDesktop() {
        guard let device = self.device else { return }
        let screen = window?.screen ?? NSScreen.main
        metalRenderer.backgroundTexture = MetalRenderer.captureBlurredDesktop(
            device: device, screen: screen)
    }

    private func applyBlurVisualState() {
        let active = rendererMode == .metal
            && metalRenderer.backgroundBlurEnabled && !isInFullscreen
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
