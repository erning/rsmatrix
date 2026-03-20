import AppKit
import QuartzCore

class MatrixView: NSView {
    let renderer = MatrixRenderer()
    private var simulation: OpaquePointer?
    private var displayLink: CADisplayLink?
    private var lastFrameTime: TimeInterval = 0
    private var gridWidth: UInt32 = 0
    private var gridHeight: UInt32 = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = true
        layer?.backgroundColor = NSColor.black.cgColor
        recalculateGrid()
        lastFrameTime = CACurrentMediaTime()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        displayLink?.invalidate()
        if let sim = simulation {
            rsmatrix_destroy(sim)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startDisplayLink()
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    // MARK: - CADisplayLink

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let dl = self.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }

    @objc private func displayLinkFired(_ sender: CADisplayLink) {
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let now = CACurrentMediaTime()
        let delta = now - lastFrameTime
        lastFrameTime = now
        let deltaMs = UInt32(min(delta * 1000.0, 1000.0))

        if let sim = simulation, deltaMs > 0 {
            rsmatrix_tick(sim, deltaMs)
        }

        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(bounds)

        guard let sim = simulation else { return }
        let grid = rsmatrix_get_grid(sim)
        renderer.render(
            context: context, grid: grid,
            width: rsmatrix_grid_width(sim),
            height: rsmatrix_grid_height(sim)
        )
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateGrid()
    }

    private func recalculateGrid() {
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

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers else { return }
        switch chars {
        case "c":
            if let sim = simulation { rsmatrix_clear(sim) }
        case "k":
            rsmatrix_set_charset(2)
        case "b":
            rsmatrix_set_charset(0)
        case "a":
            rsmatrix_set_charset(1)
        default:
            super.keyDown(with: event)
        }
    }
}
