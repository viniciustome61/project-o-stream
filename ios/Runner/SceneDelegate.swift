import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
    override func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        print("[PO] SceneDelegate.scene willConnectTo — calling super")
        super.scene(scene, willConnectTo: session, options: connectionOptions)
        print("[PO] super returned. self.window=\(String(describing: self.window))")

        let rootWindow = self.window
            ?? (scene as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow })
            ?? (scene as? UIWindowScene)?.windows.first

        print("[PO] rootWindow=\(String(describing: rootWindow))")
        print("[PO] rootVC=\(String(describing: rootWindow?.rootViewController))")

        guard let controller = rootWindow?.rootViewController as? FlutterViewController,
              let appDelegate = UIApplication.shared.delegate as? AppDelegate else {
            print("[PO] GUARD FAILED — channels NOT registered. rootVC type: \(type(of: rootWindow?.rootViewController))")
            return
        }

        print("[PO] FlutterViewController found — registering channels")
        let messenger = controller.binaryMessenger

        FlutterMethodChannel(name: "project_o_stream/native", binaryMessenger: messenger)
            .setMethodCallHandler { [weak appDelegate] call, result in
                print("[PO] MethodChannel call: \(call.method)")
                appDelegate?.handle(call: call, result: result)
            }

        FlutterEventChannel(name: "project_o_stream/events", binaryMessenger: messenger)
            .setStreamHandler(appDelegate)

        controller.registrar(forPlugin: "ProjectOStreamPreview")?.register(
            PreviewFactory(camera: appDelegate.camera),
            withId: "project_o_stream/preview"
        )
        print("[PO] Channels + platform view factory registered OK")
    }
}
