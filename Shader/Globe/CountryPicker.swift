//
//  CountryPicker.swift
//  Shader
//

import SwiftUI

/// Country selection over a dotted Metal globe: pick a region to turn the globe to it
/// and light it up, then a country to fly in and reveal it. Tapping the globe picks the
/// country under your finger; dragging turns it while zoomed out.
struct CountryPickerView: View {
    @State private var globe = GlobeController()
    @State private var isDragging = false
    @GestureState private var isGestureActive = false
    @AppStorage(GlobeTheme.storageKey) private var theme: GlobeTheme = .light
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            // The globe sits behind this gap; the slot only positions it.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { globe.setGlobeSlot($0) }
            controls
        }
        .background {
            ZStack {
                GlobeView(controller: globe, theme: theme)
                Color.clear
                    .contentShape(.rect)
                    .gesture(globeGesture)
            }
            .ignoresSafeArea()
            .accessibilityElement()
            .accessibilityLabel("Globe")
            .accessibilityValue(globe.country?.name ?? globe.region?.title ?? "World")
        }
        .background(theme.background)
        .environment(\.colorScheme, theme.colorScheme)
        // Keyed to the value: writes to `@AppStorage` don't carry `withAnimation`'s
        // transaction. Matches the globe's own fade.
        .animation(.easeInOut(duration: 0.35), value: theme)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    theme = theme == .light ? .dark : .light
                } label: {
                    Label(theme == .light ? "Dark Appearance" : "Light Appearance",
                          systemImage: theme == .light ? "moon.fill" : "sun.max.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .onChange(of: reduceMotion, initial: true) { globe.reduceMotion = reduceMotion }
        .onChange(of: isGestureActive) { _, active in
            // The system cancelled the drag (no `onEnded`): let the globe settle.
            if !active, isDragging {
                isDragging = false
                globe.endDrag(velocity: .zero)
            }
        }
        .task { await globe.load() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Select your country")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Choose a region, then a country")
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.5))
        }
        .multilineTextAlignment(.center)
        .padding(.top, 6)
        .padding(.horizontal, 24)
    }

    private var controls: some View {
        VStack(spacing: 20) {
            RegionStrip(thumbnails: globe.atlas?.thumbnails ?? [:], selection: globe.region) { region in
                globe.toggle(region)
            }
            CountryStrip(countries: globe.atlas?.countries(in: globe.region) ?? [],
                         listID: globe.region,
                         selection: globe.country) { country in
                globe.toggle(country)
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background {
            // Dots fade out as they reach the controls.
            LinearGradient(stops: [.init(color: theme.background.opacity(0), location: 0),
                                   .init(color: theme.background, location: 0.4)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -64)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }

    private var globeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($isGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                let travel = abs(value.translation.width) + abs(value.translation.height)
                guard isDragging || travel > 8 else { return }
                isDragging = true
                globe.drag(by: value.translation)
            }
            .onEnded { value in
                if isDragging {
                    isDragging = false
                    globe.endDrag(velocity: value.velocity)
                } else {
                    globe.tap(at: value.location)
                }
            }
    }
}

// MARK: - Regions

private struct RegionStrip: View {
    let thumbnails: [GlobeRegion: [SIMD2<Float>]]
    let selection: GlobeRegion?
    let onSelect: (GlobeRegion) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(GlobeRegion.allCases) { region in
                    let isSelected = region == selection
                    Button {
                        onSelect(region)
                    } label: {
                        VStack(spacing: 8) {
                            RegionThumbnail(dots: thumbnails[region] ?? [], isSelected: isSelected)
                                .frame(width: 56, height: 34)
                            Text(region.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(.primary.opacity(isSelected ? 1 : 0.35))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .frame(width: 86)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(region.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .animation(.easeOut(duration: 0.25), value: selection)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 10, for: .scrollContent)
    }
}

/// The region's land as a small dot map.
private struct RegionThumbnail: View {
    let dots: [SIMD2<Float>]
    let isSelected: Bool

    var body: some View {
        Canvas { context, size in
            let radius = 0.62
            var path = Path()
            for dot in dots {
                let x = Double(dot.x) * size.width
                let y = Double(dot.y) * size.height
                path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
            }
            context.fill(path, with: .foreground)
        }
        .foregroundStyle(.primary)
        .opacity(isSelected ? 0.9 : 0.3)
        .accessibilityHidden(true)
    }
}

// MARK: - Countries

private struct CountryStrip: View {
    let countries: [Country]
    /// Identifies the list; the strip starts over when it changes.
    let listID: GlobeRegion?
    let selection: Country?
    let onSelect: (Country) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(countries) { country in
                        CountryChip(country: country, isSelected: country == selection) {
                            onSelect(country)
                        }
                        .id(country.id)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .id(listID)
            .transition(.opacity)
            .onChange(of: selection) { _, country in
                guard let country else { return }
                withAnimation(.smooth(duration: 0.45)) {
                    proxy.scrollTo(country.id, anchor: .center)
                }
            }
            .onChange(of: listID) {
                if let selection {
                    proxy.scrollTo(selection.id, anchor: .center)
                }
            }
        }
        .frame(height: 48)
        .animation(.easeInOut(duration: 0.25), value: listID)
    }
}

private struct CountryChip: View {
    let country: Country
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                Text(country.flag)
                    .font(.system(size: 19))
                    .accessibilityHidden(true)
                Text(country.name)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(isSelected ? 1 : 0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .background(.primary.opacity(isSelected ? 0.14 : 0.07), in: shape)
            .overlay {
                shape.strokeBorder(.primary.opacity(isSelected ? 0.3 : 0), lineWidth: 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Catalog preview

/// A slowly turning, non-interactive globe for the catalog.
struct GlobePreview: View {
    @State private var globe = GlobeController()
    @AppStorage(GlobeTheme.storageKey) private var theme: GlobeTheme = .light
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlobeView(controller: globe, theme: theme)
            .background(theme.background)
            .onChange(of: reduceMotion, initial: true) { globe.reduceMotion = reduceMotion }
            .task { await globe.load() }
    }
}

#Preview {
    NavigationStack {
        CountryPickerView()
    }
}
