import SwiftUI
@preconcurrency import AVFoundation

public struct CameraPreviewView: UIViewRepresentable {

    private let source: PreviewSource

    public init(source: PreviewSource) {
        self.source = source
    }

    public func makeUIView(context: Context) -> PreviewView {
        let preview = PreviewView()
        // Connect the preview layer to the capture session.
        source.connect(to: preview)
        return preview
    }

    public func updateUIView(_ previewView: PreviewView, context: Context) {
        // No-op.
    }

}

public class PreviewView: UIView, PreviewTarget {

    public init() {
        super.init(frame: .zero)
#if targetEnvironment(simulator)
        // The capture APIs require running on a real device. If running
        // in Simulator, display a static image to represent the video feed.
        let imageView = UIImageView(frame: UIScreen.main.bounds)
        imageView.image = UIImage(named: "test_image.jpg", in: Bundle(for: PreviewView.self), compatibleWith: nil)
        imageView.contentMode = .scaleAspectFill
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
#endif
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    public var previewLayer: AVCaptureVideoPreviewLayer {
        guard let typedLayer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Unknown layer type: \(layer)")
        }
        return typedLayer
    }

    public nonisolated func setSession(_ session: AVCaptureSession) {
        Task(operation: { @MainActor in
            previewLayer.session = session
        })
    }

    public nonisolated func clearSession() {
        Task(operation: { @MainActor in
            previewLayer.session = nil
        })
    }

    public nonisolated func setVideoGravity(_ videoGravity: AVLayerVideoGravity) {
        Task(operation: { @MainActor in
            previewLayer.videoGravity = videoGravity
        })
    }

}

/// A protocol that enables a preview source to connect to a preview target.
///
/// The app provides an instance of this type to the client tier so it can connect
/// the capture session to the `PreviewView` view. It uses these protocols
/// to prevent explicitly exposing the capture objects to the UI layer.
///
public protocol PreviewSource: Sendable {
    // Connects a preview destination to this source.
    func connect(to target: PreviewTarget)
    // Disconnects a preview destination from this source.
    //
    // Call this before the preview target is removed from the view hierarchy
    // (and therefore deallocated) while the capture session is still running.
    // It detaches the capture session from the preview layer so that the
    // layer's `dealloc` does not race with concurrent session mutations
    // (e.g. `stopRunning` on the session queue), which can otherwise throw
    // an `NSException` from AVFoundation.
    func disconnect(from target: PreviewTarget)
}

public extension PreviewSource {

    func disconnect(from target: PreviewTarget) {
        target.clearSession()
    }

}

/// A protocol that passes the app's capture session to the `CameraPreview` view.
public protocol PreviewTarget {
    // Sets the capture session on the destination.
    func setSession(_ session: AVCaptureSession)
    // Clears the capture session from the destination.
    func clearSession()
    func setVideoGravity(_ videoGravity: AVLayerVideoGravity)
}

public extension PreviewTarget {

    func clearSession() { }

}

/// The app's default `PreviewSource` implementation.
struct DefaultPreviewSource: PreviewSource {

    private let session: AVCaptureSession
    private let videoGravity: AVLayerVideoGravity

    init(session: AVCaptureSession, videoGravity: AVLayerVideoGravity) {
        self.session = session
        self.videoGravity = videoGravity
    }

    func connect(to target: PreviewTarget) {
        target.setSession(session)
        target.setVideoGravity(videoGravity)
    }

    func disconnect(from target: PreviewTarget) {
        target.clearSession()
    }

}
