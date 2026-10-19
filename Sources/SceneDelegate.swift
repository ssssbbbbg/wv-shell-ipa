//
//  SceneDelegate.swift
//  PokeBonk
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Landscape lock is enforced by Info.plist (UISupportedInterfaceOrientations~ipad
        // = landscape only) + UIRequiresFullScreen. requestGeometryUpdate() is not used
        // on purpose: during willConnectTo the scene has no interface yet, so the call
        // is a no-op and only spams the system log.
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = GameWebViewController()
        // Opaque black: avoids a white flash between launch and the first WebGL frame.
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        controller?.restoreWebState()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        controller?.setPageVisible(true)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        controller?.setPageVisible(false)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Give the page a chance to flush localStorage / IndexedDB before suspension.
        controller?.persistWebState()
    }

    private var controller: GameWebViewController? {
        window?.rootViewController as? GameWebViewController
    }
}
