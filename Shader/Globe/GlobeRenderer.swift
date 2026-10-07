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
    var paper = SIMD3<Float>()
    var ink = SIMD3<Float>()
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
    var dotGain: Float = 1
    var restLevel: Float = 1
    var highlightGrowth: Float = 0
    var regionFocus: Float = 0
    var selectedID: Int32 = 0
}

/// The globe's colours. Dots are ink on paper: the shader works out how much ink each
/// pixel takes and blends between the two, so dark is white on black and light is
/// grey and black on white.
enum GlobeTheme: String, CaseIterable, Identifiable {
    case light
    case dark

    /// `@AppStorage` key shared by the picker and the catalog preview.
    static let storageKey = "globeTheme"

    var id: Self { self }

    /// How the theme inks the globe.
    struct Style {
        var paper: SIMD3<Float>
        var ink: SIMD3<Float>
        /// Scales the ink of every dot.
        var dotGain: Float
        /// Extra ink for the dots of the picked region.
        var highlightLevel: Float
        /// Share of their ink the other dots keep while a region is picked.
        var restLevel: Float
        /// Ink of the picked country's dots.
        var countryLevel: Float
        /// How much bigger the picked region's dots get.
        var highlightGrowth: Float

        func mixed(with other: Style, _ t: Float) -> Style {
            func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * t }
            return Style(paper: simd_mix(paper, other.paper, SIMD3(repeating: t)),
                         ink: simd_mix(ink, other.ink, SIMD3(repeating: t)),
                         dotGain: mix(dotGain, other.dotGain),
                         highlightLevel: mix(highlightLevel, other.highlightLevel),
                         restLevel: mix(restLevel, other.restLevel),
                         countryLevel: mix(countryLevel, other.countryLevel),
                         highlightGrowth: mix(highlightGrowth, other.highlightGrowth))
        }
    }

    var style: Style {
        switch self {
        case .light:
            // Grey on white: picked dots go fully black, a little bigger, and everything
            // else fades back so they stand out.
            Style(paper: SIMD3(1, 1, 1), ink: SIMD3(0, 0, 0), dotGain: 1.1,
                  highlightLevel: 1.2, restLevel: 0.45, countryLevel: 1, highlightGrowth: 0.2)
        case .dark:
            Style(paper: SIMD3(0, 0, 0), ink: SIMD3(1, 1, 1), dotGain: 1,
                  highlightLevel: 0.45, restLevel: 1, countryLevel: 0.8, highlightGrowth: 0)
        }
    }

    var paper: SIMD3<Float> { style.paper }

    var background: Color {
        Color(red: Double(paper.x), green: Double(paper.y), blue: Double(paper.z))
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A Metal view drawing the globe of `controller`. It only redraws while something
/// moves, and ignores touches: put gestures on a SwiftUI view above it.
struct GlobeView: UIViewRepresentable {
    let controller: GlobeController
    var theme: GlobeTheme = .light

    func makeCoordinator() -> GlobeRenderer {
        GlobeRenderer(controller: controller)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = GlobeResources.pixelFormat
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.isPaused = true
        view.isUserInteractionEnabled = false
        view.delegate = context.coordinator
        context.coordinator.attach(to: view)
        controller.setTheme(theme, animated: false)
        applyBackground(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        controller.setTheme(theme, animated: true)
        applyBackground(to: view)
    }

    /// Shows until the first frame is drawn.
    private func applyBackground(to view: MTKView) {
        let paper = theme.paper
        view.backgroundColor = UIColor(red: CGFloat(paper.x), green: CGFloat(paper.y), blue: CGFloat(paper.z), alpha: 1)
        view.clearColor = MTLClearColor(red: Double(paper.x), green: Double(paper.y), blue: Double(paper.z), alpha: 1)
    }

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
