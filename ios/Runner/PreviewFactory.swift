import Flutter
import UIKit

final class PreviewFactory: NSObject, FlutterPlatformViewFactory {
    private let camera: CameraController

    init(camera: CameraController) {
        self.camera = camera
        super.init()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        NativePreview(view: camera.previewView)
    }
}

final class NativePreview: NSObject, FlutterPlatformView {
    private let wrapped: UIView

    init(view: UIView) {
        wrapped = view
        super.init()
    }

    func view() -> UIView {
        wrapped
    }
}
