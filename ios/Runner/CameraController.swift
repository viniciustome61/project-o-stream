import AVFoundation
import HaishinKit
import SRTHaishinKit
import UIKit
import VideoToolbox

@MainActor
final class CameraController: NSObject {
    let previewView = PreviewHostView()

    private let connection = SRTConnection()
    private lazy var stream = SRTStream(connection: connection)
    private lazy var mixer = MediaMixer()
    private lazy var hkView = MTHKView(frame: .zero)
    private var cameraPosition: AVCaptureDevice.Position = .back
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

        try await mixer.attachVideo(
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            track: 0
        )
        try await mixer.attachAudio(AVCaptureDevice.default(for: .audio), track: 0)

        try await stream.setVideoSettings(VideoCodecSettings(
            videoSize: CGSize(width: 3840, height: 2160),
            bitRate: 12 * 1_000_000,
            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String
        ))

        await mixer.addOutput(hkView)
        hkView.videoGravity = .resizeAspect
        // Give hkView the parent's current bounds as its initial frame so CAMetalLayer
        // has a non-zero size before Auto Layout takes over. Without this the Metal layer
        // can initialise at {0,0} and never render frames even after constraints are set.
        hkView.frame = previewView.bounds.isEmpty
            ? CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
            : previewView.bounds
        previewView.addSubview(hkView)
        hkView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hkView.topAnchor.constraint(equalTo: previewView.topAnchor),
            hkView.bottomAnchor.constraint(equalTo: previewView.bottomAnchor),
            hkView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            hkView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
        ])
        previewView.layoutIfNeeded()
    }

    func startPreview() async throws {
        // Capture starts automatically once devices are attached to the mixer.
    }

    func startStream(config: [String: Any]) async throws {
        let host = config["host"] as? String ?? ""
        let port = config["port"] as? Int ?? 7070
        let latencyMs = config["latencyMs"] as? Int ?? 80

        let profile = config["profile"] as? [String: Any]
        let width = profile?["width"] as? Int ?? 3840
        let height = profile?["height"] as? Int ?? 2160
        let bitrate = profile?["bitrate"] as? Int ?? 12_000_000

        try await stream.setVideoSettings(VideoCodecSettings(
            videoSize: CGSize(width: CGFloat(width), height: CGFloat(height)),
            bitRate: bitrate,
            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String
        ))

        await mixer.addOutput(stream)

        guard let url = URL(string: "srt://\(host):\(port)?mode=caller&latency=\(latencyMs)") else {
            throw StreamError.invalidArguments
        }
        try await connection.connect(url)
        await stream.publish()
        streaming = true
    }

    func stopStream() {
        Task {
            await stream.close()
            await connection.close()
        }
        streaming = false
    }

    func stop() {
        stopStream()
    }

    func switchCamera() async throws {
        cameraPosition = cameraPosition == .back ? .front : .back
        try await mixer.attachVideo(
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition),
            track: 0
        )
    }

    func setTorch(_ enabled: Bool) async throws {
        try await mixer.configuration(video: 0) { unit in
            guard let device = unit.device, device.hasTorch else { return }
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            device.unlockForConfiguration()
        }
    }

    func setZoom(_ value: CGFloat) async throws {
        try await mixer.configuration(video: 0) { unit in
            guard let device = unit.device else { return }
            try device.lockForConfiguration()
            device.videoZoomFactor = min(max(value, 1), device.activeFormat.videoMaxZoomFactor)
            device.unlockForConfiguration()
        }
    }
}

final class PreviewHostView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep Metal sublayers in sync when Flutter resizes this view.
        subviews.forEach { $0.frame = bounds }
    }
}
