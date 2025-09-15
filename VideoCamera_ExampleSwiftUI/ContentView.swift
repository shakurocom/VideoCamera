import SwiftUI
import VideoCamera_Framework

struct ContentView: View {

    @StateObject private var camera = CameraModel(options: CameraModel.Options(isAudioAvailable: true))

    var body: some View {
        CameraView(camera: camera)
            .statusBarHidden(true)
            .task {
                await camera.start()
            }
    }

}

#Preview {
    ContentView()
}
