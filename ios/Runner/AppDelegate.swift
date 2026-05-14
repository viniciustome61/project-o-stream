import AVFoundation
import Flutter
import UIKit

@UIApplicationMain
class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
    var eventSink: FlutterEventSink?
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var nativeBridgeRegistered = false
    private var nativePreviewRegistered = false
    private var camera: CameraController?
    private var bootOverlay: UIView?
    private weak var bootOverlayLabel: UILabel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        registerNativePreviewFactory()

        let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.installNativeBridgeWhenFlutterViewIsReady()
        }
        return launched
    }

    func registerNativeBridge(messenger: FlutterBinaryMessenger) {
        guard !nativeBridgeRegistered else { return }
        nativeBridgeRegistered = true

        print("[PO] registering native method/event channels")
        let methods = FlutterMethodChannel(name: "project_o_stream/native", binaryMessenger: messenger)
        methods.setMethodCallHandler { [weak self] call, result in
            print("[PO] MethodChannel call: \(call.method)")
            self?.handle(call: call, result: result)
        }
        methodChannel = methods

        let events = FlutterEventChannel(name: "project_o_stream/events", binaryMessenger: messenger)
        events.setStreamHandler(self)
        eventChannel = events

        print("[PO] native streaming bridge registered")
    }

    @MainActor
    private func nativeCamera() -> CameraController {
        if let camera = camera {
            return camera
        }
        let camera = CameraController()
        self.camera = camera
        print("[PO] CameraController initialized")
        return camera
    }

    @MainActor
    private func registerNativePreviewFactory() {
        guard !nativePreviewRegistered else { return }
        let previewRegistrar = registrar(forPlugin: "ProjectONativePreview")
        previewRegistrar.register(
            PreviewFactory(camera: nativeCamera()),
            withId: "project_o_stream/preview"
        )
        nativePreviewRegistered = true
        print("[PO] native preview platform view registered")
    }

    private func installNativeBridgeWhenFlutterViewIsReady() {
        if installNativeBridgeOnCurrentRootController() {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.installNativeBridgeOnCurrentRootController() {
                print("[PO] Flutter root view controller was not available after launch")
            }
        }
    }

    @discardableResult
    private func installNativeBridgeOnCurrentRootController() -> Bool {
        guard let window = window,
              let controller = window.rootViewController as? FlutterViewController else {
            print("[PO] waiting for Flutter root view controller. window=\(String(describing: window)), root=\(String(describing: window?.rootViewController))")
            return false
        }

        installNativeSurface(in: window, controller: controller)
        return true
    }

    func installNativeSurface(in window: UIWindow, controller: FlutterViewController) {
        print("[PO] FlutterViewController ready - installing native bridge, preview, and visible boot overlay")
        controller.isViewOpaque = false
        controller.splashScreenView = nil
        controller.view.isOpaque = false
        controller.view.backgroundColor = .clear

        registerNativeBridge(messenger: controller.binaryMessenger)
        registerNativePreviewFactory()
        installBootOverlay(in: window, status: "native boot ok")
    }

    private func installBootOverlay(in window: UIWindow, status: String) {
        if let bootOverlay {
            window.bringSubviewToFront(bootOverlay)
            updateBootOverlay(status)
            return
        }

        let overlay = UIView(frame: CGRect(x: 12, y: 54, width: window.bounds.width - 24, height: 54))
        overlay.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        overlay.backgroundColor = UIColor(red: 0.86, green: 0.09, blue: 0.13, alpha: 0.96)
        overlay.layer.cornerRadius = 10
        overlay.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
        overlay.layer.borderWidth = 1
        overlay.isUserInteractionEnabled = false

        let title = UILabel(frame: CGRect(x: 12, y: 7, width: overlay.bounds.width - 24, height: 18))
        title.autoresizingMask = [.flexibleWidth]
        title.text = "Project O Stream"
        title.textColor = .white
        title.font = .boldSystemFont(ofSize: 15)
        overlay.addSubview(title)

        let label = UILabel(frame: CGRect(x: 12, y: 28, width: overlay.bounds.width - 24, height: 17))
        label.autoresizingMask = [.flexibleWidth]
        label.textColor = UIColor.white.withAlphaComponent(0.88)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        overlay.addSubview(label)

        window.addSubview(overlay)
        window.bringSubviewToFront(overlay)
        bootOverlay = overlay
        bootOverlayLabel = label
        updateBootOverlay(status)
    }

    private func updateBootOverlay(_ status: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        bootOverlayLabel?.text = "\(status) | iOS \(UIDevice.current.systemVersion) | v\(version)"
    }

    private func removeBootOverlay() {
        bootOverlay?.removeFromSuperview()
        bootOverlay = nil
        bootOverlayLabel = nil
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        Task { @MainActor in
            do {
                switch call.method {
                case "initialize":
                    print("[PO] initialize() called")
                    do {
                        try await nativeCamera().configure(includeAudio: false)
                        send(status: "Ready", live: false)
                        result(nil)
                    } catch {
                        print("[PO] initialize() failed: \(error)")
                        throw error
                    }
                case "flutterRendered":
                    print("[PO] Flutter reported first rendered frame")
                    removeBootOverlay()
                    result(nil)
                case "startPreview":
                    print("[PO] startPreview() called")
                    do {
                        try await nativeCamera().startPreview()
                        send(status: "Preview", live: false)
                        result(nil)
                    } catch {
                        print("[PO] startPreview() failed: \(error)")
                        throw error
                    }
                case "stopPreview":
                    camera?.stop()
                    send(status: "Preview stopped", live: false)
                    result(nil)
                case "loadEndpoint":
                    let defaults = UserDefaults.standard
                    var endpoint: [String: Any] = [:]
                    if let host = defaults.string(forKey: "project_o_stream.host") {
                        endpoint["host"] = host
                    }
                    if defaults.object(forKey: "project_o_stream.port") != nil {
                        endpoint["port"] = defaults.integer(forKey: "project_o_stream.port")
                    }
                    result(endpoint)
                case "saveEndpoint":
                    guard let args = call.arguments as? [String: Any],
                          let host = args["host"] as? String,
                          let port = args["port"] as? Int else {
                        throw StreamError.invalidArguments
                    }
                    let defaults = UserDefaults.standard
                    defaults.set(host.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "project_o_stream.host")
                    defaults.set(port, forKey: "project_o_stream.port")
                    result(nil)
                case "getCapabilities":
                    result([
                        "platform": "ios",
                        "preview": true,
                        "srt": true,
                        "hevc": true,
                        "torch": true,
                        "zoom": true,
                        "transportStatus": "SRT sender available via HaishinKit",
                        "device": UIDevice.current.model,
                        "os": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
                    ])
                case "startStream":
                    guard let args = call.arguments as? [String: Any] else {
                        throw StreamError.invalidArguments
                    }
                    try await nativeCamera().startStream(config: args)
                    send(status: "Live", live: true)
                    result(nil)
                case "stopStream":
                    await camera?.stopStream()
                    send(status: "Ready", live: false)
                    result(nil)
                case "switchCamera":
                    try await nativeCamera().switchCamera()
                    send(status: "Camera switched", live: camera?.isStreaming == true)
                    result(nil)
                case "setTorch":
                    let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
                    try await nativeCamera().setTorch(enabled)
                    send(status: enabled ? "Torch on" : "Torch off", live: camera?.isStreaming == true)
                    result(nil)
                case "setZoom":
                    let value = (call.arguments as? [String: Any])?["value"] as? Double ?? 1
                    try await nativeCamera().setZoom(CGFloat(value))
                    send(status: String(format: "Zoom %.1fx", value), live: camera?.isStreaming == true)
                    result(nil)
                case "setKeepScreenOn":
                    let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
                    UIApplication.shared.isIdleTimerDisabled = enabled
                    send(status: enabled ? "Screen awake lock on" : "Screen awake lock off", live: camera?.isStreaming == true)
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            } catch {
                result(FlutterError(code: "native_error", message: error.localizedDescription, details: nil))
            }
        }
    }

    func send(status: String, live: Bool) {
        eventSink?(["status": status, "live": live, "stats": ""])
    }
}

enum StreamError: LocalizedError {
    case invalidArguments
    case srtTransportUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Invalid stream configuration."
        case .srtTransportUnavailable:
            return "iOS SRT transport requires linking libsrt.xcframework in the iOS build."
        }
    }
}
