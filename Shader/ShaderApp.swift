//
//  ShaderApp.swift
//  Shader
//
//  Created by Nadeem M A, Muhammed on 07/10/26.
//

import SwiftUI

@main
struct ShaderApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ShaderCatalogView()
            }
            .preferredColorScheme(.light)
        }
    }
}
