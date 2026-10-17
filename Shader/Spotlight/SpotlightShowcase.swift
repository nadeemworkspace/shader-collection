//
//  SpotlightShowcase.swift
//  Shader
//

import SwiftUI

/// Demo screen: a plain white page that the offer spotlight pops up over. It opens with
/// the offer showing; close it to see the screen, and bring it back from there.
struct SpotlightShowcaseView: View {
    @State private var isOfferPresented = false
    @State private var hasOpened = false

    var body: some View {
        Button("Show Offer", systemImage: "gift") { setOfferPresented(true) }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(SpotlightDesign.blues[0])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white)
            .navigationTitle(ShaderEffect.spotlight.title)
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $isOfferPresented) {
                SpotlightOverlay { setOfferPresented(false) }
                    .presentationBackground(.clear)
                    // Light status bar over the scrim.
                    .preferredColorScheme(.dark)
            }
            .task {
                // Wait for the push to settle before covering it.
                guard !hasOpened else { return }
                try? await Task.sleep(for: .seconds(0.4))
                guard !Task.isCancelled else { return }
                hasOpened = true
                setOfferPresented(true)
            }
    }

    /// Skips the cover's slide-up: the overlay animates itself in and out.
    private func setOfferPresented(_ presented: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isOfferPresented = presented }
    }
}

/// Catalog preview: the spotlight, scaled down to fit.
struct SpotlightPreview: View {
    var body: some View {
        GeometryReader { proxy in
            // Lay out with some room around the card, then scale the whole stage down.
            let scale = min(proxy.size.width / 300, proxy.size.height / 340)
            SpotlightStage()
                .frame(width: proxy.size.width / scale, height: proxy.size.height / scale)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(.white)
        // Taps go to whatever contains the preview (e.g. a navigation link).
        .allowsHitTesting(false)
    }
}

#Preview {
    NavigationStack {
        SpotlightShowcaseView()
    }
}
