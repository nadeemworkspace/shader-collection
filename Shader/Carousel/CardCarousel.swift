//
//  CardCarousel.swift
//  Shader
//

import SwiftUI
import QuartzCore

/// How cards are arranged in 3D.
enum CarouselStyle: String, CaseIterable, Identifiable {
    /// Neighbours sit at the sides facing away (content reads mirrored) and flip through
    /// edge-on as they travel.
    case flip
    /// Cards are bent around the front of a spinning cylinder.
    case drum

    var id: Self { self }

    var title: String {
        switch self {
        case .flip: "Flip"
        case .drum: "Drum"
        }
    }
}

/// An endless 3D card carousel.
///
/// - Flip: the whole stage goes through the `edgeLens` Metal shader, which refracts
///   whatever reaches the left and right edges.
/// - Drum: each card goes through the `drumWrap` Metal shader, which bends it around
///   a cylinder.
struct CardCarousel<Card: View>: View {
    let count: Int
    var style: CarouselStyle = .flip
    /// Pass a shared motion to keep the position when the carousel is rebuilt
    /// (e.g. while cross-fading between styles). Defaults to a private one.
    var motion: CarouselMotion?
    /// Previews turn this off: no gestures, focus or accessibility element.
    var isInteractive = true
    /// Steps to the next card on this interval (skipped with Reduce Motion).
    var autoAdvance: Duration?
    var accessibilityName: (Int) -> String = { "Card \($0 + 1)" }
    @ViewBuilder let card: (Int) -> Card

    @State private var ownMotion = CarouselMotion()
    @State private var isDragging = false
    @GestureState private var isGestureActive = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeMotion: CarouselMotion { motion ?? ownMotion }

    var body: some View {
        let motion = activeMotion
        GeometryReader { proxy in
            let layout = CarouselLayout(size: proxy.size, style: style, count: count)
            Group {
                switch style {
                case .flip: flipStage(layout: layout, position: motion.position)
                case .drum: drumStage(layout: layout, position: motion.position)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(layout: layout))
        }
        // Previews let taps through to whatever contains them (e.g. a navigation link).
        .allowsHitTesting(isInteractive)
        .focusable(isInteractive)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { motion.step(-1); return .handled }
        .onKeyPress(.rightArrow) { motion.step(1); return .handled }
        .onAppear { isFocused = isInteractive }
        .onChange(of: isGestureActive) { _, active in
            // The system cancelled the drag (no `onEnded`): settle where we are.
            if !active, isDragging {
                isDragging = false
                motion.release(velocity: 0)
            }
        }
        .task(id: autoAdvance) {
            guard let autoAdvance, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: autoAdvance)
                guard !Task.isCancelled else { return }
                motion.step(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cards")
        .accessibilityValue(accessibilityName(wrapped(motion.restingIndex)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: motion.step(1)
            case .decrement: motion.step(-1)
            @unknown default: break
            }
        }
        .accessibilityHidden(!isInteractive)
    }

    private func flipStage(layout: CarouselLayout, position: Double) -> some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                let offset = layout.offset(of: index, position: position)
                card(index)
                    .environment(\.cardUnit, layout.cardUnit)
                    .frame(width: layout.cardSize.width, height: layout.cardSize.height)
                    .projectionEffect(layout.flipProjection(for: offset))
                    .opacity(layout.flipOpacity(for: offset))
                    .zIndex(-abs(offset))
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(Color.carouselBackground)
        // Flatten first: otherwise SwiftUI can run the layer effect over separate
        // pieces of the stage, and the per-channel dispersion no longer composites
        // correctly (fringes pick up the wrong hue).
        .drawingGroup()
        .layerEffect(
            ShaderLibrary.edgeLens(
                .boundingRect,
                .float(layout.lensBand),
                .float(layout.size.height / 2),  // flare centre line
                .float(0.49),                    // vertical strength (~2× at the edge)
                .float(2.5),                     // horizontal strength
                .float(0.3),                     // vertical dispersion
                .float(0.08)                     // horizontal dispersion
            ),
            maxSampleOffset: CGSize(width: layout.lensBand, height: layout.size.height / 2)
        )
    }

    private func drumStage(layout: CarouselLayout, position: Double) -> some View {
        // The cards lie flat, side by side, on one strip that a single shader pass wraps
        // around the drum (cards on a drum never overlap, so no sorting is needed). They
        // sit at whole-card offsets from the nearest resting position and the fraction
        // goes to the shader, so the strip itself only changes when a card passes the
        // centre.
        let anchor = position.rounded()
        let strip = layout.drumStripSize
        return ZStack {
            ForEach(0..<count, id: \.self) { index in
                let slot = layout.offset(of: index, position: anchor)
                if layout.isOnDrumStrip(slot) {
                    card(index)
                        .environment(\.cardUnit, layout.cardUnit)
                        .frame(width: layout.cardSize.width, height: layout.cardSize.height)
                        .offset(x: slot * layout.drumPitch)
                }
            }
        }
        .frame(width: strip.width, height: strip.height)
        // Flatten first so the effect sees the whole strip as one layer.
        .drawingGroup()
        .layerEffect(
            ShaderLibrary.drumWrap(
                .float2(strip.width / 2, strip.height / 2),
                .float(layout.drumRadius),
                .float(layout.cameraDistance),
                .float((anchor - position) * layout.drumPitch),
                .color(.carouselBackground),
                .float(0.9),            // haze at 90°
                .float(10)              // blur radius at 90°, points
            ),
            maxSampleOffset: CGSize(width: layout.drumSampleReach, height: 0)
        )
        .frame(width: layout.size.width, height: layout.size.height)
        .background(Color.carouselBackground)
    }

    private func dragGesture(layout: CarouselLayout) -> some Gesture {
        let motion = activeMotion
        return DragGesture(minimumDistance: 0)
            .updating($isGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    motion.grab()
                }
                motion.drag(by: value.translation.width / layout.dragUnit)
            }
            .onEnded { value in
                isDragging = false
                let travel = abs(value.translation.width) + abs(value.translation.height)
                guard travel < 8 else {
                    motion.release(velocity: -value.velocity.width / layout.dragUnit)
                    return
                }
                // A tap: settle, then step toward whichever side was tapped.
                motion.release(velocity: 0)
                let x = value.location.x - layout.size.width / 2
                if x < -layout.cardSize.width / 2 {
                    motion.step(-1)
                } else if x > layout.cardSize.width / 2 {
                    motion.step(1)
                }
            }
    }

    private func wrapped(_ index: Int) -> Int {
        ((index % count) + count) % count
    }
}

// MARK: - Layout

/// Geometry of the stage, fitted from the reference recordings. A card's offset `o` is
/// its distance from the centre in cards (0 = centre, ±1 = neighbours), wrapped so the
/// carousel is endless.
///
/// - Flip: turned `180° · o`, slid `o · spacing` sideways and pushed `o² · depth` away
///   from a perspective camera.
/// - Drum: bent around a cylinder of radius `drumRadius`, `o · drumPitch` of arc away
///   from the front. The cards are laid flat on a strip that is wrapped as a whole.
struct CarouselLayout {
    let size: CGSize
    let style: CarouselStyle
    let count: Int
    let cardSize: CGSize
    /// Camera distance to the centre card (flip) or to the front of the drum.
    let cameraDistance: CGFloat
    let lensBand: CGFloat
    let drumRadius: CGFloat
    /// Arc length from one drum card's centre to the next.
    let drumPitch: CGFloat

    private let spacing: CGFloat
    private let depth: CGFloat

    /// On-screen scale of a flip neighbour relative to the centre card.
    private static let neighbourScale: CGFloat = 0.66

    init(size: CGSize, style: CarouselStyle, count: Int) {
        self.size = size
        self.style = style
        self.count = count

        // Narrow screens are limited by width: flip neighbours need room at the sides,
        // drum neighbours curve away and need a little less.
        let widthShare: CGFloat = style == .flip ? 2.15 : 2.2
        let height = min(size.height * 0.63, size.width / widthShare / CardDesign.aspectRatio)
        cardSize = CGSize(width: height * CardDesign.aspectRatio, height: height)
        let width = cardSize.width

        // Flip: neighbours end flush with the screen edge, as in the reference, but keep
        // at least 12% of a card width of air next to the centre card on narrow screens.
        let scale = Self.neighbourScale
        let flipCamera = 4.16 * width
        depth = flipCamera * (1 / scale - 1)
        let flush = size.width / (2 * scale) - width / 2
        let minimum = (0.62 * width) / scale + width / 2
        spacing = max(flush, minimum)
        // The lens covers the outer ~58% of what is visible of a neighbour, leaving its
        // inner edge undistorted.
        let neighbourInnerEdge = scale * (spacing - width / 2)
        lensBand = 0.58 * max(size.width / 2 - neighbourInnerEdge, 0.3 * width)

        // Drum: radius, camera and the gap between cards measured from the reference.
        drumRadius = 1.95 * width
        drumPitch = 1.09 * width

        cameraDistance = style == .flip ? flipCamera : 3.1 * width
    }

    /// Size of one card design unit in points.
    var cardUnit: CGFloat { cardSize.width / CardDesign.width }

    /// Points of horizontal drag that move the carousel by one card: roughly how far a
    /// neighbour's centre sits from the screen centre.
    var dragUnit: CGFloat {
        switch style {
        case .flip: spacing * Self.neighbourScale
        case .drum: drumPitch
        }
    }

    /// Offset of card `index` from the centre, wrapped into `-count/2 ..< count/2`.
    func offset(of index: Int, position: Double) -> Double {
        let n = Double(count)
        var offset = (Double(index) - position).truncatingRemainder(dividingBy: n)
        if offset < -n / 2 {
            offset += n
        } else if offset >= n / 2 {
            offset -= n
        }
        return offset
    }

    func flipProjection(for offset: Double) -> ProjectionTransform {
        let o = CGFloat(offset)
        let half = CGSize(width: cardSize.width / 2, height: cardSize.height / 2)

        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / cameraDistance

        var transform = CATransform3DMakeTranslation(-half.width, -half.height, 0)
        transform = CATransform3DConcat(transform, CATransform3DMakeRotation(.pi * o, 0, 1, 0))
        transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(spacing * o, 0, -depth * o * o))
        transform = CATransform3DConcat(transform, perspective)
        transform = CATransform3DConcat(transform, CATransform3DMakeTranslation(half.width, half.height, 0))
        return ProjectionTransform(transform)
    }

    /// Flip cards fade out past the neighbours; they are edge-on by ±1.5 anyway.
    func flipOpacity(for offset: Double) -> Double {
        min(max((1.5 - abs(offset)) / 0.25, 0), 1)
    }

    /// Angle from the front of the drum to its silhouette, as seen by the camera.
    private var drumVisibleAngle: CGFloat {
        acos(drumRadius / (drumRadius + cameraDistance))
    }

    /// Half the arc of the drum the camera can see, plus the half pitch the strip can be
    /// scrolled either way before the cards move to new slots.
    private var drumStripReach: CGFloat {
        drumRadius * drumVisibleAngle + drumPitch / 2
    }

    /// The flat strip of cards: wide enough for every card that can be on the visible
    /// arc, one card tall (cards are never magnified past their flat size).
    var drumStripSize: CGSize {
        CGSize(width: 2 * drumStripReach, height: cardSize.height)
    }

    /// Whether a card at a whole-card offset can show on the visible arc.
    func isOnDrumStrip(_ slot: Double) -> Bool {
        abs(CGFloat(slot)) * drumPitch - cardSize.width / 2 < drumStripReach
    }

    /// Farthest a drum pixel samples from itself: the visible arc unrolls wider than
    /// its projection, most of all at the silhouette, plus the scroll.
    var drumSampleReach: CGFloat {
        let angle = drumVisibleAngle
        let projected = drumRadius * sin(angle) * cameraDistance
            / (cameraDistance + drumRadius * (1 - cos(angle)))
        return drumRadius * angle - projected + drumPitch / 2 + 2
    }
}

// MARK: - Motion

/// Spring-driven scroll position. Driving it from a display link (rather than SwiftUI
/// animations) lets a drag catch the carousel mid-flight without a jump.
@Observable
final class CarouselMotion {
    /// Continuous index of the card at the centre; whole numbers are resting positions.
    private(set) var position: Double = 0

    @ObservationIgnored private var target: Double = 0
    @ObservationIgnored private var velocity: Double = 0
    @ObservationIgnored private var grabbedAt: Double = 0
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval?

    // Response ≈ 0.5 s, damping ratio ≈ 0.86.
    private let stiffness = 158.0
    private let damping = 21.6

    var restingIndex: Int { Int(target.rounded()) }

    func step(_ delta: Int) {
        target = target.rounded() + Double(delta)
        start()
    }

    func grab() {
        stop()
        grabbedAt = position
    }

    func drag(by cards: CGFloat) {
        position = grabbedAt - Double(cards)
    }

    /// Settles on the card the gesture was heading for, at most one away from the card
    /// that was centred when it began (like paging in a scroll view).
    /// - Parameter velocity: cards per second.
    func release(velocity: CGFloat) {
        let speed = Double(velocity)
        let origin = grabbedAt.rounded()
        let projected = (position + speed * 0.15).rounded()
        target = min(max(projected, origin - 1), origin + 1)
        self.velocity = speed
        start()
    }

    private func start() {
        guard displayLink == nil else { return }
        lastTimestamp = nil
        let ticker = DisplayLinkTicker { [weak self] link in
            guard let self else {
                link.invalidate()
                return
            }
            self.tick(link)
        }
        let link = CADisplayLink(target: ticker, selector: #selector(DisplayLinkTicker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        velocity = 0
    }

    private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let elapsed = min(max(now - (lastTimestamp ?? link.timestamp), 1.0 / 240), 1.0 / 30)
        lastTimestamp = now

        // Semi-implicit Euler, sub-stepped so long frames stay stable.
        let substeps = 4
        let dt = elapsed / Double(substeps)
        var x = position
        var v = velocity
        for _ in 0..<substeps {
            v += (-stiffness * (x - target) - damping * v) * dt
            x += v * dt
        }

        if abs(x - target) < 0.0005, abs(v) < 0.005 {
            position = target
            stop()
        } else {
            position = x
            velocity = v
        }
    }
}

private final class DisplayLinkTicker: NSObject {
    private let action: (CADisplayLink) -> Void

    init(_ action: @escaping (CADisplayLink) -> Void) {
        self.action = action
    }

    @objc func tick(_ link: CADisplayLink) {
        action(link)
    }
}

extension Color {
    static let carouselBackground = Color(white: 0.94)
}

