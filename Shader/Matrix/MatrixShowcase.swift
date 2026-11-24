//
//  MatrixShowcase.swift
//  Shader
//

import SwiftUI

/// Demo screen: the rain across the whole screen, in any orientation. Tap to hide the
/// navigation and status bars, and again to bring them back.
struct MatrixShowcaseView: View {
    @State private var isChromeHidden = false

    var body: some View {
        MatrixRainView()
            .ignoresSafeArea()
            .overlay {
                Color.clear
                    .contentShape(.rect)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { isChromeHidden.toggle() }
                    }
            }
            .background(.black)
            .accessibilityElement()
            .accessibilityLabel("Green katakana, letters and digits raining down the screen")
            .accessibilityAction(named: isChromeHidden ? "Show Navigation Bar" : "Hide Navigation Bar") {
                isChromeHidden.toggle()
            }
            .navigationTitle(ShaderEffect.matrix.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarVisibility(isChromeHidden ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(isChromeHidden)
            .persistentSystemOverlays(isChromeHidden ? .hidden : .automatic)
            .supportedInterfaceOrientations(.all)
    }
}

/// Catalog preview: the rain with smaller glyphs, at a calmer frame rate.
struct MatrixPreview: View {
    var body: some View {
        MatrixRainView(scale: 0.75, framesPerSecond: 30)
            .background(.black)
            .allowsHitTesting(false)
    }
}

#Preview {
    NavigationStack {
        MatrixShowcaseView()
    }
}
