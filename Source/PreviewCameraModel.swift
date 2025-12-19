@preconcurrency import AVFoundation
import Foundation
import SwiftUI

public class PreviewCameraModel: ObservableObject, Camera {

    struct PreviewSourceStub: PreviewSource { // stubbed out for test purposes
        func connect(to target: PreviewTarget) {}
    }

    @Published public private(set) var status = CameraStatus.unknown

    @Published public var captureMode: CaptureMode? { // photo video
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

    public var didOutputSampleBuffer: AsyncStream<CMSampleBufferUncheckedSendable>

    public var hasTorch: Bool {
        get async {
            return false
        }
    }

    // MARK: - Initialization

    public init(captureMode: CaptureMode?, status: CameraStatus = .unknown) {
        self.captureMode = captureMode
        self.status = status
        let (didOutputSampleBuffer, _) = AsyncStream.makeStream(of: CMSampleBufferUncheckedSendable.self)
        self.didOutputSampleBuffer = didOutputSampleBuffer
    }

    // MARK: - Public

    public func start() async throws {
        if status == .unknown {
            status = .running
        }
    }

    public func stopSession() async {
        if status == .running {
            status = .unknown
        }
    }

    public func setCaptureMode(_ captureMode: CaptureMode) { }

    public func switchVideoDevices() async {
        CaptureService.logger.debug("Device switching isn't implemented in PreviewCamera.")
    }

    public func focusAndExpose(at point: CGPoint) async { // func performs a one-time automatic focus and exposure operation
        CaptureService.logger.debug("Focus and expose isn't implemented in PreviewCamera.")
    }

    public func capturePhoto() async { // captures a photo and writes it to the user's photo library
        CaptureService.logger.debug("Photo capture isn't implemented in PreviewCamera.")
    }

    public func toggleRecording() async { // starts or stops recording a movie, and writes it to the user's photo library when complete
        CaptureService.logger.debug("Moving capture isn't implemented in PreviewCamera.")
    }

    public func setVideoPreviewPaused(_ paused: Bool) async {
        CaptureService.logger.debug("setVideoPreviewPaused isn't implemented in PreviewCamera.")
    }

    public func setFocusMode(_ mode: AVCaptureDevice.FocusMode, focusPointOfInterest: CGPoint) async throws {
        CaptureService.logger.debug("setFocusMode isn't implemented in PreviewCamera.")
    }

    public func torchMode() async -> AVCaptureDevice.TorchMode {
        CaptureService.logger.debug("torchMode isn't implemented in PreviewCamera.")
        return .off
    }

    public func setSmoothAutoFocusEnabled(_ enabled: Bool) async throws {
        CaptureService.logger.debug("setSmoothAutoFocusEnabled isn't implemented in PreviewCamera.")
    }

    public func setTorchMode(_ mode: AVCaptureDevice.TorchMode) async throws {
        CaptureService.logger.debug("setTorchMode isn't implemented in PreviewCamera.")
    }

    public func videoDataOutputSize() async -> CGSize {
        CaptureService.logger.debug("videoDataOutputSize isn't implemented in PreviewCamera.")
        return CGSize(width: 100, height: 100)
    }

}
