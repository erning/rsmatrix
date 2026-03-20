import ScreenSaver

private let bundleID = "com.rsmatrix.MatrixSaver"
private let prefCharset = "Charset"   // "combined", "ascii", "kana"
private let prefFPS     = "FPS"       // Int 1-60

@objc(MatrixSaverView)
class MatrixSaverView: ScreenSaverView {
    private var simulation: OpaquePointer?
    private var lastFrameTime: TimeInterval = 0
    private var gridWidth: UInt32 = 0
    private var gridHeight: UInt32 = 0

    private var coreTextRenderer: MatrixRenderer?

    // Configure sheet
    private var configSheet: NSWindow?
    private var charsetPopup: NSPopUpButton?
    private var fpsSlider: NSSlider?
    private var fpsLabel: NSTextField?

    override var isFlipped: Bool { true }

    private var defaults: ScreenSaverDefaults {
        ScreenSaverDefaults(forModuleWithName: bundleID)!
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)

        let defs = defaults
        defs.register(defaults: [
            prefCharset: "combined",
            prefFPS: 30,
        ])

        let fps = defs.integer(forKey: prefFPS)
        animationTimeInterval = 1.0 / Double(max(fps, 1))
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

        let fps = defaults.integer(forKey: prefFPS)
        animationTimeInterval = 1.0 / Double(max(fps, 1))

        coreTextRenderer = MatrixRenderer(isPreview: isPreview)
        recalculateGrid()
        lastFrameTime = CACurrentMediaTime()
    }

    override func stopAnimation() {
        super.stopAnimation()
        coreTextRenderer = nil
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

        setNeedsDisplay(bounds)
    }

    override func draw(_ rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(bounds)

        guard let sim = simulation, let renderer = coreTextRenderer else { return }
        let grid = rsmatrix_get_grid(sim)
        renderer.render(
            context: context, grid: grid,
            width: rsmatrix_grid_width(sim),
            height: rsmatrix_grid_height(sim)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateGrid()
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
        let h: CGFloat = 150
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

        // Row 2 (top): Charset
        let y2: CGFloat = 105
        let csLabel = NSTextField(labelWithString: "Characters:")
        csLabel.frame = NSRect(x: labelX, y: y2, width: 85, height: 20)
        contentView.addSubview(csLabel)

        let cPopup = NSPopUpButton(frame: NSRect(x: controlX, y: y2 - 3, width: controlW, height: 26))
        cPopup.addItems(withTitles: ["Combined (Kana + ASCII)", "ASCII only", "Katakana only"])
        let curCharset = defaults.string(forKey: prefCharset) ?? "combined"
        switch curCharset {
        case "ascii": cPopup.selectItem(at: 1)
        case "kana":  cPopup.selectItem(at: 2)
        default:      cPopup.selectItem(at: 0)
        }
        contentView.addSubview(cPopup)
        charsetPopup = cPopup

        // Row 1: FPS
        let y1: CGFloat = 68
        let fLabel = NSTextField(labelWithString: "FPS:")
        fLabel.frame = NSRect(x: labelX, y: y1, width: 85, height: 20)
        contentView.addSubview(fLabel)

        let curFPS = max(defaults.integer(forKey: prefFPS), 1)
        let slider = NSSlider(value: Double(curFPS), minValue: 1, maxValue: 60,
                              target: self, action: #selector(fpsSliderChanged(_:)))
        slider.frame = NSRect(x: controlX, y: y1, width: controlW - 40, height: 20)
        contentView.addSubview(slider)
        fpsSlider = slider

        let valLabel = NSTextField(labelWithString: "\(curFPS)")
        valLabel.frame = NSRect(x: controlX + controlW - 35, y: y1, width: 35, height: 20)
        valLabel.alignment = .right
        contentView.addSubview(valLabel)
        fpsLabel = valLabel

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

    @objc private func fpsSliderChanged(_ sender: NSSlider) {
        fpsLabel?.stringValue = "\(Int(sender.doubleValue))"
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

        let fps = Int(fpsSlider?.doubleValue ?? 30)
        defs.set(fps, forKey: prefFPS)
        defs.synchronize()

        applyCharset()
        animationTimeInterval = 1.0 / Double(max(fps, 1))

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
        guard let renderer = coreTextRenderer else { return }
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
