import ScreenSaver
import MetalKit

// Known issues on macOS Sonoma (14) and later:
//
// Apple replaced the native screensaver host with legacyScreenSaver.appex,
// introducing several regressions that affect all third-party .saver bundles:
//
// - isPreview is unreliable (always true on Sonoma, inverted on Tahoe)
// - stopAnimation() is not called during normal fullscreen operation
// - Instances accumulate without being destroyed
// - legacyScreenSaver process does not terminate after the screensaver stops
// - Preview is disabled (guard !isPreview) to avoid rendering in broken state
//
// Community workarounds (exit(0) on willstop notification, instance deduplication)
// have been tried but do not reliably fix the process lifecycle issues.
//
// The standalone app (make run-app) is the recommended alternative on Sonoma+.
// See: https://github.com/JohnCoates/Aerial/issues — Aerial's issue tracker
//      documents the same regressions across Sonoma/Sequoia/Tahoe.

private let bundleID = "com.rsmatrix.MatrixSaver"
private let prefCharset  = "Charset"         // "combined", "ascii", "kana"
private let prefFontSize = "FontSize"        // Int (10,12,14,16,18,20,24)
private let prefBloom    = "Bloom"           // Bool
private let prefCRT      = "CRT"             // Bool
private let prefBlur     = "BackgroundBlur"  // Bool

@objc(MatrixSaverView)
class MatrixSaverView: ScreenSaverView, MTKViewDelegate {
    private var simulation: OpaquePointer?
    private var lastFrameTime: TimeInterval = 0
    private var gridWidth: UInt32 = 0
    private var gridHeight: UInt32 = 0

    private var mtkView: MTKView?
    private var metalRenderer: MetalRenderer?

    // Configure sheet
    private var configSheet: NSWindow?
    private var charsetPopup: NSPopUpButton?
    private var fontSizePopup: NSPopUpButton?
    private var bloomCheck: NSButton?
    private var crtCheck: NSButton?
    private var blurCheck: NSButton?

    private var defaults: ScreenSaverDefaults {
        ScreenSaverDefaults(forModuleWithName: bundleID)!
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)

        let defs = defaults
        defs.register(defaults: [
            prefCharset: "combined",
            prefFontSize: 14,
            prefBloom: true,
            prefCRT: true,
            prefBlur: true,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let sim = simulation {
            rsmatrix_destroy(sim)
        }
    }

    // MARK: - Animation

    override func startAnimation() {
        super.startAnimation()
        guard !isPreview else { return }
        tearDown()
        applyCharset()

        let defs = defaults

        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let fontSize = CGFloat(max(defs.integer(forKey: prefFontSize), 10))
        let saverBundle = Bundle(for: MatrixSaverView.self)
        let screen = window?.screen ?? NSScreen.main
        let renderer = MetalRenderer(
            device: device,
            fontSize: fontSize,
            bundle: saverBundle,
            scaleFactor: screen?.backingScaleFactor
        )
        renderer.bloomEnabled = defs.bool(forKey: prefBloom)
        renderer.crtEnabled = defs.bool(forKey: prefCRT)
        renderer.isFullscreen = true
        metalRenderer = renderer

        // Capture and blur desktop for background
        if defs.bool(forKey: prefBlur) {
            captureAndBlurDesktop(device: device, renderer: renderer)
        }

        let view = MTKView(frame: bounds, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoresizingMask = [.width, .height]
        view.layer?.isOpaque = true
        view.delegate = self
        addSubview(view)
        mtkView = view

        // Adapt frame rate to display refresh rate
        let fps = MetalRenderer.displayRefreshRate(for: window?.screen ?? NSScreen.main)
        animationTimeInterval = 1.0 / Double(fps)

        recalculateGrid()
        lastFrameTime = CACurrentMediaTime()
    }

    override func stopAnimation() {
        super.stopAnimation()
        tearDown()
    }

    private func tearDown() {
        mtkView?.removeFromSuperview()
        mtkView = nil
        metalRenderer = nil
        if let sim = simulation {
            rsmatrix_destroy(sim)
            simulation = nil
        }
        gridWidth = 0
        gridHeight = 0
    }

    override func animateOneFrame() {
        let now = CACurrentMediaTime()
        let delta = now - lastFrameTime
        lastFrameTime = now

        let deltaMs = UInt32(min(delta * 1000.0, 1000.0))
        if let sim = simulation, deltaMs > 0 {
            rsmatrix_tick(sim, deltaMs)
        }

        guard let sim = simulation, let renderer = metalRenderer else { return }
        let grid = rsmatrix_get_grid(sim)
        renderer.updateInstances(
            grid: grid,
            width: rsmatrix_grid_width(sim),
            height: rsmatrix_grid_height(sim)
        )
        mtkView?.draw()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        metalRenderer?.resizeOffscreenTextures(width: Int(size.width), height: Int(size.height))
    }

    func draw(in view: MTKView) {
        metalRenderer?.render(in: view)
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateGrid()
    }

    // MARK: - Background capture

    private func captureAndBlurDesktop(device: MTLDevice, renderer: MetalRenderer) {
        let screen = window?.screen ?? NSScreen.main
        renderer.backgroundTexture = MetalRenderer.captureBlurredDesktop(
            device: device, screen: screen)
    }

    // MARK: - Preferences

    private func applyCharset() {
        let charset = defaults.string(forKey: prefCharset) ?? "combined"
        let mode: UInt32
        switch charset {
        case "ascii": mode = 1
        case "kana":  mode = 2
        default:      mode = 0
        }
        rsmatrix_set_charset(mode)
    }

    // MARK: - Configure sheet

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        if let sheet = configSheet { return sheet }

        let w: CGFloat = 320
        let h: CGFloat = 260
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.title = "MatrixSaver Options"

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let labelX: CGFloat = 20
        let controlX: CGFloat = 110
        let controlW: CGFloat = 190

        let defs = defaults

        // Row 5 (top): Charset
        let y5: CGFloat = 215
        let csLabel = NSTextField(labelWithString: "Characters:")
        csLabel.frame = NSRect(x: labelX, y: y5, width: 85, height: 20)
        contentView.addSubview(csLabel)

        let cPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y5 - 3, width: controlW, height: 26))
        cPopup.addItems(withTitles: ["Combined (Kana + ASCII)", "ASCII only", "Katakana only"])
        let curCharset = defs.string(forKey: prefCharset) ?? "combined"
        switch curCharset {
        case "ascii": cPopup.selectItem(at: 1)
        case "kana":  cPopup.selectItem(at: 2)
        default:      cPopup.selectItem(at: 0)
        }
        contentView.addSubview(cPopup)
        charsetPopup = cPopup

        // Row 4: Font Size
        let y4: CGFloat = 178
        let fsLabel = NSTextField(labelWithString: "Font Size:")
        fsLabel.frame = NSRect(x: labelX, y: y4, width: 85, height: 20)
        contentView.addSubview(fsLabel)

        let fsPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y4 - 3, width: controlW, height: 26))
        let fontSizes = ["10", "12", "14", "16", "18", "20", "24"]
        fsPopup.addItems(withTitles: fontSizes)
        let curFontSize = defs.integer(forKey: prefFontSize)
        if let idx = fontSizes.firstIndex(of: "\(curFontSize)") {
            fsPopup.selectItem(at: idx)
        } else {
            fsPopup.selectItem(at: 2) // default 14
        }
        contentView.addSubview(fsPopup)
        fontSizePopup = fsPopup

        // Row 3: Bloom
        let y3: CGFloat = 135
        let efLabel = NSTextField(labelWithString: "Effects:")
        efLabel.frame = NSRect(x: labelX, y: y3, width: 85, height: 20)
        contentView.addSubview(efLabel)

        let bloom = NSButton(checkboxWithTitle: "Bloom", target: nil, action: nil)
        bloom.frame = NSRect(x: controlX, y: y3, width: controlW, height: 20)
        bloom.state = defs.bool(forKey: prefBloom) ? .on : .off
        contentView.addSubview(bloom)
        bloomCheck = bloom

        // Row 2: CRT
        let y2: CGFloat = 110
        let crt = NSButton(checkboxWithTitle: "CRT", target: nil, action: nil)
        crt.frame = NSRect(x: controlX, y: y2, width: controlW, height: 20)
        crt.state = defs.bool(forKey: prefCRT) ? .on : .off
        contentView.addSubview(crt)
        crtCheck = crt

        // Row 1: Background Blur
        let y1: CGFloat = 85
        let blur = NSButton(checkboxWithTitle: "Background Blur", target: nil, action: nil)
        blur.frame = NSRect(x: controlX, y: y1, width: controlW, height: 20)
        blur.state = defs.bool(forKey: prefBlur) ? .on : .off
        contentView.addSubview(blur)
        blurCheck = blur

        // Buttons
        let okButton = NSButton(frame: NSRect(x: w - 100, y: 12, width: 80, height: 28))
        okButton.title = "OK"
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        okButton.target = self
        okButton.action = #selector(configSheetOK(_:))
        contentView.addSubview(okButton)

        let cancelButton = NSButton(frame: NSRect(x: w - 190, y: 12, width: 80, height: 28))
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(configSheetCancel(_:))
        contentView.addSubview(cancelButton)

        sheet.contentView = contentView
        configSheet = sheet
        return sheet
    }

    @objc private func configSheetOK(_ sender: Any?) {
        let defs = defaults

        let charsetValue: String
        switch charsetPopup?.indexOfSelectedItem {
        case 1:  charsetValue = "ascii"
        case 2:  charsetValue = "kana"
        default: charsetValue = "combined"
        }
        defs.set(charsetValue, forKey: prefCharset)

        let fontSizes = [10, 12, 14, 16, 18, 20, 24]
        let fsIndex = fontSizePopup?.indexOfSelectedItem ?? 2
        defs.set(fontSizes.indices.contains(fsIndex) ? fontSizes[fsIndex] : 14, forKey: prefFontSize)

        defs.set(bloomCheck?.state == .on, forKey: prefBloom)
        defs.set(crtCheck?.state == .on, forKey: prefCRT)
        defs.set(blurCheck?.state == .on, forKey: prefBlur)
        defs.synchronize()

        applyCharset()

        dismissSheet()
    }

    @objc private func configSheetCancel(_ sender: Any?) {
        dismissSheet()
    }

    private func dismissSheet() {
        guard let sheet = configSheet, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
        configSheet = nil
    }

    // MARK: - Grid

    private func recalculateGrid() {
        guard let renderer = metalRenderer else { return }
        let cellSize = renderer.cellSize
        let newWidth = max(UInt32(bounds.width / cellSize.width), 1)
        let newHeight = max(UInt32(bounds.height / cellSize.height), 1)

        if newWidth == gridWidth && newHeight == gridHeight { return }

        gridWidth = newWidth
        gridHeight = newHeight

        if let sim = simulation {
            rsmatrix_resize(sim, gridWidth, gridHeight)
        } else {
            simulation = rsmatrix_create(gridWidth, gridHeight)
        }
    }
}
