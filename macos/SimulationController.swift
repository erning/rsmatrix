import QuartzCore

class SimulationController {
    private(set) var simulation: OpaquePointer?
    private(set) var gridWidth: UInt32 = 0
    private(set) var gridHeight: UInt32 = 0
    private var lastFrameTime: TimeInterval = 0

    func resetFrameTime() {
        lastFrameTime = CACurrentMediaTime()
    }

    @discardableResult
    func recalculateGrid(bounds: CGSize, cellSize: CGSize) -> Bool {
        let newWidth = max(UInt32(bounds.width / cellSize.width), 1)
        let newHeight = max(UInt32(bounds.height / cellSize.height), 1)

        guard newWidth != gridWidth || newHeight != gridHeight else { return false }

        gridWidth = newWidth
        gridHeight = newHeight

        if let sim = simulation {
            rsmatrix_resize(sim, gridWidth, gridHeight)
        } else {
            simulation = rsmatrix_create(gridWidth, gridHeight)
        }
        return true
    }

    func tick() -> UnsafePointer<RsMatrixCell>? {
        let now = CACurrentMediaTime()
        let delta = now - lastFrameTime
        lastFrameTime = now

        let deltaMs = UInt32(min(delta * 1000.0, 1000.0))
        guard let sim = simulation else { return nil }
        if deltaMs > 0 {
            rsmatrix_tick(sim, deltaMs)
        }
        return rsmatrix_get_grid(sim)
    }

    func clear() {
        if let sim = simulation {
            rsmatrix_clear(sim)
        }
    }

    func destroy() {
        if let sim = simulation {
            rsmatrix_destroy(sim)
            simulation = nil
        }
        gridWidth = 0
        gridHeight = 0
    }

    deinit {
        destroy()
    }
}
