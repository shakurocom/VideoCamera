import SwiftUI

@MainActor
public protocol Camera: AnyObject, SendableMetatype, ObservableObject {

    var status: CameraStatus { get }
    var captureMode: CaptureMode { get set } // photo video
    var isSwitchingModes: Bool { get } // camera is currently switching capture modes
    var captureActivity: CaptureActivity { get } // photo capture, movie capture, or idle
    var isSwitchingVideoDevices: Bool { get }
    var prefersMinimizedControlsUI: Bool { get }
    var isLivePhotoEnabled: Bool { get set }
    var isHDRVideoSupported: Bool { get } // indicates whether the camera supports HDR video recording
    var isHDRVideoEnabled: Bool { get set } // indicates whether camera enables HDR video recording
    var qualityPrioritization: QualityPrioritization { get set } // value indicates how to balance the photo capture quality versus speed.
    var shouldFlashScreen: Bool { get } // indicates whether to show visual feedback when capture begins
    var previewSource: PreviewSource { get }
    var thumbnail: CGImage? { get } // thumbnail image for the most recent photo or video capture.
    var error: Error? { get } // error if the camera encountered a problem

    func start() async
    func switchVideoDevices() async
    func focusAndExpose(at point: CGPoint) async // func performs a one-time automatic focus and exposure operation
    func capturePhoto() async // captures a photo and writes it to the user's photo library
    func toggleRecording() async // starts or stops recording a movie, and writes it to the user's photo library when complete

}
