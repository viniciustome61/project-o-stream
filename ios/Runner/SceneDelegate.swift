import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        print("[PO] SceneDelegate.scene willConnectTo - calling super")
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        print("[PO] super returned. self.window=\(String(describing: self.window))")

        let rootWindow = self.window
            ?? (scene as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow })
            ?? (scene as? UIWindowScene)?.windows.first

        print("[PO] rootWindow=\(String(describing: rootWindow))")
        print("[PO] rootVC=\(String(describing: rootWindow?.rootViewController))")

        guard let window = rootWindow,
              let controller = window.rootViewController as? FlutterViewController,
              let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            print("[PO] GUARD FAILED - rootVC type: \(type(of: rootWindow?.rootViewController))")
            return
        }

        print("[PO] FlutterViewController found - delegating native surface install")
        appDelegate.installNativeSurface(in: window, controller: controller)
    }
}
