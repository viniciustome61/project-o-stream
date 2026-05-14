import Flutter
import UIKit

@objc class SceneDelegate: FlutterSceneDelegate {
    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        print("[PO] SceneDelegate willConnectTo - calling FlutterSceneDelegate")
        super.scene(scene, willConnectTo: session, options: connectionOptions)

        guard let windowScene = scene as? UIWindowScene else { return }
        let window = self.window ?? windowScene.windows.first ?? UIWindow(windowScene: windowScene)
        if window.rootViewController == nil {
            window.rootViewController = UIStoryboard(name: "Main", bundle: nil).instantiateInitialViewController()
        }
        self.window = window
        window.makeKeyAndVisible()

        guard let controller = window.rootViewController as? FlutterViewController,
              let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            print("[PO] Flutter root view controller was not available in SceneDelegate")
            return
        }

        appDelegate.installNativeSurface(in: window, controller: controller)
    }
}
