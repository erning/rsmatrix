import ScreenSaver
import MetalKit
import CoreImage

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
        applyCharset()

        let defs = defaults

        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let fontSize: CGFloat = isPreview ? 6 : CGFloat(max(defs.integer(forKey: prefFontSize), 10))
        let saverBundle = Bundle(for: MatrixSaverView.self)
        let renderer = MetalRenderer(
            device: device,
            fontSize: fontSize,
            bundle: saverBundle
        )
        renderer.bloomEnabled = defs.bool(forKey: prefBloom)
        renderer.crtEnabled = defs.bool(forKey: prefCRT)
        renderer.isFullscreen = true
        metalRenderer = renderer

        // Capture and blur desktop for background
        if !isPreview && defs.bool(forKey: prefBlur) {
            captureAndBlurDesktop(device: device, renderer: renderer)
        }

        let view = MTKView(frame: bounds, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.autoresizingMask = [.width, .height]
        view.layer?.isOpaque = true
        view.delegate = self

        // Adapt frame rate to display refresh rate
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
        view.preferredFramesPerSecond = fps
        view.isPaused = false
        view.enableSetNeedsDisplay = false

        addSubview(view)
        mtkView = view

        recalculateGrid()
        lastFrameTime = CACurrentMediaTime()
    }

    override func stopAnimation() {
        super.stopAnimation()
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
        // No-op: MTKView drives the render loop at display refresh rate
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        metalRenderer?.resizeOffscreenTextures(width: Int(size.width), height: Int(size.height))
    }

    func draw(in view: MTKView) {
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
        renderer.render(in: view)
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateGrid()
    }

    // MARK: - Background capture

    private func captureAndBlurDesktop(device: MTLDevice, renderer: MetalRenderer) {
        // Get desktop wallpaper for the screen this saver runs on
        guard let screen = window?.screen ?? NSScreen.main,
              let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen),
              let nsImage = NSImage(contentsOf: wallpaperURL)
        else { return }

        // Render wallpaper into a bitmap at screen resolution (aspect-fill)
        let screenSize = screen.frame.size
        let scale = screen.backingScaleFactor
        let pixW = Int(screenSize.width * scale)
        let pixH = Int(screenSize.height * scale)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let drawCtx = CGContext(
            data: nil, width: pixW, height: pixH,
            bitsPerComponent: 8, bytesPerRow: pixW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        drawCtx.interpolationQuality = .high

        // Aspect-fill: scale to cover entire screen
        let imgW = nsImage.size.width
        let imgH = nsImage.size.height
        let fillScale = max(screenSize.width / imgW, screenSize.height / imgH)
        let drawW = imgW * fillScale * scale
        let drawH = imgH * fillScale * scale
        let drawX = (CGFloat(pixW) - drawW) / 2
        let drawY = (CGFloat(pixH) - drawH) / 2
        let drawRect = CGRect(x: drawX, y: drawY, width: drawW, height: drawH)

        var imgRect = CGRect(x: 0, y: 0, width: nsImage.size.width, height: nsImage.size.height)
        guard let cgImage = nsImage.cgImage(forProposedRect: &imgRect, context: nil, hints: nil) else { return }
        drawCtx.draw(cgImage, in: drawRect)
        guard let scaledCG = drawCtx.makeImage() else { return }

        // Blur with CIFilter
        let ciImage = CIImage(cgImage: scaledCG)
        let blurred = ciImage.applyingGaussianBlur(sigma: 30)
        let ciContext = CIContext()
        guard let blurredCG = ciContext.createCGImage(blurred, from: ciImage.extent) else { return }

        // Upload to Metal texture
        let texW = blurredCG.width
        let texH = blurredCG.height
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: texW, height: texH, mipmapped: false)
        texDesc.storageMode = .shared
        texDesc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: texDesc) else { return }

        guard let uploadCtx = CGContext(
            data: nil, width: texW, height: texH,
            bitsPerComponent: 8, bytesPerRow: texW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        uploadCtx.draw(blurredCG, in: CGRect(x: 0, y: 0, width: texW, height: texH))

        if let data = uploadCtx.data {
            texture.replace(
                region: MTLRegionMake2D(0, 0, texW, texH),
                mipmapLevel: 0, withBytes: data, bytesPerRow: texW * 4)
        }

        renderer.backgroundTexture = texture
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
        defs.set(fontSizes[fsIndex], forKey: prefFontSize)

        defs.set(bloomCheck?.state == .on, forKey: prefBloom)
        defs.set(crtCheck?.state == .on, forKey: prefCRT)
        defs.set(blurCheck?.state == .on, forKey: prefBlur)

        defs.synchronize()

        applyCharset()

        closeSheet()
    }

    @objc private func configSheetCancel(_ sender: Any?) {
        closeSheet()
    }

    private func closeSheet() {
        guard let sheet = configSheet else { return }
        if let parent = sheet.sheetParent {
            parent.endSheet(sheet)
        } else {
            sheet.close()
        }
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
