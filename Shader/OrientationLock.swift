//
//  OrientationLock.swift
//  Shader
//
//  Lets a screen limit the window's interface orientations while it is shown. SwiftUI has
//  no per-view orientation API, so the window scene's delegate reports whatever the
//  screen on top asks for, and falls back to the app's Info.plist orientations.
//
//  iPhone only in practice: iPad windows that support multitasking resize freely and
//  the system ignores orientation limits.
//

import SwiftUI
import UIKit

extension View {
    /// Limits the window to `orientations` while this view is on screen, rotating to one
    /// of them if needed, and lifts the limit when the view goes away.
    func supportedInterfaceOrientations(_ orientations: UIInterfaceOrientationMask) -> some View {
        modifier(OrientationLockModifier(orientations: orientations))
    }
}

private struct OrientationLockModifier: ViewModifier {
    let orientations: UIInterfaceOrientationMask

    func body(content: Content) -> some View {
        content
            .onAppear { OrientationLock.restrict(to: orientations) }
            .onDisappear { OrientationLock.restrict(to: nil) }
    }
}

enum OrientationLock {
    /// What the window scenes currently allow.
    static var supported: UIInterfaceOrientationMask { restriction ?? appDefault }

    private static var restriction: UIInterfaceOrientationMask?

    /// The orientations from Info.plist (`UISupportedInterfaceOrientations`, already
    /// resolved for the current device).
    private static let appDefault: UIInterfaceOrientationMask = {
        let names = Bundle.main.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String] ?? []
        let mask = names.reduce(into: UIInterfaceOrientationMask()) { mask, name in
            switch name {
            case "UIInterfaceOrientationPortrait": mask.insert(.portrait)
            case "UIInterfaceOrientationPortraitUpsideDown": mask.insert(.portraitUpsideDown)
            case "UIInterfaceOrientationLandscapeLeft": mask.insert(.landscapeLeft)
            case "UIInterfaceOrientationLandscapeRight": mask.insert(.landscapeRight)
            default: break
            }
        }
        if !mask.isEmpty { return mask }
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }()

    /// - Parameter orientations: the orientations to allow, or `nil` for the app's own.
    static func restrict(to orientations: UIInterfaceOrientationMask?) {
        guard orientations != restriction else { return }
        restriction = orientations
        let mask = supported
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            // Re-reads `supported`; rotates back to the device's orientation if it is
            // allowed again.
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !mask.contains(scene.effectiveGeometry.interfaceOrientation.mask) {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            }
        }
    }
}

private extension UIInterfaceOrientation {
    var mask: UIInterfaceOrientationMask {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: []
        }
    }
}

// MARK: - App and scene delegates

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// SwiftUI still drives the window; it forwards these calls to this class.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func supportedInterfaceOrientations(for windowScene: UIWindowScene) -> UIInterfaceOrientationMask {
        OrientationLock.supported
    }
}
