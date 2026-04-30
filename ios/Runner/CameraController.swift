import AVFoundation
import UIKit

@MainActor
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let previewView = PreviewHostView()

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "project-o-camera")
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
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
        session.beginConfiguration()
        session.sessionPreset = .hd4K3840x2160
        try configureVideo(position: .back)
        try configureAudio()
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        let audioOutput = AVCaptureAudioDataOutput()
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        session.commitConfiguration()
        previewView.layer.session = session
        previewView.layer.videoGravity = .resizeAspect
    }

    func startPreview() async throws {
        if !session.isRunning {
            queue.async { self.session.startRunning() }
        }
    }

    func startStream(config: [String: Any]) async throws {
        streaming = true
        throw StreamError.srtTransportUnavailable
    }

    func stopStream() {
        streaming = false
    }

    func stop() {
        streaming = false
        if session.isRunning {
            queue.async { self.session.stopRunning() }
        }
    }

    func switchCamera() async throws {
        let next: AVCaptureDevice.Position = videoInput?.device.position == .back ? .front : .back
        session.beginConfiguration()
        if let videoInput { session.removeInput(videoInput) }
        try configureVideo(position: next)
        session.commitConfiguration()
    }

    func setTorch(_ enabled: Bool) throws {
        guard let device = videoInput?.device, device.hasTorch else { return }
        try device.lockForConfiguration()
        device.torchMode = enabled ? .on : .off
        device.unlockForConfiguration()
    }

    func setZoom(_ value: CGFloat) throws {
        guard let device = videoInput?.device else { return }
        try device.lockForConfiguration()
        device.videoZoomFactor = min(max(value, 1), device.activeFormat.videoMaxZoomFactor)
        device.unlockForConfiguration()
    }

    private func configureVideo(position: AVCaptureDevice.Position) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw NSError(domain: "ProjectOStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera not found"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
            videoInput = input
        }
    }

    private func configureAudio() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { return }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }
    }
}

final class PreviewHostView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    override var layer: AVCaptureVideoPreviewLayer { super.layer as! AVCaptureVideoPreviewLayer }
}
