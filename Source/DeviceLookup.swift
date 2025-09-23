import AVFoundation
import Combine

final class DeviceLookup {

    // discovery sessions to find the front and back cameras, and external cameras in iPadOS.
    private let frontCameraDiscoverySession: AVCaptureDevice.DiscoverySession
    private let backCameraDiscoverySession: AVCaptureDevice.DiscoverySession
    private let externalCameraDiscoverSession: AVCaptureDevice.DiscoverySession?

    init() {
        backCameraDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualCamera, .builtInWideAngleCamera],
                                                                      mediaType: .video,
                                                                      position: .back)
        frontCameraDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera, .builtInWideAngleCamera],
                                                                       mediaType: .video,
                                                                       position: .front)
        if #available(iOS 17.0, *) {
            externalCameraDiscoverSession = AVCaptureDevice.DiscoverySession(deviceTypes: [.external],
                                                                             mediaType: .video,
                                                                             position: .unspecified)
            // if the host doesn't currently define a system-preferred camera device, set the user's preferred selection to the back camera.
            if AVCaptureDevice.systemPreferredCamera == nil {
                AVCaptureDevice.userPreferredCamera = backCameraDiscoverySession.devices.first
            }
        } else {
            externalCameraDiscoverSession = nil
        }
    }

    // returns the system-preferred camera for the host system.
    @available(iOS 17.0, *)
    var defaultCamera: AVCaptureDevice {
        get throws {
            guard let videoDevice = AVCaptureDevice.systemPreferredCamera else {
                throw CameraError.videoDeviceUnavailable
            }
            return videoDevice
        }
    }

    func getCamera(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        return AVCaptureDevice.default(AVCaptureDevice.DeviceType.builtInWideAngleCamera, for: AVMediaType.video, position: position)
    }

    // returns the default microphone for the device on which the app runs.
    var defaultMic: AVCaptureDevice {
        get throws {
            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                throw CameraError.audioDeviceUnavailable
            }
            return audioDevice
        }
    }

    var cameras: [AVCaptureDevice] {
        // populate the cameras array with the available cameras.
        var cameras: [AVCaptureDevice] = []
        if let backCamera = backCameraDiscoverySession.devices.first {
            cameras.append(backCamera)
        }
        if let frontCamera = frontCameraDiscoverySession.devices.first {
            cameras.append(frontCamera)
        }
        // iPadOS supports connecting external cameras.
        if let externalCamera = externalCameraDiscoverSession?.devices.first {
            cameras.append(externalCamera)
        }

#if !targetEnvironment(simulator)
        if cameras.isEmpty {
            fatalError("No camera devices are found on this system.")
        }
#endif
        return cameras
    }

}
