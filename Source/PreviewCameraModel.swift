import Foundation
import SwiftUI

public class PreviewCameraModel: ObservableObject, Camera {

    @Published public var isLivePhotoEnabled = true
    @Published public var prefersMinimizedUI = false
    @Published public var qualityPrioritization = QualityPrioritization.quality
    @Published public var shouldFlashScreen = false
    @Published public var isHDRVideoSupported = false
    @Published public var isHDRVideoEnabled = false

    struct PreviewSourceStub: PreviewSource {
        // Stubbed out for test purposes.
        func connect(to target: PreviewTarget) {}
    }
    
    public let previewSource: PreviewSource = PreviewSourceStub()

    @Published public private(set) var status = CameraStatus.unknown
    @Published public private(set) var captureActivity = CaptureActivity.idle
    @Published public var captureMode = CaptureMode.photo {
        didSet {
            isSwitchingModes = true
            Task {
                // Create a short delay to mimic the time it takes to reconfigure the session.
                try? await Task.sleep(until: .now + .seconds(0.3), clock: .continuous)
                self.isSwitchingModes = false
            }
        }
    }
    @Published public private(set) var isSwitchingModes = false
    @Published public private(set) var isVideoDeviceSwitchable = true
    @Published public private(set) var isSwitchingVideoDevices = false
    @Published public private(set) var thumbnail: CGImage?

    @Published public var error: Error?

    public init(captureMode: CaptureMode = .photo, status: CameraStatus = .unknown) {
        self.captureMode = captureMode
        self.status = status
    }
    
    public func start() async {
        if status == .unknown {
            status = .running
        }
    }
    
    public func switchVideoDevices() {
        logger.debug("Device switching isn't implemented in PreviewCamera.")
    }
    
    public func capturePhoto() {
        logger.debug("Photo capture isn't implemented in PreviewCamera.")
    }
    
    public func toggleRecording() {
        logger.debug("Moving capture isn't implemented in PreviewCamera.")
    }
    
    public func focusAndExpose(at point: CGPoint) {
        logger.debug("Focus and expose isn't implemented in PreviewCamera.")
    }
    
    public var recordingTime: TimeInterval { .zero }

    private func capabilities(for mode: CaptureMode) -> CaptureCapabilities {
        switch mode {
        case .photo:
            return CaptureCapabilities(isLivePhotoCaptureSupported: true)
        case .video:
            return CaptureCapabilities(isLivePhotoCaptureSupported: false,
                                       isHDRSupported: true)
        }
    }
    
    public func syncState() async {
        logger.debug("Syncing state isn't implemented in PreviewCamera.")
    }

}
