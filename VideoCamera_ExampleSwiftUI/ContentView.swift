import SwiftUI
import VideoCamera_Framework

struct ContentView: View {

    @State private var camera = CameraModel()

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
