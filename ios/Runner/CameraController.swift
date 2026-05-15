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
        await stopStream()

        let host = (config["host"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let port = config["port"] as? Int ?? 7070
        let latencyMs = config["latencyMs"] as? Int ?? 80
        let microphone = config["microphone"] as? Bool ?? true

        if !configured {
            try await configure(includeAudio: microphone)
        } else if microphone {
            try await ensureAudioInputIfAllowed()
        }

        guard isUsableEndpointHost(host) else {
            throw StreamError.invalidArguments
        }
        if microphone {
            try configureAudioSession()
        }

        let profile = config["profile"] as? [String: Any]
        let width = profile?["width"] as? Int ?? 3840
        let height = profile?["height"] as? Int ?? 2160
        let bitrate = profile?["bitrate"] as? Int ?? 12_000_000
        let latency = latencyMs

        let shouldRestorePreview = previewRunning || captureSession.isRunning
        if shouldRestorePreview {
            stopPreviewCaptureSession()
        }

        let connection = SRTConnection()
        let stream = SRTStream(connection: connection)
        let mixer = MediaMixer()
        self.connection = connection
        self.stream = stream
        self.mixer = mixer

        do {
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
            print("[PO] starting MediaMixer capture")
            await mixer.startRunning()

            let urlString = "srt://\(host):\(port)?mode=caller&latency=\(latency)&tlpktdrop=1"
            guard let url = URL(string: urlString) else {
                throw StreamError.invalidArguments
            }
            print("[PO] connecting SRT: \(urlString)")
            try await connection.connect(url)
            await stream.publish()
            streaming = true
            print("[PO] stream live")
        } catch {
            print("[PO] startStream() failed: \(error)")
            await stopStream()
            if shouldRestorePreview {
                try? await startPreview()
            }
            throw error
        }
    }

    func stopStream(restartPreview: Bool = false) async {
        let activeMixer = mixer
        let activeStream = stream
        let activeConnection = connection
        stream = nil
        connection = nil
        mixer = nil
        streaming = false
        if let activeMixer {
            if let activeStream {
                await activeMixer.removeOutput(activeStream)
            }
            await activeMixer.stopRunning()
        }
        await activeStream?.close()
        await activeConnection?.close()
        if restartPreview {
            try? await startPreview()
        }
    }

    func stop() {
        Task {
            await stopStream()
        }
        stopPreviewCaptureSession()
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

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
    }

    private func stopPreviewCaptureSession() {
        previewRunning = false
        let session = captureSession
        captureQueue.sync {
            if session.isRunning {
                print("[PO] captureSession.stopRunning()")
                session.stopRunning()
            }
        }
    }

    private func currentVideoDevice() -> AVCaptureDevice {
        if let device = activeVideoInput?.device {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: cameraPosition)
            ?? AVCaptureDevice.default(for: .video)!
    }

    private func isUsableEndpointHost(_ host: String) -> Bool {
        guard !host.isEmpty,
              host != "0.0.0.0",
              host != "255.255.255.255",
              let firstOctet = Int(host.split(separator: ".").first ?? "") else {
            return false
        }
        return firstOctet > 0 && firstOctet < 224 && firstOctet != 127
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
