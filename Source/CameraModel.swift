import os.log
import SwiftUI

let logger = Logger() // TODO: implement

@MainActor
public final class CameraModel: ObservableObject, Camera {

    public struct Options {

        public let isAudioAllowed: Bool
        public let captureModes: [CaptureMode]

        public init(isAudioAllowed: Bool,
                    captureModes: [CaptureMode]) {
            self.isAudioAllowed = isAudioAllowed
            self.captureModes = captureModes
        }

    }

    @Published public private(set) var status = CameraStatus.unknown
    @Published public private(set) var isSwitchingModes = false // camera is currently switching capture modes
    @Published public private(set) var captureActivity = CaptureActivity.idle // photo capture, movie capture, or idle
    @Published public private(set) var isSwitchingVideoDevices = false
    @Published public private(set) var prefersMinimizedControlsUI = false
    @Published public var isLivePhotoEnabled = true
    @Published public private(set) var isHDRVideoSupported = false // indicates whether the camera supports HDR video recording

    @Published public var isHDRVideoEnabled = false { // indicates whether camera enables HDR video recording
        didSet {
            guard status == .running, captureMode == .video else { return }
            Task {
                await captureService.setHDRVideoEnabled(isHDRVideoEnabled)
            }
        }
    }

    // value indicates how to balance the photo capture quality versus speed
    @Published public var qualityPrioritization = QualityPrioritization.quality
    @Published public private(set) var shouldFlashScreen = false // indicates whether to show visual feedback when capture begins

    public var previewSource: PreviewSource {
        return captureService.previewSource
    }

    @Published public private(set) var thumbnail: CGImage? // thumbnail image for the most recent photo or video capture
    @Published public private(set) var error: Error? // error if the camera encountered a problem

    private let options: Options
    private let captureService: CaptureService
    private let mediaLibrary: MediaLibrary?

    @Published private var captureMode: CaptureMode?
    @Published private var isVideoHDREnabled = true
    @Published private var isVideoHDRSupported = true

    // MARK: - Initialization

    public init(options: Options) {
        self.options = options
        self.captureService = CaptureService(options: CaptureService.Options(isAudioAllowed: options.isAudioAllowed,
                                                                             captureModes: options.captureModes))
        self.mediaLibrary = options.captureModes.isEmpty ? nil : MediaLibrary()
        self.captureMode = options.captureModes.first
    }

    // MARK: - Public

    public func start() async {
        guard await captureService.isAuthorized else { // TODO: implement
            status = .unauthorized
            return
        }
        do {
            try await captureService.start(newCaptureMode: captureMode, isVideoHDREnabledNew: isVideoHDREnabled)
            startObserving()
            status = .running
        } catch {
            logger.error("Failed to start capture service. \(error)")
            status = .failed
        }
    }

    public func setCaptureMode(_ captureMode: CaptureMode) {
        guard status == .running && options.captureModes.contains(captureMode) else {
            return
        }
        self.captureMode = captureMode
        Task(operation: {
            isSwitchingModes = true
            defer { isSwitchingModes = false }
            try? await captureService.setCaptureMode(captureMode)
        })
    }

    public func switchVideoDevices() async {
        isSwitchingVideoDevices = true
        defer { isSwitchingVideoDevices = false }
        await captureService.selectNextVideoDevice()
    }

    public func focusAndExpose(at point: CGPoint) async { // func performs a one-time automatic focus and exposure operation
        await captureService.focusAndExpose(at: point)
    }

    public func capturePhoto() async { // captures a photo and writes it to the user's photo library
        guard let mediaLibraryActual = mediaLibrary else {
            return
        }
        do {
            let photoFeatures = PhotoFeatures(isLivePhotoEnabled: isLivePhotoEnabled, qualityPrioritization: qualityPrioritization)
            let photo = try await captureService.capturePhoto(with: photoFeatures)
            try await mediaLibraryActual.save(photo: photo)
        } catch {
            self.error = error
        }
    }

    public func toggleRecording() async { // starts or stops recording a movie, and writes it to the user's photo library when complete
        guard let mediaLibraryActual = mediaLibrary else {
            return
        }
        switch await captureService.captureActivity {
        case .movieCapture:
            do {
                let movie = try await captureService.stopRecording()
                try await mediaLibraryActual.save(movie: movie)
            } catch {
                self.error = error
            }
        default:
            await captureService.startRecording()
        }
    }

    // MARK: - Private

    private func startObserving() {
        Task(operation: { [weak self] in
            guard let mediaLibraryActual = self?.mediaLibrary else {
                return
            }
            // await new thumbnails that the media library generates when saving a file
            for await thumbnail in mediaLibraryActual.thumbnails {
                if let thumbnail {
                    self?.thumbnail = thumbnail
                }
            }
        })
        Task(operation: { [weak self] in
            guard let captureServiceActual = self?.captureService else {
                return
            }
            // await new capture activity values from the capture service
            for await activity in await captureServiceActual.$captureActivity.values {
                if activity.willCapture {
                    // flash the screen to indicate capture is starting
                    self?.flashScreen()
                } else {
                    self?.captureActivity = activity
                }
            }
        })
        Task(operation: { [weak self] in
            guard let captureServiceActual = self?.captureService else {
                return
            }
            // await updates to the capabilities that the capture service advertises
            for await capabilities in await captureServiceActual.$captureCapabilities.values {
                guard let capabilitiesActual = capabilities else {
                    continue
                }
                self?.isHDRVideoSupported = capabilitiesActual.isHDRSupported
                self?.isVideoHDRSupported = capabilitiesActual.isHDRSupported
            }
        })
        Task(operation: { [weak self] in
            guard let captureServiceActual = self?.captureService else {
                return
            }
            // await updates to a person's interaction with the Camera Control HUD
            for await isShowingFullscreenControls in await captureServiceActual.$isShowingFullscreenControls.values {
                withAnimation {
                    // prefer showing a minimized UI when capture controls enter a fullscreen appearance
                    self?.prefersMinimizedControlsUI = isShowingFullscreenControls
                }
            }
        })
    }

    private func flashScreen() {
        shouldFlashScreen = true
        withAnimation(.linear(duration: 0.01), {
            shouldFlashScreen = false
        })
    }

}
