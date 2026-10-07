//
//  ShaderCatalog.swift
//  Shader
//

import SwiftUI

/// One entry in the collection. Add a case here to list a new effect.
enum ShaderEffect: String, CaseIterable, Identifiable, Hashable {
    case carousel
    case globe

    var id: Self { self }

    var title: String {
        switch self {
        case .carousel: "Carousel"
        case .globe: "Globe"
        }
    }

    var summary: String {
        switch self {
        case .carousel: "3D cards refracted through a glass edge"
        case .globe: "Dotted globe that flies to the country you pick"
        }
    }

    var variants: String {
        switch self {
        case .carousel: CarouselStyle.allCases.map(\.title).joined(separator: " · ")
        case .globe: "Regions · Countries"
        }
    }

    /// A small, non-interactive live preview for the catalog.
    @ViewBuilder var preview: some View {
        switch self {
        case .carousel:
            CardCarousel(count: DemoCard.allCases.count, isInteractive: false, autoAdvance: .seconds(2.4)) { index in
                DemoCard.allCases[index].view
            }
        case .globe:
            GlobePreview()
        }
    }

    @ViewBuilder var destination: some View {
        switch self {
        case .carousel: CarouselShowcaseView()
        case .globe: CountryPickerView()
        }
    }
}

enum CatalogLayout: String {
    case grid, list
}

/// Landing screen: every effect in the collection, as a grid or a list.
struct ShaderCatalogView: View {
    @AppStorage("catalogLayout") private var layout: CatalogLayout = .grid

    var body: some View {
        ScrollView {
            Group {
                switch layout {
                case .grid:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                        ForEach(ShaderEffect.allCases) { effect in
                            NavigationLink(value: effect) { EffectTile(effect: effect) }
                        }
                    }
                case .list:
                    LazyVStack(spacing: 12) {
                        ForEach(ShaderEffect.allCases) { effect in
                            NavigationLink(value: effect) { EffectRow(effect: effect) }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .background(Color.carouselBackground)
        .navigationTitle("Shaders")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.snappy) { layout = layout == .grid ? .list : .grid }
                } label: {
                    Label(layout == .grid ? "Show as List" : "Show as Grid",
                          systemImage: layout == .grid ? "list.bullet" : "square.grid.2x2")
                }
            }
        }
        .navigationDestination(for: ShaderEffect.self) { effect in
            effect.destination
        }
    }
}

private struct EffectTile: View {
    let effect: ShaderEffect

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            effect.preview
                .frame(height: 210)
                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
            EffectCaption(effect: effect)
                .padding(.horizontal, 4)
        }
        .padding(8)
        .background(.white, in: .rect(cornerRadius: 24, style: .continuous))
        .contentShape(.rect(cornerRadius: 24, style: .continuous))
    }
}

private struct EffectRow: View {
    let effect: ShaderEffect

    var body: some View {
        HStack(spacing: 14) {
            effect.preview
                .frame(width: 96, height: 96)
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            EffectCaption(effect: effect)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(.white, in: .rect(cornerRadius: 22, style: .continuous))
        .contentShape(.rect(cornerRadius: 22, style: .continuous))
    }
}

private struct EffectCaption: View {
    let effect: ShaderEffect

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(effect.title)
                .font(.headline)
            Text(effect.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(effect.variants)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }
}

/// The carousel effect, with a switch between its styles.
struct CarouselShowcaseView: View {
    @State private var style: CarouselStyle = .flip
    // Shared so the position survives the cross-fade between styles.
    @State private var motion = CarouselMotion()
    private let cards = DemoCard.allCases

    var body: some View {
        ZStack {
            CardCarousel(count: cards.count, style: style, motion: motion,
                         accessibilityName: { cards[$0].accessibilityName }) { index in
                cards[index].view
            }
            .id(style)
            .transition(.opacity)
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            Text("Drag, tap or use ← →")
                .font(.system(size: 14))
                .foregroundStyle(Color(white: 0.45))
                .padding(.bottom, 8)
                .accessibilityHidden(true)
        }
        .background(Color.carouselBackground)
        .navigationTitle(ShaderEffect.carousel.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Style", selection: $style.animation(.easeInOut(duration: 0.35))) {
                    ForEach(CarouselStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }
}

#Preview {
    NavigationStack {
        ShaderCatalogView()
    }
}
