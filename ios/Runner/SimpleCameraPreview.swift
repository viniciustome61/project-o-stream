import AVFoundation
import UIKit

@MainActor
class SimpleCameraPreview: NSObject {
    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "project_o_stream.preview")
    private var activeVideoInput: AVCaptureDeviceInput?
    private var cameraPosition: AVCaptureDevice.Position = .back
    private var previewRunning = false

    func configure() async throws {
        print("[PO] SimpleCameraPreview.configure()")
        let camOK = await AVCaptureDevice.requestAccess(for: .video)
        guard camOK else {
            throw NSError(domain: "ProjectOStream", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Camera permission denied"])
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080
        try installVideoInput(position: cameraPosition)
        captureSession.commitConfiguration()
        print("[PO] SimpleCameraPreview configured")
    }

    func startPreview() async throws {
        guard !previewRunning else { return }
        previewRunning = true
        let session = captureSession
        captureQueue.async {
            if !session.isRunning {
                session.startRunning()
                print("[PO] Preview started")
            }
        }
    }

    func stop() {
        previewRunning = false
        let session = captureSession
        captureQueue.async {
            if session.isRunning {
                session.stopRunning()
                print("[PO] Preview stopped")
            }
        }
    }

    // Stub methods to match CameraController interface
    // These are called by AppDelegate but SimpleCameraPreview is lightweight boot version
    
    func startStream(config: [String: Any]) async throws {
        print("[PO] SimpleCameraPreview.startStream() - SRT streaming not available in boot preview")
        // No-op: SimpleCameraPreview doesn't support SRT streaming
    }

    func stopStream() {
        print("[PO] SimpleCameraPreview.stopStream()")
        // No-op: SimpleCameraPreview doesn't support SRT streaming
    }

    func switchCamera() async throws {
        print("[PO] SimpleCameraPreview.switchCamera()")
        cameraPosition = (cameraPosition == .back) ? .front : .back
        do {
            captureSession.beginConfiguration()
            // Remove current input
            if let currentInput = activeVideoInput {
                captureSession.removeInput(currentInput)
            }
            try installVideoInput(position: cameraPosition)
            captureSession.commitConfiguration()
        } catch {
            print("[PO] Camera switch failed: \(error)")
            throw error
        }
    }

    func setTorch(_ enabled: Bool) async throws {
        print("[PO] SimpleCameraPreview.setTorch(\(enabled))")
        guard let device = activeVideoInput?.device else {
            throw NSError(domain: "ProjectOStream", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "No active camera device"])
        }
        
        guard device.hasTorch else {
            throw NSError(domain: "ProjectOStream", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Torch not available"])
        }
        
        do {
            try device.lockForConfiguration()
            device.torchMode = enabled ? .on : .off
            device.unlockForConfiguration()
        } catch {
            print("[PO] Torch control failed: \(error)")
            throw error
        }
    }

    func setZoom(_ value: Double) async throws {
        print("[PO] SimpleCameraPreview.setZoom(\(value))")
        guard let device = activeVideoInput?.device else {
            throw NSError(domain: "ProjectOStream", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "No active camera device"])
        }
        
        do {
            try device.lockForConfiguration()
            let clampedZoom = max(1.0, min(value, device.activeFormat.videoMaxZoomFactor))
            device.videoZoomFactor = clampedZoom
            device.unlockForConfiguration()
        } catch {
            print("[PO] Zoom control failed: \(error)")
            throw error
        }
    }

    private func installVideoInput(position: AVCaptureDevice.Position) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw NSError(domain: "ProjectOStream", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No camera device found"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
            activeVideoInput = input
        }
    }
}
