//
//  DemoCards.swift
//  Shader
//

import SwiftUI

/// Cards are designed on a 320 × 400 canvas; `cardUnit` converts design units to points.
enum CardDesign {
    static let width: CGFloat = 320
    static let height: CGFloat = 400
    static let aspectRatio: CGFloat = width / height
}

extension EnvironmentValues {
    @Entry var cardUnit: CGFloat = 1
}

enum DemoCard: Int, CaseIterable {
    case coffee, heartRate, focus, moon, solar, surf

    var accessibilityName: String {
        switch self {
        case .coffee: "Coffee roast, 212 degrees Celsius"
        case .heartRate: "Heart rate, 142 beats per minute"
        case .focus: "Deep focus, 18.5 hours this week"
        case .moon: "Moon phase, 84 percent"
        case .solar: "Solar output, 6.4 kilowatts"
        case .surf: "Surf report, 2.8 metres"
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .coffee: CoffeeRoastCard()
        case .heartRate: HeartRateCard()
        case .focus: DeepFocusCard()
        case .moon: MoonPhaseCard()
        case .solar: SolarOutputCard()
        case .surf: SurfReportCard()
        }
    }
}

// MARK: - Cards

struct CoffeeRoastCard: View {
    var body: some View {
        CardShell(palette: .coffee) {
            CardHeader(title: "Coffee roast", subtitle: "Batch 27")
            BigValue(value: "212", unit: "°C", colors: [Color(hex: 0xFFE9D2), Color(hex: 0xF38D3C)], glow: Color(hex: 0xF59A4E))
                .cardSlot(top: 155, .center)
            RoastProgress()
                .cardSlot(top: 278, inset: 29)
            CardFooter(text: "First crack in 3:40")
        }
    }
}

struct HeartRateCard: View {
    @Environment(\.cardUnit) private var u

    var body: some View {
        CardShell(palette: .heartRate) {
            CardHeader(title: "Heart rate", subtitle: "Morning run")
            HStack(spacing: 5 * u) {
                Circle()
                    .fill(.white)
                    .frame(width: 5 * u, height: 5 * u)
                Text("Live")
                    .font(.system(size: 9.5 * u, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .cardSlot(top: 89)
            BigValue(value: "142", unit: "bpm", colors: [.white, Color(hex: 0xFFC3D2)], glow: Color(hex: 0xFF8FB0))
                .cardSlot(top: 153, .center)
            HeartbeatTrace()
                .frame(height: 60 * u)
                .cardSlot(top: 252, inset: 18)
            CardFooter(text: "Zone 4 · 38 min")
        }
    }
}

struct DeepFocusCard: View {
    var body: some View {
        CardShell(palette: .focus) {
            CardHeader(title: "Deep focus", subtitle: "This week", badge: "+12%")
            BigValue(value: "18.5", unit: "h", colors: [Color(hex: 0xDDF9FF), Color(hex: 0x56C3FF)], glow: Color(hex: 0x4FC3FF))
                .cardSlot(top: 134, .center)
            WeekBars()
                .cardSlot(top: 252, .center)
            CardFooter(text: "Best day, Thursday")
        }
    }
}

struct MoonPhaseCard: View {
    var body: some View {
        CardShell(palette: .moon) {
            StarField()
            CardHeader(title: "Night sky", subtitle: "Moon phase")
            Moon()
                .cardSlot(top: 138, .center)
            BigValue(value: "84", unit: "%", colors: [Color(hex: 0xFBD3F7), Color(hex: 0xDD7BEF)], glow: Color(hex: 0xF0ABFC), size: 64, unitSize: 22)
                .cardSlot(top: 254, .center)
            CardFooter(text: "Waxing gibbous · Rises 18:42")
        }
    }
}

struct SolarOutputCard: View {
    var body: some View {
        CardShell(palette: .solar) {
            CardHeader(title: "Solar output", subtitle: "Rooftop array")
            BigValue(value: "6.4", unit: "kW", colors: [Color(hex: 0xFFFEF7), Color(hex: 0xFFEFC9)], glow: Color(hex: 0xFFF3C4), size: 100)
                .cardSlot(top: 131, .center)
            SolarBars()
                .cardSlot(top: 256, inset: 30)
            CardFooter(text: "Peak today at 13:10")
        }
    }
}

struct SurfReportCard: View {
    @Environment(\.cardUnit) private var u

    var body: some View {
        CardShell(palette: .surf) {
            CardHeader(title: "Surf report", subtitle: "North beach", badge: "Offshore")
            BigValue(value: "2.8", unit: "m", colors: [Color(hex: 0xD6FFF1), Color(hex: 0x44E2B4)], glow: Color(hex: 0x3FE0B0), size: 98)
                .cardSlot(top: 135, .center)
            SwellLines()
                .frame(height: 60 * u)
                .cardSlot(top: 260, inset: 20)
            CardFooter(text: "Period 14 s · Low tide 16:05")
        }
    }
}

// MARK: - Shared pieces

struct CardShell<Content: View>: View {
    let palette: CardPalette
    @ViewBuilder let content: Content
    @Environment(\.cardUnit) private var u

    var body: some View {
        ZStack(alignment: .topLeading) {
            BlobBackground(palette: palette)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(.rect(cornerRadius: 13 * u, style: .continuous))
    }
}

/// Pins a view at a fixed distance (in design units) from the top of the card.
struct CardSlot: ViewModifier {
    var top: CGFloat
    var alignment: HorizontalAlignment
    var inset: CGFloat
    @Environment(\.cardUnit) private var u

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
            .padding(.horizontal, inset * u)
            .padding(.top, top * u)
    }
}

extension View {
    func cardSlot(top: CGFloat, _ alignment: HorizontalAlignment = .leading, inset: CGFloat = 22) -> some View {
        modifier(CardSlot(top: top, alignment: alignment, inset: inset))
    }
}

struct CardHeader: View {
    let title: String
    let subtitle: String
    var badge: String?
    @Environment(\.cardUnit) private var u

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2 * u) {
                Text(title)
                Text(subtitle)
            }
            .font(.system(size: 15 * u, weight: .medium))
            .tracking(-0.2 * u)
            .foregroundStyle(.white.opacity(0.94))

            Spacer(minLength: 0)

            if let badge {
                Text(badge)
                    .font(.system(size: 9.5 * u, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 8 * u)
                    .padding(.vertical, 4 * u)
                    .background(.white.opacity(0.14), in: .capsule)
            }
        }
        .cardSlot(top: 33)
    }
}

struct CardFooter: View {
    let text: String
    @Environment(\.cardUnit) private var u

    var body: some View {
        Text(text)
            .font(.system(size: 15 * u, weight: .medium))
            .tracking(-0.2 * u)
            .foregroundStyle(.white.opacity(0.94))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, 22 * u)
            .padding(.bottom, 24 * u)
    }
}

/// The headline number with its unit set as a superscript whose cap height lines up
/// with the digits.
struct BigValue: View {
    let value: String
    let unit: String
    let colors: [Color]
    let glow: Color
    var size: CGFloat = 92
    var unitSize: CGFloat = 26
    @Environment(\.cardUnit) private var u

    private static let capHeight: CGFloat = 0.705

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3 * u) {
            Text(value)
                .font(.system(size: size * u, weight: .semibold))
                .tracking(-0.03 * size * u)
                .foregroundStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            Text(unit)
                .font(.system(size: unitSize * u, weight: .medium))
                .foregroundStyle(colors.first ?? .white)
                .offset(y: -Self.capHeight * (size - unitSize) * u)
        }
        .shadow(color: glow.opacity(0.55), radius: 14 * u)
    }
}

// MARK: - Card visuals

struct RoastProgress: View {
    var lit = 14
    var total = 24
    @Environment(\.cardUnit) private var u

    var body: some View {
        VStack(spacing: 9 * u) {
            HStack(spacing: 3 * u) {
                ForEach(0..<total, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.8 * u, style: .continuous)
                        .fill(index < lit
                              ? Color(hex: 0xF5913F).opacity(0.55 + 0.45 * Double(index) / Double(lit - 1))
                              : .white.opacity(0.13))
                        .frame(height: 3.8 * u)
                }
            }
            ZStack {
                Text("Drying").frame(maxWidth: .infinity, alignment: .leading)
                Text("Maillard").foregroundStyle(.white.opacity(0.8))
                Text("Develop").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 8.5 * u, weight: .medium))
            .foregroundStyle(.white.opacity(0.42))
        }
    }
}

struct HeartbeatTrace: View {
    @Environment(\.cardUnit) private var u

    /// One beat: x across the beat, y up from the baseline (as a fraction of the amplitude).
    private static let beat: [CGPoint] = [
        .init(x: 0.00, y: 0), .init(x: 0.16, y: 0), .init(x: 0.20, y: 0.10), .init(x: 0.24, y: 0.14),
        .init(x: 0.28, y: 0.08), .init(x: 0.32, y: 0), .init(x: 0.38, y: 0), .init(x: 0.41, y: -0.16),
        .init(x: 0.46, y: 1.00), .init(x: 0.51, y: -0.52), .init(x: 0.55, y: 0.04), .init(x: 0.60, y: 0),
        .init(x: 0.66, y: 0.10), .init(x: 0.71, y: 0.26), .init(x: 0.76, y: 0.22), .init(x: 0.81, y: 0.04),
        .init(x: 0.86, y: 0), .init(x: 1.00, y: 0),
    ]

    var body: some View {
        Canvas { context, size in
            let beats = 4
            let width = size.width / CGFloat(beats)
            let amplitude = size.height * 0.48
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            for index in 0..<beats {
                for point in Self.beat {
                    path.addLine(to: CGPoint(x: (CGFloat(index) + point.x) * width,
                                             y: size.height / 2 - point.y * amplitude))
                }
            }
            context.stroke(path, with: .color(Color(hex: 0xFFD9E3)),
                           style: StrokeStyle(lineWidth: 1.5 * u, lineCap: .round, lineJoin: .round))
        }
        .shadow(color: Color(hex: 0xFF7FA6).opacity(0.9), radius: 5 * u)
    }
}

struct WeekBars: View {
    private let values: [CGFloat] = [30, 44, 37, 58, 50, 30, 27]
    private let days = ["M", "T", "W", "T", "F", "S", "S"]
    private let best = 3
    @Environment(\.cardUnit) private var u

    var body: some View {
        HStack(alignment: .bottom, spacing: 20 * u) {
            ForEach(values.indices, id: \.self) { index in
                VStack(spacing: 9 * u) {
                    RoundedRectangle(cornerRadius: 4.5 * u, style: .continuous)
                        .fill(index == best
                              ? LinearGradient(colors: [Color(hex: 0xE6FBFF), Color(hex: 0x7FD6FF)], startPoint: .top, endPoint: .bottom)
                              : LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.14)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 16 * u, height: values[index] * u)
                        .shadow(color: Color(hex: 0x7FD6FF).opacity(index == best ? 0.9 : 0), radius: 8 * u)
                    Text(days[index])
                        .font(.system(size: 8 * u, weight: .medium))
                        .foregroundStyle(.white.opacity(index == best ? 0.85 : 0.5))
                }
            }
        }
    }
}

struct SolarBars: View {
    private let count = 25
    private let peak = 14
    @Environment(\.cardUnit) private var u

    var body: some View {
        VStack(spacing: 8 * u) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    let distance = Double(index - 13) / 3.6
                    let height = 58 * exp(-distance * distance / 2)
                    Capsule()
                        .fill(.white.opacity(index == peak ? 1 : (height < 4 ? 0.35 : 0.55)))
                        .frame(width: (index == peak ? 5 : 4.4) * u, height: max(height, 2) * u)
                        .shadow(color: .white.opacity(index == peak ? 0.9 : 0), radius: 5 * u)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 60 * u, alignment: .bottom)
            ZStack {
                Text("06").frame(maxWidth: .infinity, alignment: .leading)
                Text("12")
                Text("18").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 8 * u, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
        }
    }
}

struct SwellLines: View {
    @Environment(\.cardUnit) private var u

    var body: some View {
        Canvas { context, size in
            let lines: [(phase: Double, cycles: Double, amplitude: Double, opacity: Double)] = [
                (0.0, 2.6, 0.36, 0.8), (1.7, 2.2, 0.3, 0.5), (3.1, 3.0, 0.22, 0.32),
            ]
            for line in lines {
                var path = Path()
                for step in 0...96 {
                    let t = Double(step) / 96
                    let wave = 0.7 * sin(t * .pi * 2 * line.cycles + line.phase)
                        + 0.3 * sin(t * .pi * 2 * line.cycles * 2.3 + line.phase * 1.6)
                    let point = CGPoint(x: t * size.width, y: size.height / 2 * (1 - line.amplitude * 2 * wave))
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(Color(hex: 0xBFFBE6).opacity(line.opacity)),
                               style: StrokeStyle(lineWidth: 1.3 * u, lineCap: .round))
            }
        }
    }
}

struct Moon: View {
    @Environment(\.cardUnit) private var u

    var body: some View {
        let diameter = 104 * u
        ZStack {
            Circle().fill(Color(hex: 0x3B136F))
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFFF8FF), Color(hex: 0xE9CCFF), Color(hex: 0xC69CF4)],
                                     center: UnitPoint(x: 0.62, y: 0.38), startRadius: 0, endRadius: diameter * 0.62))
                .mask(Circle().offset(x: diameter * 0.17))
        }
        .frame(width: diameter, height: diameter)
        .clipShape(.circle)
        .shadow(color: Color(hex: 0xEBD5FF).opacity(0.75), radius: 20 * u)
    }
}

struct StarField: View {
    var body: some View {
        Canvas { context, size in
            let unit = size.width / CardDesign.width
            for index in 0..<48 {
                let seed = Double(index)
                let x = fract(sin(seed * 12.9898) * 43758.5453) * size.width
                let y = fract(sin(seed * 78.233) * 12345.6789) * size.height
                let radius = (0.35 + 0.7 * fract(sin(seed * 3.17) * 9631.17)) * unit
                let opacity = 0.2 + 0.6 * fract(sin(seed * 5.71) * 2741.3)
                context.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(.white.opacity(opacity)))
            }
        }
    }

    private func fract(_ value: Double) -> Double {
        value - value.rounded(.down)
    }
}

// MARK: - Backgrounds

struct Blob {
    var color: Color
    var center: UnitPoint
    /// Radius as a fraction of the card width.
    var radius: CGFloat
}

struct CardPalette {
    var base: [Color]
    var blobs: [Blob]
}

extension CardPalette {
    static let coffee = CardPalette(base: [Color(hex: 0x16103A), Color(hex: 0x100B26)], blobs: [
        Blob(color: Color(hex: 0x0E0A24), center: UnitPoint(x: 0.7, y: 0.55), radius: 0.6),
        Blob(color: Color(hex: 0x5442DC), center: UnitPoint(x: 0.85, y: 0.18), radius: 0.72),
        Blob(color: Color(hex: 0xF08A2E), center: UnitPoint(x: 0.08, y: 0.9), radius: 0.85),
        Blob(color: Color(hex: 0xA83A72), center: UnitPoint(x: 1.0, y: 1.0), radius: 0.5),
    ])

    static let heartRate = CardPalette(base: [Color(hex: 0xA81733), Color(hex: 0x86112E)], blobs: [
        Blob(color: Color(hex: 0xEE4A22), center: UnitPoint(x: 0.08, y: 0.5), radius: 0.85),
        Blob(color: Color(hex: 0xF4356F), center: UnitPoint(x: 0.95, y: 0.42), radius: 0.75),
        Blob(color: Color(hex: 0x5C0A22), center: UnitPoint(x: 0.5, y: 0.62), radius: 0.5),
        Blob(color: Color(hex: 0xC8264D), center: UnitPoint(x: 0.75, y: 1.05), radius: 0.6),
    ])

    static let focus = CardPalette(base: [Color(hex: 0x0B1B52), Color(hex: 0x1C46C8)], blobs: [
        Blob(color: Color(hex: 0x071030), center: UnitPoint(x: 0.05, y: 0.08), radius: 0.8),
        Blob(color: Color(hex: 0x2563EB), center: UnitPoint(x: 0.65, y: 0.62), radius: 0.8),
        Blob(color: Color(hex: 0x3B82F6), center: UnitPoint(x: 0.95, y: 0.3), radius: 0.5),
        Blob(color: Color(hex: 0xB4ECFF), center: UnitPoint(x: 1.0, y: 1.0), radius: 0.6),
    ])

    static let moon = CardPalette(base: [Color(hex: 0x5521B5), Color(hex: 0x7B2FD6)], blobs: [
        Blob(color: Color(hex: 0x2A0B63), center: UnitPoint(x: 0.0, y: 0.62), radius: 0.75),
        Blob(color: Color(hex: 0xA855F7), center: UnitPoint(x: 0.85, y: 0.15), radius: 0.75),
        Blob(color: Color(hex: 0x6D28D9), center: UnitPoint(x: 0.45, y: 0.5), radius: 0.5),
        Blob(color: Color(hex: 0xD6A6FF), center: UnitPoint(x: 0.95, y: 0.95), radius: 0.65),
    ])

    static let solar = CardPalette(base: [Color(hex: 0xF97A3E), Color(hex: 0xF7744C)], blobs: [
        Blob(color: Color(hex: 0xFCD34D), center: UnitPoint(x: 0.55, y: 0.14), radius: 0.85),
        Blob(color: Color(hex: 0x4F9A2C), center: UnitPoint(x: 0.5, y: 0.52), radius: 0.42),
        Blob(color: Color(hex: 0xF9A8C8), center: UnitPoint(x: 1.0, y: 1.0), radius: 0.65),
        Blob(color: Color(hex: 0xF86A35), center: UnitPoint(x: 0.0, y: 0.6), radius: 0.5),
    ])

    static let surf = CardPalette(base: [Color(hex: 0x0A3A2C), Color(hex: 0x0D5843)], blobs: [
        Blob(color: Color(hex: 0x05261C), center: UnitPoint(x: 0.12, y: 0.25), radius: 0.7),
        Blob(color: Color(hex: 0x23C79C), center: UnitPoint(x: 0.88, y: 0.28), radius: 0.8),
        Blob(color: Color(hex: 0x12805F), center: UnitPoint(x: 0.45, y: 0.75), radius: 0.6),
        Blob(color: Color(hex: 0x8DF2D2), center: UnitPoint(x: 0.98, y: 0.98), radius: 0.55),
    ])
}

struct BlobBackground: View {
    let palette: CardPalette

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: palette.base, startPoint: .top, endPoint: .bottom)
                ForEach(palette.blobs.indices, id: \.self) { index in
                    let blob = palette.blobs[index]
                    RadialGradient(
                        stops: [
                            .init(color: blob.color, location: 0),
                            .init(color: blob.color.opacity(0.72), location: 0.3),
                            .init(color: blob.color.opacity(0.32), location: 0.6),
                            .init(color: blob.color.opacity(0.08), location: 0.85),
                            .init(color: blob.color.opacity(0), location: 1),
                        ],
                        center: blob.center,
                        startRadius: 0,
                        endRadius: blob.radius * proxy.size.width
                    )
                }
            }
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}
