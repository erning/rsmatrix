import ScreenSaver

@objc(MatrixSaverView)
class MatrixSaverView: ScreenSaverView {
    private var simulation: OpaquePointer?
    private var renderer: MatrixRenderer?
    private var lastFrameTime: TimeInterval = 0
    private var gridWidth: UInt32 = 0
    private var gridHeight: UInt32 = 0

    override var isFlipped: Bool { true }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func startAnimation() {
        super.startAnimation()
        renderer = MatrixRenderer(isPreview: isPreview)
        recalculateGrid()
        lastFrameTime = CACurrentMediaTime()
    }

    override func stopAnimation() {
        super.stopAnimation()
        if let sim = simulation {
            rsmatrix_destroy(sim)
            simulation = nil
        }
        renderer = nil
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

        // Black background
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(bounds)

        guard let sim = simulation, let renderer = renderer else { return }

        let grid = rsmatrix_get_grid(sim)
        let width = rsmatrix_grid_width(sim)
        let height = rsmatrix_grid_height(sim)

        renderer.render(context: context, grid: grid, width: width, height: height, bounds: bounds)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recalculateGrid()
    }

    private func recalculateGrid() {
        guard let renderer = renderer else { return }

        let cellSize = renderer.cellSize
        let newWidth = max(UInt32(bounds.width / cellSize.width), 1)
        let newHeight = max(UInt32(bounds.height / cellSize.height), 1)

        if newWidth == gridWidth && newHeight == gridHeight {
            return
        }

        gridWidth = newWidth
        gridHeight = newHeight

        if let sim = simulation {
            rsmatrix_resize(sim, gridWidth, gridHeight)
        } else {
            simulation = rsmatrix_create(gridWidth, gridHeight)
        }
    }
}
