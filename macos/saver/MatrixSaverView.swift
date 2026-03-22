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
    private var scene: MetalSceneController?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Animation

    override func startAnimation() {
        super.startAnimation()
        guard !isPreview else { return }
        tearDown()

        guard let device = MTLCreateSystemDefaultDevice() else { return }

        var config = RenderConfig.screensaver
        config.shaderBundle = Bundle(for: MatrixSaverView.self)
        config.scaleFactor = (window?.screen ?? NSScreen.main)?.backingScaleFactor
        scene = MetalSceneController(device: device, config: config)

        guard let scene = scene else { return }
        scene.captureBlurredDesktop(screen: window?.screen ?? NSScreen.main)

        scene.mtkView.frame = bounds
        scene.mtkView.isPaused = true
        scene.mtkView.enableSetNeedsDisplay = false
        scene.mtkView.autoresizingMask = [.width, .height]
        scene.mtkView.layer?.isOpaque = true
        scene.mtkView.delegate = self
        addSubview(scene.mtkView)

        let fps = MetalRenderer.displayRefreshRate(for: window?.screen ?? NSScreen.main)
        animationTimeInterval = 1.0 / Double(fps)

        scene.recalculateGrid(bounds: bounds.size)
        scene.simulation.resetFrameTime()
    }

    override func stopAnimation() {
        super.stopAnimation()
        tearDown()
    }

    private func tearDown() {
        scene?.mtkView.removeFromSuperview()
        scene?.tearDown()
        scene = nil
    }

    override func animateOneFrame() {
        scene?.advanceFrame()
        scene?.mtkView.draw()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        scene?.resizeOffscreenTextures(size: size)
    }

    func draw(in view: MTKView) {
        scene?.render(in: view)
    }

    // MARK: - Resize

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scene?.recalculateGrid(bounds: CGSize(width: newSize.width, height: newSize.height))
    }

    // MARK: - Configure sheet (disabled)

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
