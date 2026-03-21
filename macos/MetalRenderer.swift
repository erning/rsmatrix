import Metal
import MetalKit
import AppKit
import CoreText
import CoreImage

// MARK: - Uniform structs (must match Metal shader layout)

struct GridUniforms {
    var viewSize: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var uvCellSize: SIMD2<Float>
}

struct CompositeUniforms {
    var bloomIntensity: Float
    var scanlineIntensity: Float
    var distortionStrength: Float
    var vignetteStrength: Float
    var viewHeightPixels: Float
    var backgroundAlpha: Float
    var hasBackground: Float
}

struct CellInstance {
    var posX: Float
    var posY: Float
    var uvX: Float
    var uvY: Float
    var r: Float
    var g: Float
    var b: Float
}

// MARK: - MetalRenderer

class MetalRenderer {

    // All codepoints that may appear in the grid (62 ASCII + 63 katakana = 125)
    private static let allCodepoints: [UInt32] = {
        var cp: [UInt32] = []
        for c in 0xFF61...0xFF9F { cp.append(UInt32(c)) }        // half-width kana
        for c: UInt32 in 0x41...0x5A { cp.append(c) }            // A-Z
        for c: UInt32 in 0x61...0x7A { cp.append(c) }            // a-z
        for c: UInt32 in 0x30...0x39 { cp.append(c) }            // 0-9
        return cp
    }()

    // Metal objects
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    // Pipeline states
    private let gridPipeline: MTLRenderPipelineState
    private let phosphorPipeline: MTLRenderPipelineState
    private let bloomBrightPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let blitPipeline: MTLRenderPipelineState

    // Blit textures for CoreText rendering path (triple-buffered)
    private var blitTextures: [MTLTexture] = []
    private var blitTextureIndex = 0
    var blitTexture: MTLTexture? { blitTextures.isEmpty ? nil : blitTextures[blitTextureIndex] }

    // Glyph atlas
    private var glyphAtlas: MTLTexture!
    private var glyphUVs: [UInt32: SIMD2<Float>] = [:]
    private var uvCellSize: SIMD2<Float> = .zero

    // Font
    private(set) var cellSize: CGSize
    private var ctFont: CTFont
    private var fontSize: CGFloat

    // Instance buffers (triple-buffered)
    private var instanceBuffers: [MTLBuffer] = []
    private var maxInstances: Int = 0
    private var currentBufferIndex = 0
    private let inflightSemaphore = DispatchSemaphore(value: 3)
    private var visibleCellCount = 0

    // Offscreen textures
    private var gridTexture: MTLTexture?
    private var persistenceTextures: [MTLTexture?] = [nil, nil]
    private var persistenceIndex = 0
    private var bloomTexture: MTLTexture?
    private var bloomTempTexture: MTLTexture?
    private var drawableWidth = 0
    private var drawableHeight = 0

    // Effect settings
    var bloomEnabled = true
    var crtEnabled = true
    var backgroundBlurEnabled = true
    var isFullscreen = false
    var backgroundTexture: MTLTexture?
    var phosphorDecay: Float = 0.92
    var bloomThreshold: Float = 0.4
    var bloomIntensityValue: Float = 0.5
    var scanlineIntensity: Float = 0.15
    var distortionStrength: Float = 0.05
    var vignetteStrength: Float = 0.3

    // MARK: - Init

    init(device: MTLDevice, fontSize: CGFloat = 14, bundle: Bundle? = nil) {
        self.device = device
        self.fontSize = fontSize
        self.commandQueue = device.makeCommandQueue()!

        // Font setup
        let font = NSFont(name: "Menlo", size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.ctFont = font as CTFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = NSAttributedString(string: "W", attributes: attrs).size()
        self.cellSize = CGSize(width: ceil(size.width), height: ceil(size.height))

        // Compile shaders
        let library: MTLLibrary
        if let bundle = bundle,
           let libURL = bundle.url(forResource: "default", withExtension: "metallib") {
            library = try! device.makeLibrary(URL: libURL)
        } else {
            library = device.makeDefaultLibrary()!
        }

        // Pipeline states
        let offscreenFormat: MTLPixelFormat = .rgba16Float
        let drawableFormat: MTLPixelFormat = .bgra8Unorm
        self.gridPipeline = Self.makePipeline(device: device, library: library,
            vertex: "grid_vertex", fragment: "grid_fragment", format: offscreenFormat)
        self.phosphorPipeline = Self.makePipeline(device: device, library: library,
            vertex: "fullscreen_vertex", fragment: "phosphor_fragment", format: offscreenFormat)
        self.bloomBrightPipeline = Self.makePipeline(device: device, library: library,
            vertex: "fullscreen_vertex", fragment: "bloom_bright_fragment", format: offscreenFormat)
        self.blurPipeline = Self.makePipeline(device: device, library: library,
            vertex: "fullscreen_vertex", fragment: "blur_fragment", format: offscreenFormat)
        self.compositePipeline = Self.makePipeline(device: device, library: library,
            vertex: "fullscreen_vertex", fragment: "composite_fragment", format: drawableFormat)
        self.blitPipeline = Self.makePipeline(device: device, library: library,
            vertex: "fullscreen_vertex", fragment: "blit_fragment", format: drawableFormat)

        // Build glyph atlas
        buildAtlas(scaleFactor: NSScreen.main?.backingScaleFactor ?? 2.0)
    }

    // MARK: - Pipeline creation

    private static func makePipeline(
        device: MTLDevice, library: MTLLibrary,
        vertex: String, fragment: String, format: MTLPixelFormat
    ) -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: vertex)
        desc.fragmentFunction = library.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = format
        return try! device.makeRenderPipelineState(descriptor: desc)
    }

    // MARK: - Glyph atlas

    func buildAtlas(scaleFactor: CGFloat) {
        let cellW = cellSize.width
        let cellH = cellSize.height
        let cellPixW = Int(ceil(cellW * scaleFactor))
        let cellPixH = Int(ceil(cellH * scaleFactor))

        let codepoints = Self.allCodepoints
        let cols = 16
        let rows = (codepoints.count + cols - 1) / cols

        let atlasPixW = cols * cellPixW
        let atlasPixH = rows * cellPixH

        // Create bitmap context (bottom-left origin, RGBA premultiplied)
        let bytesPerRow = atlasPixW * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: nil, width: atlasPixW, height: atlasPixH,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else { fatalError("Failed to create atlas CGContext") }

        // Scale for Retina; drawing coords are in points
        ctx.scaleBy(x: scaleFactor, y: scaleFactor)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.setTextDrawingMode(.fill)

        let descent = CTFontGetDescent(ctFont)

        // Glyph cache for font fallback
        var resolvedGlyphs: [(glyph: CGGlyph, font: CTFont, ascent: CGFloat)] = []
        for cp in codepoints {
            resolvedGlyphs.append(resolveGlyph(for: cp))
        }

        // Draw each glyph into its atlas cell
        for (i, cp) in codepoints.enumerated() {
            let col = i % cols
            let row = i / cols
            let info = resolvedGlyphs[i]

            let baselineX = CGFloat(col) * cellW
            let baselineY = CGFloat(row) * cellH + descent

            var glyph = info.glyph
            var position = CGPoint(x: baselineX, y: baselineY)
            CTFontDrawGlyphs(info.font, &glyph, &position, 1, ctx)

            // Record UV coordinates
            let u = Float(col * cellPixW) / Float(atlasPixW)
            let v = 1.0 - Float((row + 1) * cellPixH) / Float(atlasPixH)
            glyphUVs[cp] = SIMD2<Float>(u, v)
        }

        uvCellSize = SIMD2<Float>(
            Float(cellPixW) / Float(atlasPixW),
            Float(cellPixH) / Float(atlasPixH)
        )

        // Convert to CGImage to get top-down pixel data (matching Metal texture layout)
        guard let cgImage = ctx.makeImage(),
              let dataProvider = cgImage.dataProvider,
              let imageData = dataProvider.data
        else { fatalError("Failed to extract atlas image data") }

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: atlasPixW, height: atlasPixH, mipmapped: false)
        texDesc.storageMode = .shared
        texDesc.usage = .shaderRead
        glyphAtlas = device.makeTexture(descriptor: texDesc)!

        let imageBytes = CFDataGetBytePtr(imageData)!
        glyphAtlas.replace(
            region: MTLRegionMake2D(0, 0, atlasPixW, atlasPixH),
            mipmapLevel: 0, withBytes: imageBytes, bytesPerRow: bytesPerRow)
    }

    private func resolveGlyph(for codepoint: UInt32) -> (glyph: CGGlyph, font: CTFont, ascent: CGFloat) {
        guard let scalar = Unicode.Scalar(codepoint) else {
            return (0, ctFont, CTFontGetAscent(ctFont))
        }

        var utf16: [UniChar] = []
        UTF16.encode(scalar, into: { utf16.append($0) })
        var g = CGGlyph(0)

        // Try primary font
        if CTFontGetGlyphsForCharacters(ctFont, &utf16, &g, utf16.count) {
            return (g, ctFont, CTFontGetAscent(ctFont))
        }

        // Fallback
        let str = String(Character(scalar)) as CFString
        let range = CFRangeMake(0, CFStringGetLength(str))
        let fallback = CTFontCreateForString(ctFont, str, range)
        CTFontGetGlyphsForCharacters(fallback, &utf16, &g, utf16.count)
        return (g, fallback, CTFontGetAscent(fallback))
    }

    // MARK: - Font size change

    func rebuildForFontSize(_ newSize: CGFloat, scaleFactor: CGFloat) {
        fontSize = newSize
        let font = NSFont(name: "Menlo", size: newSize)
            ?? NSFont.monospacedSystemFont(ofSize: newSize, weight: .regular)
        ctFont = font as CTFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = NSAttributedString(string: "W", attributes: attrs).size()
        cellSize = CGSize(width: ceil(size.width), height: ceil(size.height))
        glyphUVs.removeAll()
        buildAtlas(scaleFactor: scaleFactor)
    }

    // MARK: - Offscreen textures

    func resizeOffscreenTextures(width: Int, height: Int) {
        guard width > 0 && height > 0 else { return }
        guard width != drawableWidth || height != drawableHeight else { return }
        drawableWidth = width
        drawableHeight = height

        let offscreenFormat: MTLPixelFormat = .rgba16Float

        gridTexture = makeTexture(width: width, height: height, format: offscreenFormat)
        persistenceTextures[0] = makeTexture(width: width, height: height, format: offscreenFormat)
        persistenceTextures[1] = makeTexture(width: width, height: height, format: offscreenFormat)
        persistenceIndex = 0

        let bw = max(width / 2, 1)
        let bh = max(height / 2, 1)
        bloomTexture = makeTexture(width: bw, height: bh, format: offscreenFormat)
        bloomTempTexture = makeTexture(width: bw, height: bh, format: offscreenFormat)

        // Clear persistence textures to avoid garbage on first frame
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        for tex in persistenceTextures {
            guard let tex = tex else { continue }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
                enc.endEncoding()
            }
        }
        cb.commit()
    }

    private func makeTexture(width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.storageMode = .private
        desc.usage = [.renderTarget, .shaderRead]
        return device.makeTexture(descriptor: desc)!
    }

    // MARK: - Instance buffer management

    private func ensureInstanceCapacity(_ count: Int) {
        guard count > maxInstances else { return }
        maxInstances = count
        let byteCount = count * MemoryLayout<CellInstance>.stride
        instanceBuffers = (0..<3).map { _ in
            device.makeBuffer(length: byteCount, options: .storageModeShared)!
        }
    }

    // MARK: - Update instances from grid

    func updateInstances(grid: UnsafePointer<RsMatrixCell>, width: UInt32, height: UInt32) {
        let totalCells = Int(width) * Int(height)
        ensureInstanceCapacity(totalCells)

        let buffer = instanceBuffers[currentBufferIndex]
        let ptr = buffer.contents().bindMemory(to: CellInstance.self, capacity: totalCells)
        var count = 0

        let cw = Float(cellSize.width)
        let ch = Float(cellSize.height)

        for row in 0..<Int(height) {
            for col in 0..<Int(width) {
                let cell = grid[row * Int(width) + col]
                if cell.r == 0 && cell.g == 0 && cell.b == 0 { continue }

                guard let uv = glyphUVs[cell.codepoint] else { continue }

                ptr[count] = CellInstance(
                    posX: Float(col) * cw,
                    posY: Float(row) * ch,
                    uvX: uv.x,
                    uvY: uv.y,
                    r: Float(cell.r) / 255.0,
                    g: Float(cell.g) / 255.0,
                    b: Float(cell.b) / 255.0
                )
                count += 1
            }
        }
        visibleCellCount = count
    }

    // MARK: - Multi-pass render

    func render(in view: MTKView) {
        // Lazy texture creation (drawableSizeWillChange may not fire before first draw)
        let dw = Int(view.drawableSize.width)
        let dh = Int(view.drawableSize.height)
        if gridTexture == nil && dw > 0 && dh > 0 {
            resizeOffscreenTextures(width: dw, height: dh)
        }

        guard let gridTex = gridTexture,
              let persA = persistenceTextures[0],
              let persB = persistenceTextures[1],
              let bloomTex = bloomTexture,
              let bloomTmp = bloomTempTexture
        else { return }

        let blurActive = backgroundBlurEnabled && !isFullscreen
        let bgAlpha = blurActive ? 0.75 : 1.0
        view.clearColor = MTLClearColorMake(0, 0, 0, bgAlpha)

        guard let compositeRPD = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        inflightSemaphore.wait()
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }

        let viewW = Float(view.bounds.width)
        let viewH = Float(view.bounds.height)

        // ---- Pass 1: Grid → gridTexture ----
        if visibleCellCount > 0 && !instanceBuffers.isEmpty {
            let instanceBuffer = instanceBuffers[currentBufferIndex]
            currentBufferIndex = (currentBufferIndex + 1) % 3
            encodeGridPass(commandBuffer: commandBuffer, target: gridTex,
                           instanceBuffer: instanceBuffer, viewSize: SIMD2(viewW, viewH))
        } else {
            // Clear grid texture when nothing to draw
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = gridTex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                enc.endEncoding()
            }
        }

        // ---- Pass 2: Phosphor persistence ----
        let prevPers = persistenceIndex == 0 ? persB : persA
        let currPers = persistenceIndex == 0 ? persA : persB
        persistenceIndex = 1 - persistenceIndex

        encodePhosphorPass(commandBuffer: commandBuffer,
                           freshTex: gridTex, prevTex: prevPers, target: currPers)

        // ---- Pass 3: Bloom (if enabled) ----
        if bloomEnabled {
            encodeBloomPasses(commandBuffer: commandBuffer,
                              scene: currPers, bloomTex: bloomTex, bloomTmp: bloomTmp)
        }

        // ---- Pass 4: Composite → drawable ----
        encodeCompositePass(commandBuffer: commandBuffer, rpd: compositeRPD,
                            scene: currPers, bloom: bloomTex,
                            drawableSize: view.drawableSize)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Render pass encoders

    private func encodeGridPass(
        commandBuffer: MTLCommandBuffer, target: MTLTexture,
        instanceBuffer: MTLBuffer, viewSize: SIMD2<Float>
    ) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(gridPipeline)
        enc.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1))

        enc.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        var uniforms = GridUniforms(
            viewSize: viewSize,
            cellSize: SIMD2(Float(cellSize.width), Float(cellSize.height)),
            uvCellSize: uvCellSize
        )
        enc.setVertexBytes(&uniforms, length: MemoryLayout<GridUniforms>.size, index: 1)
        enc.setFragmentTexture(glyphAtlas, index: 0)

        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                           vertexCount: 4, instanceCount: visibleCellCount)
        enc.endEncoding()
    }

    private func encodePhosphorPass(
        commandBuffer: MTLCommandBuffer,
        freshTex: MTLTexture, prevTex: MTLTexture, target: MTLTexture
    ) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(phosphorPipeline)
        enc.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(target.width), height: Double(target.height), znear: 0, zfar: 1))

        enc.setFragmentTexture(freshTex, index: 0)
        enc.setFragmentTexture(prevTex, index: 1)
        var decay = phosphorDecay
        enc.setFragmentBytes(&decay, length: MemoryLayout<Float>.size, index: 0)

        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func encodeBloomPasses(
        commandBuffer: MTLCommandBuffer,
        scene: MTLTexture, bloomTex: MTLTexture, bloomTmp: MTLTexture
    ) {
        // Bright pass → bloomTex
        do {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = bloomTex
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store

            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(bloomBrightPipeline)
            enc.setViewport(MTLViewport(originX: 0, originY: 0,
                width: Double(bloomTex.width), height: Double(bloomTex.height), znear: 0, zfar: 1))
            enc.setFragmentTexture(scene, index: 0)
            var threshold = bloomThreshold
            enc.setFragmentBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }

        // Horizontal blur → bloomTmp
        do {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = bloomTmp
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store

            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(blurPipeline)
            enc.setViewport(MTLViewport(originX: 0, originY: 0,
                width: Double(bloomTmp.width), height: Double(bloomTmp.height), znear: 0, zfar: 1))
            enc.setFragmentTexture(bloomTex, index: 0)
            var dir = SIMD2<Float>(1.0 / Float(bloomTex.width), 0)
            enc.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }

        // Vertical blur → bloomTex (reuse)
        do {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = bloomTex
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store

            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(blurPipeline)
            enc.setViewport(MTLViewport(originX: 0, originY: 0,
                width: Double(bloomTex.width), height: Double(bloomTex.height), znear: 0, zfar: 1))
            enc.setFragmentTexture(bloomTmp, index: 0)
            var dir = SIMD2<Float>(0, 1.0 / Float(bloomTmp.height))
            enc.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
    }

    private func encodeCompositePass(
        commandBuffer: MTLCommandBuffer, rpd: MTLRenderPassDescriptor,
        scene: MTLTexture, bloom: MTLTexture, drawableSize: CGSize
    ) {
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(compositePipeline)
        enc.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(drawableSize.width), height: Double(drawableSize.height), znear: 0, zfar: 1))

        enc.setFragmentTexture(scene, index: 0)
        enc.setFragmentTexture(bloom, index: 1)
        enc.setFragmentTexture(backgroundTexture ?? scene, index: 2)

        let blurActive = backgroundBlurEnabled && !isFullscreen
        var uniforms = CompositeUniforms(
            bloomIntensity: bloomEnabled ? bloomIntensityValue : 0,
            scanlineIntensity: crtEnabled ? scanlineIntensity : 0,
            distortionStrength: crtEnabled ? distortionStrength : 0,
            vignetteStrength: crtEnabled ? vignetteStrength : 0,
            viewHeightPixels: Float(drawableSize.height),
            backgroundAlpha: blurActive ? 0.75 : 1.0,
            hasBackground: backgroundTexture != nil ? 1.0 : 0.0
        )
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.size, index: 0)

        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    // MARK: - CoreText blit support

    func ensureBlitTexture(width: Int, height: Int) {
        if let tex = blitTextures.first, tex.width == width, tex.height == height { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.storageMode = .shared
        desc.usage = .shaderRead
        blitTextures = (0..<3).compactMap { _ in device.makeTexture(descriptor: desc) }
        blitTextureIndex = 0
    }

    func advanceBlitTexture() {
        if !blitTextures.isEmpty {
            blitTextureIndex = (blitTextureIndex + 1) % blitTextures.count
        }
    }

    func renderBlit(in view: MTKView) {
        guard let blitTex = blitTexture,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = commandQueue.makeCommandBuffer()
        else { return }

        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(blitPipeline)
        enc.setViewport(MTLViewport(originX: 0, originY: 0,
            width: Double(view.drawableSize.width),
            height: Double(view.drawableSize.height), znear: 0, zfar: 1))
        enc.setFragmentTexture(blitTex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cb.present(drawable)
        cb.commit()
    }

    // MARK: - Display refresh rate

    static func displayRefreshRate(for screen: NSScreen?) -> Int {
        guard let screen = screen else { return 60 }
        let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")]
        if let displayID = screenNumber as? CGDirectDisplayID,
           let mode = CGDisplayCopyDisplayMode(displayID),
           mode.refreshRate > 0 {
            return Int(mode.refreshRate)
        }
        let fps = screen.maximumFramesPerSecond
        return fps > 0 ? fps : 60
    }

    // MARK: - Wallpaper capture

    private static let ciContext = CIContext()

    static func captureBlurredDesktop(device: MTLDevice, screen: NSScreen?) -> MTLTexture? {
        guard let screen = screen,
              let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen),
              let nsImage = NSImage(contentsOf: wallpaperURL)
        else { return nil }

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
        ) else { return nil }
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
        guard let cgImage = nsImage.cgImage(forProposedRect: &imgRect, context: nil, hints: nil) else { return nil }
        drawCtx.draw(cgImage, in: drawRect)
        guard let scaledCG = drawCtx.makeImage() else { return nil }

        // Blur with CIFilter
        let ciImage = CIImage(cgImage: scaledCG)
        let blurred = ciImage.applyingGaussianBlur(sigma: 30)
        guard let blurredCG = ciContext.createCGImage(blurred, from: ciImage.extent) else { return nil }

        // Upload to Metal texture
        let texW = blurredCG.width
        let texH = blurredCG.height
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: texW, height: texH, mipmapped: false)
        texDesc.storageMode = .shared
        texDesc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: texDesc) else { return nil }

        guard let uploadCtx = CGContext(
            data: nil, width: texW, height: texH,
            bitsPerComponent: 8, bytesPerRow: texW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        uploadCtx.draw(blurredCG, in: CGRect(x: 0, y: 0, width: texW, height: texH))

        if let data = uploadCtx.data {
            texture.replace(
                region: MTLRegionMake2D(0, 0, texW, texH),
                mipmapLevel: 0, withBytes: data, bytesPerRow: texW * 4)
        }

        return texture
    }
}
