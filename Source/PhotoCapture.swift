import AVFoundation
import CoreImage

enum PhotoCaptureError: Error {
    case noPhotoData
}

@CaptureServiceActor
final class PhotoCapture: OutputService {

    @Published private(set) var captureActivity: CaptureActivity = .idle

    let avCaptureOutput = AVCapturePhotoOutput()
    private(set) var capabilities: CaptureCapabilities?

    private var photoOutput: AVCapturePhotoOutput { avCaptureOutput }
    private var livePhotoCount = 0 // count of Live Photo captures currently in progress

    // MARK: - Initialization

    @MainActor
    init() { }

    // MARK: - Public

    func capturePhoto(with features: PhotoFeatures) async throws -> Photo {
        try await withCheckedThrowingContinuation { continuation in
            let photoSettings = createPhotoSettings(with: features)
            let delegate = PhotoCaptureDelegate(continuation: continuation)
            monitorProgress(of: delegate)
            photoOutput.capturePhoto(with: photoSettings, delegate: delegate)
        }
    }

    // reconfigures the photo output and updates the output service's capabilities accordingly
    // it is called whenever you change cameras
    func updateConfiguration(for device: AVCaptureDevice) {
        // Enable all supported features.
        photoOutput.maxPhotoDimensions = device.activeFormat.supportedMaxPhotoDimensions.last ?? .zero
        photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported
        photoOutput.maxPhotoQualityPrioritization = .quality
        if #available(iOS 17.0, *) {
            photoOutput.isResponsiveCaptureEnabled = photoOutput.isResponsiveCaptureSupported
            photoOutput.isFastCapturePrioritizationEnabled = photoOutput.isFastCapturePrioritizationSupported
            photoOutput.isAutoDeferredPhotoDeliveryEnabled = photoOutput.isAutoDeferredPhotoDeliverySupported
        }
        updateCapabilities(for: device)
    }

    // MARK: - Private

    private func createPhotoSettings(with features: PhotoFeatures) -> AVCapturePhotoSettings {
        var photoSettings = AVCapturePhotoSettings()
        // capture photos in HEIF format when the device supports it
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        // set the format of the preview image to capture. The `photoSettings` object returns the available
        // preview format types in order of compatibility with the primary image.
        if let previewPhotoPixelFormatType = photoSettings.availablePreviewPhotoPixelFormatTypes.first {
            photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: previewPhotoPixelFormatType]
        }
        // set the largest dimensions that the photo output supports.
        // `CaptureService` automatically updates the photo output's `maxPhotoDimensions` when the capture pipeline changes
        photoSettings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        // set the movie URL if the photo output supports Live Photo capture
        photoSettings.livePhotoMovieFileURL = features.isLivePhotoEnabled ? URL.movieFileURL : nil
        // set the priority of speed versus quality during this capture
        if let prioritization = AVCapturePhotoOutput.QualityPrioritization(rawValue: features.qualityPrioritization.rawValue) {
            photoSettings.photoQualityPrioritization = prioritization
        }
        return photoSettings
    }

    private func monitorProgress(of delegate: PhotoCaptureDelegate) {
        Task { @CaptureServiceActor in
            var isLivePhoto = false
            // asynchronously monitor the activity of the delegate while the system performs capture
            for await activity in delegate.activityStream {
                var currentActivity = activity
                // more than one activity value for the delegate may report that `isLivePhoto` is `true`
                // only increment/decrement the count when the value changes from its previous state
                if activity.isLivePhoto != isLivePhoto {
                    isLivePhoto = activity.isLivePhoto
                    livePhotoCount += isLivePhoto ? 1 : -1
                    if livePhotoCount > 1 {
                        // set `isLivePhoto` to `true` when there are concurrent Live Photos in progress
                        // this prevents the "Live" badge in the UI from flickering
                        currentActivity = .photoCapture(willCapture: activity.willCapture, isLivePhoto: true)
                    }
                }
                captureActivity = currentActivity
            }
        }
    }

    private func updateCapabilities(for device: AVCaptureDevice) {
        capabilities = CaptureCapabilities(isLivePhotoCaptureSupported: photoOutput.isLivePhotoCaptureSupported)
    }

}

extension PhotoCapture {

    typealias PhotoContinuation = CheckedContinuation<Photo, Error>

    private class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {

        let activityStream: AsyncStream<CaptureActivity>

        private let continuation: PhotoContinuation

        private var isLivePhoto = false
        private var isProxyPhoto = false

        private var photoData: Data?
        private var livePhotoMovieURL: URL?

        private let activityContinuation: AsyncStream<CaptureActivity>.Continuation

        // MARK: - Initialization

        init(continuation: PhotoContinuation) {
            self.continuation = continuation

            let (activityStream, activityContinuation) = AsyncStream.makeStream(of: CaptureActivity.self)
            self.activityStream = activityStream
            self.activityContinuation = activityContinuation
        }

        // MARK: - AVCapturePhotoCaptureDelegate

        func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
            isLivePhoto = resolvedSettings.livePhotoMovieDimensions != .zero
            activityContinuation.yield(.photoCapture(isLivePhoto: isLivePhoto))
        }

        func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
            // capture is beginning
            activityContinuation.yield(.photoCapture(willCapture: true, isLivePhoto: isLivePhoto))
        }

        func photoOutput(_ output: AVCapturePhotoOutput,
                         didFinishRecordingLivePhotoMovieForEventualFileAt outputFileURL: URL,
                         resolvedSettings: AVCaptureResolvedPhotoSettings) {
            // Live Photo capture is over
            activityContinuation.yield(.photoCapture(isLivePhoto: false))
        }

        func photoOutput(_ output: AVCapturePhotoOutput,
                         didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                         duration: CMTime,
                         photoDisplayTime: CMTime,
                         resolvedSettings: AVCaptureResolvedPhotoSettings,
                         error: Error?) {
            if let error {
                CaptureService.logger.debug("Error processing Live Photo companion movie: \(String(describing: error))")
            }
            livePhotoMovieURL = outputFileURL
        }

        @available(iOS 17.0, *)
        func photoOutput(_ output: AVCapturePhotoOutput,
                         didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?,
                         error: Error?) {
            if let error = error {
                CaptureService.logger.debug("Error capturing deferred photo: \(error)")
                return
            }
            // capture the data for this photo
            photoData = deferredPhotoProxy?.fileDataRepresentation()
            isProxyPhoto = true
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            if let error = error {
                CaptureService.logger.debug("Error capturing photo: \(String(describing: error))")
                return
            }
            photoData = photo.fileDataRepresentation()
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
            defer {
                activityContinuation.finish()
            }
            if let errorActual = error {
                continuation.resume(throwing: errorActual)
                return
            }
            guard let photoDataActual = photoData else {
                continuation.resume(throwing: PhotoCaptureError.noPhotoData)
                return
            }
            let photo = Photo(data: photoDataActual, isProxy: isProxyPhoto, livePhotoMovieURL: livePhotoMovieURL)
            continuation.resume(returning: photo)
        }

    }

}
