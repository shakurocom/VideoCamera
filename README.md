![Shakuro VideoCamera](Resources/title_image.png)
<br><br>
# VideoCamera
![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)
![Platform](https://img.shields.io/badge/platform-iOS-lightgrey.svg)
![License MIT](https://img.shields.io/badge/license-MIT-green.svg)

- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [License](#license)

Wrapper around AVFoundation camera. Works with several data outputs, such as metadata, video data, still image capture.

## Requirements

- iOS 15.0+
- Xcode 16.0+
- Swift 5.0+

## Installation

### CocoaPods

To integrate VideoCamera into your Xcode project with CocoaPods, specify it in your `Podfile`:

```ruby
pod 'Shakuro.VideoCamera'
```

Then, run the following command:

```bash
$ pod install
```

### Manually

If you prefer not to use CocoaPods, you can integrate Shakuro.VideoCamera simply by copying it to your project.

## Usage

Each `VideoCamera` must be provided with `VideoCameraConfiguration` structure. Go though it's extensive array of settings. For a simple setup of back-facing camera, that provides only video data preview without ability to get still images:

```swift
private var camera: VideoCamera?

override func viewDidLoad() {
    super.viewDidLoad()
    
    // ...
    
    var cameraConfig = VideoCameraConfiguration()
    cameraConfig.cameraDelegate = self
    cameraConfig.captureSessionPreset = .high
    cameraConfig.capturePhotoEnabled = false
    cameraConfig.videoFeedDelegate = self
    cameraConfig.simulatedImage = UIImage(named: "card_backside.png")?.cgImage
    let videoCamera = VideoCameraFactory.createCamera(configuration: cameraConfig)
    camera = videoCamera
    
    // ...
}
```

To display camera preview, one of the simplest ways is to prepare container view in storyboard and than add camera's preview to it:

```swift
@IBOutlet private var cameraPreviewContainerView: UIView!

override func viewDidLoad() {
    super.viewDidLoad()
    
    // setup camera (see above)

    let preview = videoCamera.previewView
    preview.translatesAutoresizingMaskIntoConstraints = true
    preview.autoresizingMask = [UIViewAutoresizing.flexibleHeight, UIViewAutoresizing.flexibleWidth]
    preview.frame = cameraPreviewContainerView.bounds
    cameraPreviewContainerView.insertSubview(preview, at: 0)
    
    // ...
}
```

Changes of camera's properties are observed via delegate:

```swift
extension MyViewController: VideoCameraDelegate {

    func videoCamera(_ videoCamera: VideoCamera, error: Error) {
        // display/process error
    }

    func videoCameraInitialized(_ videoCamera: VideoCamera, errors: [VideoCameraError]) {
        // update UI - such as flash button (with actual state of camera)
    }

    func videoCamera(_ videoCamera: VideoCamera, flashModeForPhotoDidChanged newValue: AVCaptureDevice.FlashMode) {
        // update flash button
    }
    
    // ... other delegate functions
    
}
```

Have a look at the [VideoCamera_Example](https://github.com/shakurocom/VideoCamera/tree/master/VideoCamera_Example)

## License

Shakuro.VideoCamera is released under the MIT license. [See LICENSE](https://github.com/shakurocom/VideoCamera/blob/master/LICENSE.md) for details.

## Give it a try and reach us

Explore our expertise in <a href="https://shakuro.com/services/native-mobile-development/?utm_source=github&utm_medium=repository&utm_campaign=video-camera">Native Mobile Development</a> and <a href="https://shakuro.com/services/ios-dev/?utm_source=github&utm_medium=repository&utm_campaign=video-camera">iOS Development</a>.</p>

If you need professional assistance with your mobile or web project, feel free to <a href="https://shakuro.com/get-in-touch/?utm_source=github&utm_medium=repository&utm_campaign=video-camera">contact our team</a>
