import AVFoundation
import HaishinKit
import SRTHaishinKit
import UIKit
import VideoToolbox

@MainActor
final class CameraController: NSObject {
    let previewView = PreviewHostView()

    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "project_o_stream.capture")
    private var connection: SRTConnection?
    private var stream: SRTStream?
    private var mixer: MediaMixer?
    private var activeVideoInput: AVCaptureDeviceInput?
    private var activeAudioInput: AVCaptureDeviceInput?
    private var cameraPosition: AVCaptureDevice.Position = .back
    private var configured = false
    private var previewRunning = false
    private var streaming = false

    var isStreaming: Bool {
        streaming
    }

    func configure(includeAudio: Bool = false) async throws {
        print("[PO] configure() start - requesting camera permission")
        if configured {
            print("[PO] configure() skipped - camera already configured")
            if includeAudio {
                try await ensureAudioInputIfAllowed()
            }
            return
        }

        let camOK = await AVCaptureDevice.requestAccess(for: .video)
        print("[PO] camera permission: \(camOK)")
        guard camOK else {
            throw NSError(domain: "ProjectOStream", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Camera permission denied"])
        }
        var audioAllowed = false
        if includeAudio {
            audioAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            print("[PO] mic permission: \(audioAllowed)")
            guard audioAllowed else {
                throw NSError(domain: "ProjectOStream", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
            }
        }

        print("[PO] configuring AVCaptureSession preview")
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080
        try installVideoInput(position: cameraPosition)
        if audioAllowed {
            installAudioInputIfAvailable()
        }
        captureSession.commitConfiguration()

        previewView.attach(session: captureSession)
        previewView.previewLayer.videoGravity = .resizeAspectFill
        previewView.layoutIfNeeded()
        configured = true
        print("[PO] configure() complete - previewLayer.frame: \(previewView.previewLayer.frame)")
    }

    func startPreview() async throws {
        if !configured {
            try await configure(includeAudio: false)
        }
        guard !previewRunning else { return }

        previewRunning = true
        let session = captureSession
        captureQueue.async {
            if !session.isRunning {
                print("[PO] captureSession.startRunning()")
                session.startRunning()
                print("[PO] captureSession running: \(session.isRunning)")
            }
        }
    }

    func startStream(config: [String: Any]) async throws {
        if streaming {
            await stopStream()
        }

        let host = config["host"] as? String ?? ""
        let port = config["port"] as? Int ?? 7070
        let latencyMs = config["latencyMs"] as? Int ?? 80
        let microphone = config["microphone"] as? Bool ?? true

        if !configured {
            try await configure(includeAudio: microphone)
        } else if microphone {
            try await ensureAudioInputIfAllowed()
        }

        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StreamError.invalidArguments
        }

        let profile = config["profile"] as? [String: Any]
        let width = profile?["width"] as? Int ?? 3840
        let height = profile?["height"] as? Int ?? 2160
        let bitrate = profile?["bitrate"] as? Int ?? 12_000_000
        let latency = latencyMs

        let connection = SRTConnection()
        let stream = SRTStream(connection: connection)
        let mixer = MediaMixer()
        self.connection = connection
        self.stream = stream
        self.mixer = mixer

        try await stream.setVideoSettings(VideoCodecSettings(
            videoSize: CGSize(width: CGFloat(width), height: CGFloat(height)),
            bitRate: bitrate,
            profileLevel: kVTProfileLevel_H264_High_AutoLevel as String
        ))

        try await mixer.attachVideo(activeVideoInput?.device ?? currentVideoDevice(), track: 0)
        if microphone, let audioDevice = activeAudioInput?.device ?? AVCaptureDevice.default(for: .audio) {
            try await mixer.attachAudio(audioDevice, track: 0)
        }
        await mixer.addOutput(stream)

        let urlString = "srt://\(host):\(port)?mode=caller&latency=\(latency)&tlpktdrop=1"
        guard let url = URL(string: urlString) else {
            throw StreamError.invalidArguments
        }
        print("[PO] connecting SRT: \(urlString)")
        try await connection.connect(url)
        await stream.publish()
        streaming = true
    }

    func stopStream() async {
        let activeStream = stream
        let activeConnection = connection
        stream = nil
        connection = nil
        mixer = nil
        streaming = false
        await activeStream?.close()
        await activeConnection?.close()
    }

    func stop() {
        Task {
            await stopStream()
        }
        previewRunning = false
        let session = captureSession
        captureQueue.async {
            if session.isRunning {
                print("[PO] captureSession.stopRunning()")
                session.stopRunning()
            }
        }
    }

    func switchCamera() async throws {
        cameraPosition = cameraPosition == .back ? .front : .back
        captureSession.beginConfiguration()
        try installVideoInput(position: cameraPosition)
        captureSession.commitConfiguration()
        if streaming, let mixer {
            try await mixer.attachVideo(currentVideoDevice(), track: 0)
        }
        print("[PO] switched camera to \(cameraPosition == .back ? "back" : "front")")
    }

    func setTorch(_ enabled: Bool) async throws {
        let device = currentVideoDevice()
        guard device.hasTorch else {
            throw NSError(domain: "ProjectOStream", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Torch is not available on this camera"])
        }
        try device.lockForConfiguration()
        if enabled {
            try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
        } else {
            device.torchMode = .off
        }
        device.unlockForConfiguration()
        print("[PO] torch \(enabled ? "on" : "off")")
    }

    func setZoom(_ value: CGFloat) async throws {
        let device = currentVideoDevice()
        try device.lockForConfiguration()
        device.videoZoomFactor = min(max(value, 1), device.activeFormat.videoMaxZoomFactor)
        device.unlockForConfiguration()
        print("[PO] zoom \(value)")
    }

    private func installVideoInput(position: AVCaptureDevice.Position) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw NSError(domain: "ProjectOStream", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "No \(position == .back ? "back" : "front") camera found"])
        }

        let input = try AVCaptureDeviceInput(device: device)
        if let activeVideoInput {
            captureSession.removeInput(activeVideoInput)
        }
        guard captureSession.canAddInput(input) else {
            throw NSError(domain: "ProjectOStream", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot attach camera input"])
        }
        captureSession.addInput(input)
        activeVideoInput = input
    }

    private func installAudioInputIfAvailable() {
        guard activeAudioInput == nil,
              let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            return
        }
        captureSession.addInput(input)
        activeAudioInput = input
    }

    private func ensureAudioInputIfAllowed() async throws {
        guard activeAudioInput == nil else { return }
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        print("[PO] mic permission: \(micOK)")
        guard micOK else {
            throw NSError(domain: "ProjectOStream", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Microphone permission denied"])
        }

        captureSession.beginConfiguration()
        installAudioInputIfAvailable()
        captureSession.commitConfiguration()
    }

    private func currentVideoDevice() -> AVCaptureDevice {
        if let device = activeVideoInput?.device {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition)
            ?? AVCaptureDevice.default(for: .video)!
    }
}

final class PreviewHostView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        backgroundColor = .black
        clipsToBounds = true
        isOpaque = true
        isUserInteractionEnabled = false
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    func attach(session: AVCaptureSession) {
        previewLayer.session = session
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
}
