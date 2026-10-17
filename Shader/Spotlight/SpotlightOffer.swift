//
//  SpotlightOffer.swift
//  Shader
//

import SwiftUI

/// Sizes and timings measured from the reference recording.
enum SpotlightDesign {
    static let cardWidth: CGFloat = 212
    static let cardCornerRadius: CGFloat = 20
    /// The card's gradient, light blue at the top to dark blue.
    static let blues = [Color(hex: 0x2D6DF7), Color(hex: 0x0238A6)]
    /// Light wedges in the sunburst.
    static let rays = 16
    /// Clockwise, radians per second (about one turn every 15 s).
    static let raySpeed = 23.5 * Double.pi / 180
    /// The glint takes `shimmerDuration` to cross the button and comes back every
    /// `shimmerPeriod`, the first time `shimmerDelay` after the card appears.
    static let shimmerDuration = 0.5
    static let shimmerPeriod = 3.0
    static let shimmerDelay = 0.8
}

/// The offer card in its spotlight: a dimming scrim, a sunburst turning around the
/// card and a warm glow hugging it, all drawn by the `spotlightBackdrop` Metal shader.
/// Fills its container with the card in the middle.
struct SpotlightStage: View {
    /// Fades the backdrop in and springs the card up when it turns on.
    var isShown = true
    var onClaim: () -> Void = {}

    @State private var cardFrame: CGRect = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let space = "spotlightStage"

    var body: some View {
        ZStack {
            SpotlightBackdrop(
                cardFrame: cardFrame,
                // Follows the card while it scales in.
                cornerRadius: SpotlightDesign.cardCornerRadius * cardFrame.width / SpotlightDesign.cardWidth
            )
            .opacity(isShown ? 1 : 0)

            OfferCard(onClaim: onClaim)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { cardFrame = $0 }
                .scaleEffect(isShown || reduceMotion ? 1 : 0.85)
                .opacity(isShown ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(.named(Self.space))
    }
}

/// Scrim, sunburst and glow around `cardFrame` (in this view's coordinates).
private struct SpotlightBackdrop: View {
    var cardFrame: CGRect
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            Rectangle()
                .colorEffect(ShaderLibrary.spotlightBackdrop(
                    .float4(cardFrame.minX, cardFrame.minY, cardFrame.width, cardFrame.height),
                    .float(cornerRadius),
                    .float(Float(SpotlightDesign.rays)),
                    .float(rotation(at: context.date)),
                    .color(Color(red: 0.01, green: 0.02, blue: 0.04, opacity: 0.91)),  // scrim
                    .float(0.018),                                                      // ray light
                    .color(Color(hex: 0x504034)),                                       // glow at the edge
                    .float(25)                                                          // glow reach, points
                ))
        }
        .accessibilityHidden(true)
    }

    /// Wrapped to one wedge (the pattern repeats there) so the shader's float stays small.
    private func rotation(at date: Date) -> Double {
        guard !reduceMotion else { return 0 }
        let wedge = 2 * Double.pi / Double(SpotlightDesign.rays)
        return (date.timeIntervalSinceReferenceDate * SpotlightDesign.raySpeed).truncatingRemainder(dividingBy: wedge)
    }
}

/// The offer: a logo, the deal and a claim button.
private struct OfferCard: View {
    var onClaim: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OfferLogo()
                .padding(.bottom, 10)
            Text("Aurora Rewards Card")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.5))
            Text("FREE GOLD CARD")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.8)
                .padding(.top, 2)
            HStack(spacing: 5) {
                Text("NO CODE NEEDED")
                Image(systemName: "square.on.square")
                    .accessibilityHidden(true)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.top, 12)
            ClaimButton(action: onClaim)
                .padding(.top, 18)
        }
        .lineLimit(1)
        .padding(.top, 36)
        .padding([.horizontal, .bottom], 16)
        .frame(width: SpotlightDesign.cardWidth)
        .background(
            LinearGradient(colors: SpotlightDesign.blues, startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.75)),
            in: .rect(cornerRadius: SpotlightDesign.cardCornerRadius, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}

private struct OfferLogo: View {
    var body: some View {
        Image(systemName: "creditcard.fill")
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(.white)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(Color(hex: 0x3DDBB4))
                    .frame(width: 6, height: 6)
                    .offset(x: 7, y: -3)
            }
            .frame(width: 55, height: 55)
            .background(.black, in: .circle)
            .accessibilityHidden(true)
    }
}

private struct ClaimButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text("CLAIM NOW")
                    .font(.system(size: 15, weight: .bold))
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(.system(size: 20))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background {
                let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
                shape.fill(.white.opacity(0.45))
                ShimmerGlint(shape: shape)
            }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Claim now")
    }
}

/// A glint that crosses the shape every few seconds (the `shimmerSweep` Metal shader).
private struct ShimmerGlint<S: Shape>: View {
    var shape: S
    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !reduceMotion {
            TimelineView(.animation) { context in
                shape
                    .fill(.white)
                    .colorEffect(ShaderLibrary.shimmerSweep(
                        .boundingRect,
                        .float(progress(at: context.date)),
                        .float(0.5),    // slant: leans like "/"
                        .float(26),     // band width, points
                        .float(0.55)    // peak opacity
                    ))
            }
        }
    }

    /// 0…1 while the glint crosses, then held past the right edge until the next sweep.
    private func progress(at date: Date) -> Double {
        let period = SpotlightDesign.shimmerPeriod
        let elapsed = date.timeIntervalSince(start) - SpotlightDesign.shimmerDelay
        let phase = elapsed - (elapsed / period).rounded(.down) * period
        return min(phase / SpotlightDesign.shimmerDuration, 1)
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// The spotlight over everything, with a close button. Animates in when it appears and
/// calls `dismiss` once it has animated out.
struct SpotlightOverlay: View {
    var dismiss: () -> Void
    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A navigation bar only to hold the close button: the system then puts it where
        // navigation controls go on each phone (top trailing, or beside the camera on the
        // iPhone Duo's cover screen).
        NavigationStack {
            SpotlightStage(isShown: isShown, onClaim: close)
                .ignoresSafeArea()
                .containerBackground(.clear, for: .navigation)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close", systemImage: "xmark", action: close)
                            .labelStyle(.iconOnly)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color(hex: 0x0B0F17), in: .circle)
                            .contentShape(.circle)
                            .buttonStyle(.plain)
                            .opacity(isShown ? 1 : 0)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.3)) {
                isShown = true
            }
        }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.2)) {
            isShown = false
        } completion: {
            dismiss()
        }
    }
}
