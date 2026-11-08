import SwiftUI
import AVFoundation

public struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var cameraService: CameraService

    public init(cameraService: CameraService = .shared) {
        self.cameraService = cameraService
    }

    public func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = cameraService.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    public func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session != cameraService.captureSession {
            uiView.previewLayer.session = cameraService.captureSession
        }
    }

    public final class PreviewUIView: UIView {
        public override class var layerClass: AnyClass {
            return AVCaptureVideoPreviewLayer.self
        }

        public var previewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
            if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }
}
