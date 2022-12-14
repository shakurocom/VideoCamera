//
// Copyright (c) 2018 Shakuro (https://shakuro.com/)
// Sergey Laschuk
//

import AVFoundation
import UIKit
import VideoCamera_Framework

class ExampleImageProcessorViewController: UIViewController {

    @IBOutlet private var avVideoOrientationLabel: UILabel!
    @IBOutlet private var uiImageOrienttionLabel: UILabel!
    @IBOutlet private var orientationButton: UIButton!
    @IBOutlet private var sourceImageView: UIImageView!
    @IBOutlet private var sourceImageViewAspectRatioConstraint: NSLayoutConstraint!
    @IBOutlet private var outputImageSizeLabel: UILabel!

    private var example: Example?
    private var currentOrientation: AVCaptureVideoOrientation = .portrait

    override func viewDidLoad() {
        super.viewDidLoad()

        title = example?.title

        orientationButton.isExclusiveTouch = true

        // example #1
        updateOrientation(videoOrientation: currentOrientation)

        if let image = sourceImageView.image {
            if let cgImage = image.cgImage, let pixelBuffer = try? ImageProcessor.createBGRAPixelBuffer(image: cgImage) {
                outputImageSizeLabel.text = "\(CVPixelBufferGetWidth(pixelBuffer)) x \(CVPixelBufferGetHeight(pixelBuffer))"
            } else {
                assertionFailure("can't create pixel buffer")
            }
        } else {
            assertionFailure("image is not loaded")
        }
    }

    // MARK: - Interface callbacks

    @IBAction private func orientationButtonTapped() {
        let rawValue = max((currentOrientation.rawValue + 1) % 4, 1)
        if let nextOrientation = AVCaptureVideoOrientation(rawValue: rawValue) {
            updateOrientation(videoOrientation: nextOrientation)
        }
    }

    // MARK: - Private

    private func updateOrientation(videoOrientation: AVCaptureVideoOrientation) {
        currentOrientation = videoOrientation
        let imageOrienation = ImageProcessor.uiImageOrientation(from: videoOrientation)
        let videoOrientationString: String
        switch videoOrientation {
        case .portrait: videoOrientationString = "AVCaptureVideoOrientation.portrait"
        case .portraitUpsideDown: videoOrientationString = "AVCaptureVideoOrientation.portraitUpsideDown"
        case .landscapeRight: videoOrientationString = "AVCaptureVideoOrientation.landscapeRight"
        case .landscapeLeft: videoOrientationString = "AVCaptureVideoOrientation.landscapeLeft"
        @unknown default:
            fatalError("unknown AVCaptureVideoOrientation")
        }
        avVideoOrientationLabel.text = videoOrientationString
        let imageOrienationString: String
        switch imageOrienation {
        case .up: imageOrienationString = "UIImageOrientation.up"
        case .down: imageOrienationString = "UIImageOrientation.down"
        case .left: imageOrienationString = "UIImageOrientation.left"
        case .right: imageOrienationString = "UIImageOrientation.right"
        case .upMirrored: imageOrienationString = "UIImageOrientation.upMirrored"
        case .downMirrored: imageOrienationString = "UIImageOrientation.downMirrored"
        case .leftMirrored: imageOrienationString = "UIImageOrientation.leftMirrored"
        case .rightMirrored: imageOrienationString = "UIImageOrientation.rightMirrored"
        @unknown default:
            fatalError("unknown UIImageOrientation")
        }
        uiImageOrienttionLabel.text = imageOrienationString
    }

}

// MARK: - ExampleViewControllerProtocol

extension ExampleImageProcessorViewController: ExampleViewControllerProtocol {

    static func instantiate(example: Example) -> UIViewController {
        let storyboard = UIStoryboard(name: "Main", bundle: Bundle(for: self))
        let exampleVC: ExampleImageProcessorViewController = storyboard.instantiateViewController(withIdentifier: "kExampleImageProcessorViewControllerID")
        exampleVC.example = example
        return exampleVC
    }

}
