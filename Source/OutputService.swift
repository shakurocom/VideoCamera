import AVFoundation

@CaptureServiceActor
protocol OutputService: Sendable {

    associatedtype Output: AVCaptureOutput

    var avCaptureOutput: Output { get }
    var captureActivity: CaptureActivity { get }
    var capabilities: CaptureService.CaptureCapabilities? { get }

    func updateConfiguration(for device: AVCaptureDevice)
    @available(iOS 17.0, *)
    func setVideoRotationAngle(_ angle: CGFloat)

}

extension OutputService {

    @available(iOS 17.0, *)
    func setVideoRotationAngle(_ angle: CGFloat) {
        // Set the rotation angle on the output object's video connection.
        avCaptureOutput.connection(with: .video)?.videoRotationAngle = angle
    }

    func updateConfiguration(for device: AVCaptureDevice) {}

}
