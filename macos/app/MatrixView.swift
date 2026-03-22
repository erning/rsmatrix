import MetalKit
import QuartzCore

enum RendererMode {
    case metal
    case coreText
}

class MatrixView: NSView, MTKViewDelegate, NSMenuItemValidation {
    private(set) var scene: MetalSceneController
    var currentCharset: UInt32 = 0
    private var fontSize: CGFloat = 14
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
        let config = RenderConfig(fontSize: fontSize)
        self.scene = MetalSceneController(device: metalDevice, config: config)
        super.init(frame: frame)

        scene.mtkView.frame = bounds
        scene.mtkView.autoresizingMask = [.width, .height]
        scene.mtkView.delegate = self
        scene.mtkView.wantsLayer = true
        scene.mtkView.layer?.isOpaque = false
        scene.mtkView.layer?.backgroundColor = CGColor.clear
        addSubview(scene.mtkView)

        scene.updatePreferredFrameRate(for: nil)
        scene.mtkView.isPaused = false
        scene.mtkView.enableSetNeedsDisplay = false

        scene.recalculateGrid(bounds: bounds.size)
        scene.simulation.resetFrameTime()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        scene.resizeOffscreenTextures(size: size)
        if rendererMode == .coreText {
            bitmapWidth = 0
            bitmapHeight = 0
        }
    }

    func draw(in view: MTKView) {
        scene.advanceFrame()

        switch rendererMode {
        case .metal:
            scene.render(in: view)

        case .coreText:
            guard let ctRenderer = coreTextRenderer else { return }
            ensureBitmapContext()
            guard let ctx = bitmapContext else { return }

            // Clear to black
            ctx.saveGState()
            ctx.resetClip()
            let unscaledRect = CGRect(x: 0, y: 0, width: bitmapWidth, height: bitmapHeight)
            let ctm = ctx.ctm
            ctx.concatenate(ctm.inverted())
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.fill(unscaledRect)
            ctx.concatenate(ctm)
            ctx.restoreGState()

            // Render glyphs
            let sim = scene.simulation
            guard let s = sim.simulation else { return }
            let grid = rsmatrix_get_grid(s)
            ctRenderer.render(context: ctx, grid: grid, width: sim.gridWidth, height: sim.gridHeight)

            // Upload bitmap to Metal texture and present
            if let data = ctx.data {
                scene.metalRenderer.ensureBlitTexture(width: bitmapWidth, height: bitmapHeight)
                scene.metalRenderer.advanceBlitTexture()
                let region = MTLRegionMake2D(0, 0, bitmapWidth, bitmapHeight)
                scene.metalRenderer.blitTexture?.replace(
                    region: region, mipmapLevel: 0,
                    withBytes: data, bytesPerRow: bitmapWidth * 4)
                scene.metalRenderer.renderBlit(in: view)
            }
        }
    }

    private func ensureBitmapContext() {
        let dw = Int(scene.mtkView.drawableSize.width)
        let dh = Int(scene.mtkView.drawableSize.height)
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

        let scale = window?.backingScaleFactor ?? 2.0
        bitmapContext?.scaleBy(x: scale, y: scale)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            scene.simulation.resetFrameTime()
            lastBackingScale = window.backingScaleFactor
            scene.updatePreferredFrameRate(for: window.screen)
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
        scene.updatePreferredFrameRate(for: window?.screen)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if scale != lastBackingScale && lastBackingScale != 0 {
            scene.metalRenderer.buildAtlas(scaleFactor: scale)
            if rendererMode == .coreText {
                bitmapWidth = 0
                bitmapHeight = 0
            }
            recalculateGrid()
        }
        lastBackingScale = scale
        if isInFullscreen && scene.metalRenderer.backgroundBlurEnabled {
            scene.captureBlurredDesktop(screen: window?.screen ?? NSScreen.main)
        }
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateGrid()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers else { return }
        switch chars {
        case "c":
            scene.simulation.clear()
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
            menuItem.state = scene.metalRenderer.bloomEnabled ? .on : .off
            return rendererMode == .metal
        case #selector(toggleCRT):
            menuItem.state = scene.metalRenderer.crtEnabled ? .on : .off
            return rendererMode == .metal
        case #selector(toggleBackgroundBlur):
            menuItem.state = scene.metalRenderer.backgroundBlurEnabled ? .on : .off
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
        scene.metalRenderer.rebuildForFontSize(fontSize, scaleFactor: scale)
        if rendererMode == .coreText {
            coreTextRenderer = MatrixRenderer(fontSize: fontSize)
            bitmapWidth = 0
            bitmapHeight = 0
        }
        recalculateGrid()
        scene.resizeOffscreenTextures(size: scene.mtkView.drawableSize)
        updateContentMinSize()
    }

    private func recalculateGrid() {
        let cs = rendererMode == .coreText
            ? (coreTextRenderer?.cellSize ?? scene.metalRenderer.cellSize)
            : scene.metalRenderer.cellSize
        scene.simulation.recalculateGrid(bounds: bounds.size, cellSize: cs)
    }

    private func updateContentMinSize() {
        let cs = rendererMode == .coreText
            ? (coreTextRenderer?.cellSize ?? scene.metalRenderer.cellSize)
            : scene.metalRenderer.cellSize
        window?.contentMinSize = NSSize(
            width: cs.width * 20, height: cs.height * 10)
    }

    // MARK: - Effects

    @objc func toggleBloom(_ sender: Any?) {
        scene.metalRenderer.bloomEnabled.toggle()
    }

    @objc func toggleCRT(_ sender: Any?) {
        scene.metalRenderer.crtEnabled.toggle()
    }

    @objc func toggleBackgroundBlur(_ sender: Any?) {
        scene.metalRenderer.backgroundBlurEnabled.toggle()
        if isInFullscreen {
            if scene.metalRenderer.backgroundBlurEnabled {
                scene.captureBlurredDesktop(screen: window?.screen ?? NSScreen.main)
            } else {
                scene.metalRenderer.backgroundTexture = nil
            }
        }
        applyBlurVisualState()
    }

    @objc private func didEnterFullscreen(_ notification: Notification) {
        isInFullscreen = true
        applyBlurVisualState()
        if scene.metalRenderer.backgroundBlurEnabled {
            scene.captureBlurredDesktop(screen: window?.screen ?? NSScreen.main)
        }
    }

    @objc private func didExitFullscreen(_ notification: Notification) {
        isInFullscreen = false
        scene.metalRenderer.backgroundTexture = nil
        applyBlurVisualState()
    }

    // MARK: - Blur visual state

    private func applyBlurVisualState() {
        let active = rendererMode == .metal
            && scene.metalRenderer.backgroundBlurEnabled && !isInFullscreen
        scene.metalRenderer.isFullscreen = isInFullscreen

        backgroundEffectView?.isHidden = !active
        scene.mtkView.layer?.isOpaque = !active
        scene.mtkView.layer?.backgroundColor = active ? CGColor.clear : NSColor.black.cgColor

        if let window = window {
            window.isOpaque = !active
            window.backgroundColor = active ? .clear : .black
        }
    }
}
