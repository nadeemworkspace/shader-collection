//
//  ShaderApp.swift
//  Shader
//
//  Created by Nadeem M A, Muhammed on 07/10/26.
//

import SwiftUI

@main
struct ShaderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ShaderCatalogView()
            }
            .preferredColorScheme(.light)
        }
    }
}
