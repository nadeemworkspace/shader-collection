//
//  MatrixRainRenderer.swift
//  Shader
//

import SwiftUI
import MetalKit

/// Mirrors `RainUniforms` in MatrixRain.metal; keep the field order in sync. Lengths are
/// in points.
nonisolated struct MatrixRainUniforms {
    var trailColor = SIMD4<Float>()
    var headColor = SIMD4<Float>()
    var viewport = SIMD2<Float>()
    var cell = SIMD2<Float>()
    var atlasCell = SIMD2<Float>()
    var pointScale: Float = 1
    var time: Float = 0
    var speed: Float = 0
    var density: Float = 0
    var brightness: Float = 0
    var farShare: Float = 0
    var softness: Float = 0
    var farBlur: Float = 0
    var glowAmount: Float = 0
    var atlasColumns: UInt32 = 0
    var scriptCount: UInt32 = 0
    var mirrored: UInt32 = 0
}

/// Mirrors `BlurStep` in MatrixRain.metal.
nonisolated struct MatrixBlurStep {
    var direction = SIMD2<Int32>()
    var radius: Int32 = 0
}

/// The look of the rain. Sizes and the glow were measured on the reference still,
/// taking one of its pixels as a point.
nonisolated enum MatrixDesign {
    /// Column and row pitch. Each glyph fills its cell.
    static let cell = SIMD2<Float>(24, 33)
    /// Height of a Latin capital or katakana, as a share of the row pitch (22 of 33).
    static let glyphHeight: CGFloat = 22.0 / 33.0
    static let mirrored = true
    /// Display RGB: pure green trails and white heads, the head a little hotter so it
    /// glows more.
    static let trailColor = SIMD4<Float>(0.05, 1, 0.05, 0)
    static let headColor = SIMD4<Float>(1.4, 1.4, 1.4, 0)
    /// A near trail's strength just behind its head; the glow brings it up to full.
    static let brightness: Float = 1.05
    /// Rows per second of the fastest near columns.
    static let speed: Float = 8
    static let density: Float = 0.8
    /// Far columns are dimmer, softer and slower, but the same size.
    static let farShare: Float = 0.25
    static let farBlur: Float = 1.5
    /// Extra mip levels for every glyph, softening their edges a touch like the
    /// reference's.
    static let softness: Float = 0.8
    /// The glow is the rain blurred by a Gaussian of this standard deviation (points),
    /// times `glowAmount`, added on top.
    static let glowSigma: Float = 11
    static let glowAmount: Float = 1.6
    /// Points per texel of the glow textures.
    static let glowTexel: Float = 2
}

// MARK: - GPU resources

/// Pipelines and the glyph atlas, shared by every rain view on screen.
nonisolated final class MatrixResources: @unchecked Sendable {
    static let pixelFormat = MTLPixelFormat.bgra8Unorm
    static let glowFormat = MTLPixelFormat.rgba16Float

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let glowSourcePipeline: MTLRenderPipelineState
    let blurPipeline: MTLRenderPipelineState
    let compositePipeline: MTLRenderPipelineState
    let atlas: MTLTexture
    let atlasCell: SIMD2<Float>
    let atlasColumns: Int
    /// Each entry is a script's first glyph and glyph count, listed as many times as
    /// the script's weight, so a glyph picks an entry at random.
    let scriptTable: [SIMD2<UInt32>]

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary(),
              let commandQueue = device.makeCommandQueue()
        else { throw CocoaError(.featureUnsupported) }

        func pipeline(_ fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "matrixVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        let scripts = MatrixScript.all
        let glyphs = MatrixGlyphAtlas(scripts: scripts,
                                      cellAspect: CGFloat(MatrixDesign.cell.x / MatrixDesign.cell.y),
                                      glyphHeight: MatrixDesign.glyphHeight)
        var table: [SIMD2<UInt32>] = []
        for (script, range) in zip(scripts, glyphs.ranges) where !range.isEmpty {
            table += Array(repeating: SIMD2(UInt32(range.lowerBound), UInt32(range.count)), count: script.weight)
        }
        guard !table.isEmpty else { throw CocoaError(.featureUnsupported) }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: glyphs.width, height: glyphs.height, mipmapped: true)
        textureDescriptor.usage = .shaderRead
        guard let atlas = device.makeTexture(descriptor: textureDescriptor) else {
            throw CocoaError(.featureUnsupported)
        }
        glyphs.pixels.withUnsafeBytes { bytes in
            atlas.replace(region: MTLRegionMake2D(0, 0, glyphs.width, glyphs.height),
                          mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: glyphs.bytesPerRow)
        }
        // Smaller glyphs, the glow's source and the blur of far columns come from the
        // mip levels.
        if let commandBuffer = commandQueue.makeCommandBuffer(), let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: atlas)
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        self.device = device
        self.commandQueue = commandQueue
        glowSourcePipeline = try pipeline("matrixGlowSource", format: Self.glowFormat)
        blurPipeline = try pipeline("matrixGlowBlur", format: Self.glowFormat)
        compositePipeline = try pipeline("matrixComposite", format: Self.pixelFormat)
        self.atlas = atlas
        atlasCell = SIMD2(Float(glyphs.cellWidth), Float(glyphs.cellHeight))
        atlasColumns = glyphs.columns
        scriptTable = table
    }

    @MainActor private static var loading: Task<MatrixResources?, Never>?

    /// Loads once (drawing the atlas takes a moment) and shares the result.
    @MainActor static func shared() async -> MatrixResources? {
        if let loading { return await loading.value }
        let task = Task.detached(priority: .userInitiated) { () -> MatrixResources? in
            do {
                return try MatrixResources()
            } catch {
                assertionFailure("Matrix resources failed to load: \(error)")
                return nil
            }
        }
        loading = task
        return await task.value
    }
}

// MARK: - View

/// Digital rain filling the view, in every size and orientation. Ignores touches: put
/// gestures on a SwiftUI view above it.
struct MatrixRainView: UIViewRepresentable {
    /// Multiplies the size of the glyphs and their glow.
    var scale: CGFloat = 1
    var framesPerSecond = 60

    func makeCoordinator() -> MatrixRainRenderer {
        MatrixRainRenderer()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = MatrixResources.pixelFormat
        view.framebufferOnly = true
        view.backgroundColor = .black
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let renderer = context.coordinator
        renderer.scale = Float(scale)
        renderer.setAnimating(!context.environment.accessibilityReduceMotion, framesPerSecond: framesPerSecond)
    }

    static func dismantleUIView(_ view: MTKView, coordinator: MatrixRainRenderer) {
        view.isPaused = true
    }
}

final class MatrixRainRenderer: NSObject, MTKViewDelegate {
    var scale: Float = 1

    private weak var view: MTKView?
    private var resources: MatrixResources?
    /// The glow's source and its blur, swapped between passes.
    private var glowTextures: [MTLTexture] = []
    private let start = CACurrentMediaTime()
    /// Set while the rain is held still (Reduce Motion).
    private var frozenTime: Double?

    /// Wraps the clock so the shader's float time keeps its precision.
    private static let timeWrap: Double = 3600

    func attach(to view: MTKView) {
        self.view = view
        Task { [weak self] in
            guard let resources = await MatrixResources.shared() else { return }
            self?.resources = resources
            self?.view?.setNeedsDisplay()
        }
    }

    /// Runs the rain at `framesPerSecond`, or holds it still and only redraws on resize.
    func setAnimating(_ animating: Bool, framesPerSecond: Int) {
        guard let view else { return }
        view.preferredFramesPerSecond = framesPerSecond
        if animating {
            frozenTime = nil
            view.enableSetNeedsDisplay = false
            view.isPaused = false
        } else {
            if frozenTime == nil { frozenTime = currentTime }
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.setNeedsDisplay()
        }
    }

    private var currentTime: Double {
        frozenTime ?? (CACurrentMediaTime() - start).truncatingRemainder(dividingBy: Self.timeWrap)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        let width = Int(view.drawableSize.width)
        let height = Int(view.drawableSize.height)
        guard let resources, width > 0, height > 0, view.bounds.width > 0,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = resources.commandQueue.makeCommandBuffer()
        else { return }

        let pointScale = Float(view.drawableSize.width / view.bounds.width)
        let glowTexel = MatrixDesign.glowTexel * scale
        fitGlowTextures(width: Int((Float(width) / (pointScale * glowTexel)).rounded(.up)),
                        height: Int((Float(height) / (pointScale * glowTexel)).rounded(.up)),
                        device: resources.device)
        guard glowTextures.count == 2 else { return }

        var scripts = resources.scriptTable
        var uniforms = MatrixRainUniforms(
            trailColor: MatrixDesign.trailColor,
            headColor: MatrixDesign.headColor,
            cell: MatrixDesign.cell * scale,
            atlasCell: resources.atlasCell,
            time: Float(currentTime),
            speed: MatrixDesign.speed,
            density: MatrixDesign.density,
            brightness: MatrixDesign.brightness,
            farShare: MatrixDesign.farShare,
            softness: MatrixDesign.softness,
            farBlur: MatrixDesign.farBlur,
            glowAmount: MatrixDesign.glowAmount,
            atlasColumns: UInt32(resources.atlasColumns),
            scriptCount: UInt32(scripts.count),
            mirrored: MatrixDesign.mirrored ? 1 : 0
        )

        func encodeRain(_ encoder: MTLRenderCommandEncoder, targetWidth: Int, targetHeight: Int) {
            uniforms.viewport = SIMD2(Float(targetWidth), Float(targetHeight))
            uniforms.pointScale = pointScale * Float(targetWidth) / Float(width)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MatrixRainUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&scripts, length: MemoryLayout<SIMD2<UInt32>>.stride * scripts.count, index: 1)
            encoder.setFragmentTexture(resources.atlas, index: 0)
        }

        // The glow: the rain at low resolution, blurred across and then down.
        let source = glowTextures[0]
        let across = glowTextures[1]
        draw(into: source, commandBuffer, resources.glowSourcePipeline) {
            encodeRain($0, targetWidth: source.width, targetHeight: source.height)
        }
        var weights = Self.gaussianWeights(sigma: MatrixDesign.glowSigma * scale / glowTexel)
        for (input, output, direction) in [(source, across, SIMD2<Int32>(1, 0)), (across, source, SIMD2<Int32>(0, 1))] {
            draw(into: output, commandBuffer, resources.blurPipeline) { encoder in
                var step = MatrixBlurStep(direction: direction, radius: Int32(weights.count - 1))
                encoder.setFragmentBytes(&step, length: MemoryLayout<MatrixBlurStep>.stride, index: 0)
                encoder.setFragmentBytes(&weights, length: MemoryLayout<Float>.stride * weights.count, index: 1)
                encoder.setFragmentTexture(input, index: 0)
            }
        }

        // The sharp rain plus the glow, into the drawable.
        pass.colorAttachments[0].loadAction = .dontCare
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(resources.compositePipeline)
            encodeRain(encoder, targetWidth: width, targetHeight: height)
            encoder.setFragmentTexture(source, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// One full-target triangle into `target`.
    private func draw(into target: MTLTexture, _ commandBuffer: MTLCommandBuffer, _ pipeline: MTLRenderPipelineState,
                      encode: (MTLRenderCommandEncoder) -> Void) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encode(encoder)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func fitGlowTextures(width: Int, height: Int, device: MTLDevice) {
        guard glowTextures.first?.width != width || glowTextures.first?.height != height else { return }
        glowTextures = (0..<2).compactMap { _ in
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: MatrixResources.glowFormat, width: max(width, 1), height: max(height, 1), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
    }

    /// Weights from the centre tap outwards, adding up to 1 over both sides, out to
    /// three standard deviations.
    private static func gaussianWeights(sigma: Float) -> [Float] {
        let radius = max(Int((3 * sigma).rounded(.up)), 1)
        let weights = (0...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = weights[0] + 2 * weights.dropFirst().reduce(0, +)
        return weights.map { $0 / total }
    }
}
