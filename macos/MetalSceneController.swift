import MetalKit
import AppKit

class MetalSceneController {
    let mtkView: MTKView
    let metalRenderer: MetalRenderer
    let simulation = SimulationController()

    init(device: MTLDevice, config: RenderConfig) {
        metalRenderer = MetalRenderer(
            device: device,
            fontSize: config.fontSize,
            bundle: config.shaderBundle,
            scaleFactor: config.scaleFactor
        )
        metalRenderer.bloomEnabled = config.bloomEnabled
        metalRenderer.crtEnabled = config.crtEnabled
        metalRenderer.backgroundBlurEnabled = config.backgroundBlurEnabled

        mtkView = MTKView(frame: .zero, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 1)
    }

    func advanceFrame() {
        guard let grid = simulation.tick() else { return }
        metalRenderer.updateInstances(
            grid: grid,
            width: simulation.gridWidth,
            height: simulation.gridHeight
        )
    }

    func render(in view: MTKView) {
        metalRenderer.render(in: view)
    }

    func resizeOffscreenTextures(size: CGSize) {
        metalRenderer.resizeOffscreenTextures(
            width: Int(size.width), height: Int(size.height))
    }

    func recalculateGrid(bounds: CGSize) {
        simulation.recalculateGrid(
            bounds: bounds, cellSize: metalRenderer.cellSize)
    }

    func updatePreferredFrameRate(for screen: NSScreen?) {
        mtkView.preferredFramesPerSecond = MetalRenderer.displayRefreshRate(
            for: screen ?? NSScreen.main)
    }

    func captureBlurredDesktop(screen: NSScreen?) {
        metalRenderer.backgroundTexture = MetalRenderer.captureBlurredDesktop(
            device: mtkView.device!, screen: screen,
            sigma: Double(metalRenderer.blurSigma))
    }

    func tearDown() {
        simulation.destroy()
    }
}
