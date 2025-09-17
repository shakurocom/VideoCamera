import Foundation
import SwiftUI

public class PreviewCameraModel: ObservableObject, Camera {

    struct PreviewSourceStub: PreviewSource { // stubbed out for test purposes
        func connect(to target: PreviewTarget) {}
    }

    @Published public private(set) var status = CameraStatus.unknown

    @Published public var captureMode = CaptureMode.photo { // photo video
        didSet {
            isSwitchingModes = true
            Task {
                // Create a short delay to mimic the time it takes to reconfigure the session.
                try? await Task.sleep(until: .now + .seconds(0.3), clock: .continuous)
                self.isSwitchingModes = false
            }
        }
    }

    @Published public private(set) var isSwitchingModes = false // camera is currently switching capture modes
    @Published public private(set) var captureActivity = CaptureActivity.idle // photo capture, movie capture, or idle
    @Published public private(set) var isSwitchingVideoDevices = false
    @Published public var prefersMinimizedControlsUI = false
    @Published public var isLivePhotoEnabled = true
    @Published public var isHDRVideoSupported = false // indicates whether the camera supports HDR video recording
    @Published public var isHDRVideoEnabled = false // indicates whether camera enables HDR video recording
    // value indicates how to balance the photo capture quality versus speed
    @Published public var qualityPrioritization = QualityPrioritization.quality
    @Published public var shouldFlashScreen = false // indicates whether to show visual feedback when capture begins
    public let previewSource: PreviewSource = PreviewSourceStub()
    @Published public private(set) var thumbnail: CGImage? // thumbnail image for the most recent photo or video capture.
    @Published public var error: Error? // error if the camera encountered a problem

    // MARK: - Initialization

    public init() { }

    // MARK: - Public

    public func start() async {
        if status == .unknown {
            status = .running
        }
    }

    public func setCaptureMode(_ captureMode: CaptureMode) { }

    public func switchVideoDevices() async {
        logger.debug("Device switching isn't implemented in PreviewCamera.")
    }

    public func focusAndExpose(at point: CGPoint) async { // func performs a one-time automatic focus and exposure operation
        logger.debug("Focus and expose isn't implemented in PreviewCamera.")
    }

    public func capturePhoto() async { // captures a photo and writes it to the user's photo library
        logger.debug("Photo capture isn't implemented in PreviewCamera.")
    }

    public func toggleRecording() async { // starts or stops recording a movie, and writes it to the user's photo library when complete
        logger.debug("Moving capture isn't implemented in PreviewCamera.")
    }

}
