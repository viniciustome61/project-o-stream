import AVFoundation
import UIKit

@MainActor
class SimpleCameraPreview: NSObject {
    let previewView = PreviewHostView()
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

        previewView.attach(session: captureSession)
        previewView.previewLayer.videoGravity = .resizeAspectFill
        previewView.layoutIfNeeded()
        print("[PO] SimpleCameraPreview configured")
    }

    func startPreview() async throws {
        guard !previewRunning else { return }
        previewRunning = true
        let session = captureSession
        captureQueue.async {
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stop() {
        previewRunning = false
        let session = captureSession
        captureQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
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
