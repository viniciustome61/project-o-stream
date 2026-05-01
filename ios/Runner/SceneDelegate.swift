import UIKit
import Flutter

@objc class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        window.makeKeyAndVisible()
        
        if let rootViewController = window.rootViewController as? FlutterViewController,
           let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            appDelegate.installNativeSurface(in: window, controller: rootViewController)
        }
    }
}
