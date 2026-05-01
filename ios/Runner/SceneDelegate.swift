import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // Flutter creates the UIWindow + FlutterViewController and assigns self.window.
        super.scene(scene, willConnectTo: session, options: connectionOptions)

        // Prefer the UIWindowSceneDelegate property; fall back to scene's window list.
        let rootWindow = self.window
            ?? (scene as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow })
            ?? (scene as? UIWindowScene)?.windows.first

        guard let controller = rootWindow?.rootViewController as? FlutterViewController,
              let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            return
        }

        let messenger = controller.binaryMessenger

        FlutterMethodChannel(name: "project_o_stream/native", binaryMessenger: messenger)
            .setMethodCallHandler { [weak appDelegate] call, result in
                appDelegate?.handle(call: call, result: result)
            }

        FlutterEventChannel(name: "project_o_stream/events", binaryMessenger: messenger)
            .setStreamHandler(appDelegate)

        controller.registrar(forPlugin: "ProjectOStreamPreview")?.register(
            PreviewFactory(camera: appDelegate.camera),
            withId: "project_o_stream/preview"
        )
    }
}
