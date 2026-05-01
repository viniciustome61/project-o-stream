import AVFoundation
import UIKit

// Stubs for HaishinKit SRT types.
// SRT streaming requires libsrt.xcframework linked at build time.
// Until that is available these are no-ops so the app compiles and
// camera preview works on real hardware.

final class SRTConnection {
    func connect(_ uri: String) {}
    func close() {}
}

final class SRTStream {
    struct VideoSettings {
        var videoSize: CGSize = CGSize(width: 1920, height: 1080)
        var bitrate: Int = 4_000_000
        var profileLevel: String = ""
        var device: AVCaptureDevice?
    }

    var videoSettings = VideoSettings()

    init(connection: SRTConnection) {}

    func attachCamera(_ device: AVCaptureDevice?) { videoSettings.device = device }
    func attachAudio(_ device: AVCaptureDevice?) {}
    func publish() {}
    func close() {}
}

final class MTHKView: UIView {
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    func attachStream(_ stream: SRTStream) {}
}
