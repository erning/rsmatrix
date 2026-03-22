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
// The standalone app (make run-app) is the recommended alternative on Sonoma+.

@objc(MatrixSaverView)
class MatrixSaverView: ScreenSaverView, MTKViewDelegate {
    private var simulation: OpaquePointer?
    private var lastFrameTime: TimeInterval = 0
    private var gridWidth: UInt32 = 0
    private var gridHeight: UInt32 = 0

    private var mtkView: MTKView?
    private var metalRenderer: MetalRenderer?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
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

        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let saverBundle = Bundle(for: MatrixSaverView.self)
        let screen = window?.screen ?? NSScreen.main
        let renderer = MetalRenderer(
            device: device,
            fontSize: 14,
            bundle: saverBundle,
            scaleFactor: screen?.backingScaleFactor
        )
        renderer.bloomEnabled = true
        renderer.crtEnabled = true
        renderer.isFullscreen = true
        metalRenderer = renderer

        renderer.backgroundTexture = MetalRenderer.captureBlurredDesktop(
            device: device, screen: screen)

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

    // MARK: - Configure sheet (disabled)

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

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
