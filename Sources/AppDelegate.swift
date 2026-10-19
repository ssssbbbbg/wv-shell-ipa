//
//  AppDelegate.swift
//  PokeBonk (iPad, offline WKWebView shell)
//
//  Pure-code app: no storyboard, no xib. Scene lifecycle lives in SceneDelegate.
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // WebGL (Metal ANGLE) is always on in the public WebKit on iOS 15+, and this
        // build must not touch private defaults. Nothing else to configure here: the
        // game is fully local, there is no background networking and no push.
        _ = application
        _ = launchOptions
        return true
    }

    // MARK: - UIScene lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        // Set here as well as in Info.plist: plist is authoritative, class is a belt.
        config.delegateClass = SceneDelegate.self
        return config
    }

    // iPad multi-window is disabled in Info.plist (UIApplicationSupportsMultipleScenes = NO).
    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {}
}
