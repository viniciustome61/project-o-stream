import UIKit
import Flutter

@objc class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        let window = self.window ?? UIWindow(windowScene: windowScene)
        window.windowScene = windowScene

        if window.rootViewController == nil {
            window.rootViewController = UIStoryboard(name: "Main", bundle: nil).instantiateInitialViewController()
        }

        self.window = window
        window.makeKeyAndVisible()

        if let rootViewController = window.rootViewController as? FlutterViewController,
           let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.installNativeSurface(in: window, controller: rootViewController)
        } else {
            print("[PO] Flutter root view controller was not available in SceneDelegate")
        }
    }
}
