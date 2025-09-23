import AVFoundation
import SwiftUI
import VideoCamera_Framework

struct ContentView: View {

    @StateObject private var camera = CameraModel(options: CameraModel.Options(
        isAudioAllowed: true,
        captureModes: [.photo, .video],
        cameraPosition: .front,
        videoGravity: .resizeAspect,
        captureSessionPreset: nil,
        isIOS18ControlsEnabled: true,
        isIOS17RotationCoordinatorEnabled: true,
        isSubjectAreaObserverEnabled: true,
        isVideoFeedEnabled: true,
        isVideoFeedShouldDiscardLateFrames: true,
        videoFeedSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]))

    var body: some View {
        CameraView(camera: camera)
            .statusBarHidden(true)
            .task {
                try? await camera.start()
            }
    }

}

#Preview {
    ContentView()
}
