import SwiftUI

@MainActor
public protocol Camera: AnyObject, SendableMetatype, ObservableObject {

    var status: CameraStatus { get }
    var isSwitchingModes: Bool { get } // camera is currently switching capture modes
    var captureActivity: CaptureActivity { get } // photo capture, movie capture, or idle
    var captureMode: CaptureMode? { get set }
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

    func start() async throws
    func stopSession() async
    func setCaptureMode(_ captureMode: CaptureMode)
    func switchVideoDevices() async
    func focusAndExpose(at point: CGPoint) async // func performs a one-time automatic focus and exposure operation
    func capturePhoto() async // captures a photo and writes it to the user's photo library
    func toggleRecording() async // starts or stops recording a movie, and writes it to the user's photo library when complete

}

public enum CameraStatus {
    case unknown
    case unauthorized // person disallows access to the camera or microphone
    case failed // camera failed to start
    case running // camera is successfully running
    case interrupted // higher-priority media processing is interrupting the camera
}

public enum CaptureActivity: Sendable, Equatable {

    case idle
    // capture service is performing photo capture.
    case photoCapture(willCapture: Bool = false, isLivePhoto: Bool = false)
    // capture service is performing movie capture.
    case movieCapture(duration: TimeInterval = 0.0)

    public var isLivePhoto: Bool {
        if case .photoCapture(_, let isLivePhoto) = self {
            return isLivePhoto
        }
        return false
    }

    public var willCapture: Bool {
        if case .photoCapture(let willCapture, _) = self {
            return willCapture
        }
        return false
    }

    public var currentTime: TimeInterval {
        if case .movieCapture(let duration) = self {
            return duration
        }
        return .zero
    }

    public var isRecording: Bool {
        if case .movieCapture = self {
            return true
        }
        return false
    }

}

public enum CaptureMode: String, Identifiable, CaseIterable, Codable, Sendable {

    case photo
    case video

    public var id: Self { self }

}

public enum QualityPrioritization: Int, Identifiable, CaseIterable, CustomStringConvertible, Codable, Sendable {

    case speed = 1
    case balanced
    case quality

    public var id: Self { self }

    public var description: String {
        switch self {
        case.speed:
            return "Speed"
        case .balanced:
            return "Balanced"
        case .quality:
            return "Quality"
        }
    }

}

public enum CameraError: Error {
    case videoDeviceUnavailable
    case audioDeviceUnavailable
    case addInputFailed
    case addOutputFailed
    case setupFailed
    case deviceChangeFailed
    case photoCaptureNotAllowed
    case movieCaptureNotAllowed
}
