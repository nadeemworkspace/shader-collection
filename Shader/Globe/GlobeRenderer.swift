//
//  GlobeRenderer.swift
//  Shader
//

import SwiftUI
import MetalKit

/// Mirrors `GlobeUniforms` in Globe.metal; keep the field order in sync. Vectors come
/// first so both sides lay the struct out identically.
nonisolated struct GlobeUniforms {
    var eye = SIMD3<Float>()
    var right = SIMD3<Float>()
    var up = SIMD3<Float>()
    var back = SIMD3<Float>()
    var selectionCenter = SIMD3<Float>()
    var selectionEast = SIMD3<Float>()
    var selectionNorth = SIMD3<Float>()
    var viewport = SIMD2<Float>()
    var focus = SIMD2<Float>()
    var selectionScreen = SIMD2<Float>()
    var focal: Float = 1
    var scale: Float = 1
    var globeRadius: Float = 0
    var rowStep: Float = 0
    var landLevel: Float = 0
    var oceanLevel: Float = 0
    var highlightLevel: Float = 0
    var countryLevel: Float = 0
    var boost: Float = 0
    var opacity: Float = 0
    var selectionSpacing: Float = 1
    var reveal: Float = 0
    var revealRadius: Float = 0
    var revealReach: Float = 0
    var markerRadius: Float = 0
    var selectedID: Int32 = 0
}

/// A Metal view drawing the globe of `controller`. It only redraws while something
/// moves, and ignores touches: put gestures on a SwiftUI view above it.
struct GlobeView: UIViewRepresentable {
    let controller: GlobeController

    func makeCoordinator() -> GlobeRenderer {
        GlobeRenderer(controller: controller)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = GlobeResources.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    static func dismantleUIView(_ view: MTKView, coordinator: GlobeRenderer) {
        view.isPaused = true
        coordinator.controller.onWake = nil
    }
}

final class GlobeRenderer: NSObject, MTKViewDelegate {
    let controller: GlobeController
    private weak var view: MTKView?
    private var commandQueue: MTLCommandQueue?

    init(controller: GlobeController) {
        self.controller = controller
    }

    func attach(to view: MTKView) {
        self.view = view
        commandQueue = view.device?.makeCommandQueue()
        controller.onWake = { [weak self] in
            self?.view?.isPaused = false
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.isPaused = false
    }

    func draw(in view: MTKView) {
        let scale = Double(view.contentScaleFactor)
        controller.setViewFrame(view.convert(view.bounds, to: nil))
        let frame = controller.frame(at: CACurrentMediaTime(), scale: scale)

        guard let resources = controller.resources,
              let commandQueue,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        else {
            pace(view, for: frame.activity)
            return
        }

        var uniforms = frame.uniforms
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GlobeUniforms>.stride, index: 0)
        frame.highlight.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        encoder.setFragmentTexture(resources.map, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        pace(view, for: frame.activity)
    }

    private func pace(_ view: MTKView, for activity: GlobeController.Activity) {
        view.isPaused = activity == .still
        view.preferredFramesPerSecond = activity == .animating ? 120 : 60
    }
}
