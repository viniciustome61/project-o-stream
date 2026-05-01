import AVFoundation
import UIKit
import HaishinKit

@MainActor
final class CameraController: NSObject {
    let previewView = PreviewHostView()

    private let connection = SRTConnection()
    private lazy var stream: SRTStream = SRTStream(connection: connection)
    private lazy var hkView = MTHKView(frame: .zero)
    private var streaming = false

    func configure() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw NSError(domain: "ProjectOStream", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Camera permission denied"])
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw NSError(domain: "ProjectOStream", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }

        stream.attachCamera(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back))
        stream.attachAudio(AVCaptureDevice.default(for: .audio))
        
        // Match quality profiles from Flutter
        stream.videoSettings.videoSize = .init(width: 3840, height: 2160)
        stream.videoSettings.bitrate = 12 * 1000 * 1000 // 12Mbps default
        stream.videoSettings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
        
        hkView.videoGravity = .resizeAspect
        hkView.attachStream(stream)
        
        previewView.addSubview(hkView)
        hkView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hkView.topAnchor.constraint(equalTo: previewView.topAnchor),
            hkView.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),
            hkView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            hkView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor)
        ])
    }

    func startPreview() async throws {
        // HaishinKit starts capture when attached
    }

    func startStream(config: [String: Any]) async throws {
        let host = config["host"] as? String ?? ""
        let port = config["port"] as? Int ?? 7070
        let latencyMs = config["latencyMs"] as? Int ?? 80
        
        let profile = config["profile"] as? [String: Any]
        let width = profile?["width"] as? Int ?? 3840
        let height = profile?["height"] as? Int ?? 2160
        let bitrate = profile?["bitrate"] as? Int ?? 12000000
        
        stream.videoSettings.videoSize = .init(width: width, height: height)
        stream.videoSettings.bitrate = bitrate
        
        let url = "srt://\(host):\(port)?mode=caller&latency=\(latencyMs)"
        connection.connect(url)
        stream.publish()
        streaming = true
    }

    func stopStream() {
        stream.close()
        connection.close()
        streaming = false
    }

    func stop() {
        stopStream()
    }

    func switchCamera() async throws {
        let position: AVCaptureDevice.Position = stream.videoSettings.device?.position == .back ? .front : .back
        stream.attachCamera(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position))
    }

    func setTorch(_ enabled: Bool) throws {
        guard let device = stream.videoSettings.device, device.hasTorch else { return }
        try device.lockForConfiguration()
        device.torchMode = enabled ? .on : .off
        device.unlockForConfiguration()
    }

    func setZoom(_ value: CGFloat) throws {
        guard let device = stream.videoSettings.device else { return }
        try device.lockForConfiguration()
        device.videoZoomFactor = min(max(value, 1), device.activeFormat.videoMaxZoomFactor)
        device.unlockForConfiguration()
    }
}

final class PreviewHostView: UIView {
    // Container for HaishinKit view
}
