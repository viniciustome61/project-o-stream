import AVFoundation
import Flutter
import UIKit

@UIApplicationMain
class AppDelegate: FlutterAppDelegate, FlutterStreamHandler {
    private let camera = CameraController()
    private var eventSink: FlutterEventSink?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController
        let messenger = controller.binaryMessenger

        FlutterMethodChannel(name: "project_o_stream/native", binaryMessenger: messenger)
            .setMethodCallHandler { [weak self] call, result in
                self?.handle(call: call, result: result)
            }

        FlutterEventChannel(name: "project_o_stream/events", binaryMessenger: messenger)
            .setStreamHandler(self)

        controller.registrar(forPlugin: "ProjectOStreamPreview")?.register(
            PreviewFactory(camera: camera),
            withId: "project_o_stream/preview"
        )

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        Task { @MainActor in
            do {
                switch call.method {
                case "initialize":
                    try await camera.configure()
                    send(status: "Ready", live: false)
                    result(nil)
                case "startPreview":
                    try await camera.startPreview()
                    send(status: "Preview", live: false)
                    result(nil)
                case "stopPreview":
                    camera.stop()
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
                    try await camera.startStream(config: args)
                    send(status: "Live", live: true)
                    result(nil)
                case "stopStream":
                    camera.stopStream()
                    send(status: "Ready", live: false)
                    result(nil)
                case "switchCamera":
                    try await camera.switchCamera()
                    send(status: "Camera switched", live: false)
                    result(nil)
                case "setTorch":
                    let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
                    try await camera.setTorch(enabled)
                    send(status: enabled ? "Torch on" : "Torch off", live: false)
                    result(nil)
                case "setZoom":
                    let value = (call.arguments as? [String: Any])?["value"] as? Double ?? 1
                    try await camera.setZoom(CGFloat(value))
                    send(status: String(format: "Zoom %.1fx", value), live: false)
                    result(nil)
                case "setKeepScreenOn":
                    let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
                    UIApplication.shared.isIdleTimerDisabled = enabled
                    send(status: enabled ? "Screen awake lock on" : "Screen awake lock off", live: false)
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            } catch {
                result(FlutterError(code: "native_error", message: error.localizedDescription, details: nil))
            }
        }
    }

    private func send(status: String, live: Bool) {
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
