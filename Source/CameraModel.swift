@preconcurrency import AVFoundation
import SwiftUI

@MainActor
public final class CameraModel: ObservableObject, Camera {

    public struct Options {

        public let isAudioAllowed: Bool
        public let captureModes: [CaptureMode]
        public let cameraPosition: AVCaptureDevice.Position
        public let videoGravity: AVLayerVideoGravity
        public let captureSessionPreset: AVCaptureSession.Preset?
        public let isIOS18ControlsEnabled: Bool
        public let isIOS17RotationCoordinatorEnabled: Bool
        public let isSubjectAreaObserverEnabled: Bool

        let isVideoFeedEnabled: Bool
        let isVideoFeedShouldDiscardLateFrames: Bool
        let videoFeedSettings: [String: any Sendable]

        public init(isAudioAllowed: Bool = false,
                    captureModes: [CaptureMode] = [],
                    cameraPosition: AVCaptureDevice.Position = AVCaptureDevice.Position.back,
                    videoGravity: AVLayerVideoGravity = .resizeAspect,
                    captureSessionPreset: AVCaptureSession.Preset? = nil,
                    isIOS18ControlsEnabled: Bool = false,
                    isIOS17RotationCoordinatorEnabled: Bool = false,
                    isSubjectAreaObserverEnabled: Bool = false,
                    isVideoFeedEnabled: Bool = false,
                    isVideoFeedShouldDiscardLateFrames: Bool = true,
                    videoFeedSettings: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]) {
            self.isAudioAllowed = isAudioAllowed
            self.captureModes = captureModes
            self.cameraPosition = cameraPosition
            self.videoGravity = videoGravity
            self.captureSessionPreset = captureSessionPreset
            self.isIOS18ControlsEnabled = isIOS18ControlsEnabled
            self.isIOS17RotationCoordinatorEnabled = isIOS17RotationCoordinatorEnabled
            self.isSubjectAreaObserverEnabled = isSubjectAreaObserverEnabled
            self.isVideoFeedEnabled = isVideoFeedEnabled
            self.isVideoFeedShouldDiscardLateFrames = isVideoFeedShouldDiscardLateFrames
            self.videoFeedSettings = videoFeedSettings
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
            Task(operation: {
                await captureService.setHDRVideoEnabled(isHDRVideoEnabled)
            })
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

    private var observeTasks: [Task<Void, Never>] = []

    public var didOutputSampleBuffer: AsyncStream<CMSampleBufferUncheckedSendable> {
        return captureService.didOutputSampleBuffer
    }

    public var hasTorch: Bool {
        get async {
            return await captureService.hasTorch
        }
    }

    // MARK: - Initialization

    public init(options: Options) {
        self.options = options
        self.captureService = CaptureService(options: CaptureService.Options(
            isAudioAllowed: options.isAudioAllowed,
            captureModes: options.captureModes,
            cameraPosition: options.cameraPosition,
            videoGravity: options.videoGravity,
            captureSessionPreset: options.captureSessionPreset,
            isIOS18ControlsEnabled: options.isIOS18ControlsEnabled,
            isIOS17RotationCoordinatorEnabled: options.isIOS17RotationCoordinatorEnabled,
            isSubjectAreaObserverEnabled: options.isSubjectAreaObserverEnabled,
            isVideoFeedEnabled: options.isVideoFeedEnabled,
            isVideoFeedShouldDiscardLateFrames: options.isVideoFeedShouldDiscardLateFrames,
            videoFeedSettings: options.videoFeedSettings
        ))
        self.mediaLibrary = options.captureModes.isEmpty ? nil : MediaLibrary()
        self.captureMode = options.captureModes.first
    }

    deinit {
        observeTasks.forEach({ $0.cancel() })
    }

    // MARK: - Public

    public func videoDataOutputSize() async -> CGSize {
        return await captureService.videoDataOutputSize
    }

    public func smoothAutoFocusEnabled() async -> Bool {
        return await captureService.smoothAutoFocusEnabled()
    }

    public func setSmoothAutoFocusEnabled(_ enabled: Bool) async throws {
        try await captureService.setSmoothAutoFocusEnabled(enabled)
    }

    public func torchMode() async -> AVCaptureDevice.TorchMode {
        return await captureService.torchMode()
    }

    public func setTorchMode(_ mode: AVCaptureDevice.TorchMode) async throws {
        try await captureService.setTorchMode(mode)
    }

    public func start() async throws {
        guard await captureService.isAuthorized else {
            status = .unauthorized
            return
        }
        do {
            try await captureService.start(newCaptureMode: captureMode, isVideoHDREnabledNew: isVideoHDREnabled)
            startObserving()
            status = .running
        } catch {
            CaptureService.logger.error("Failed to start capture service. \(error)")
            status = .failed
            throw error
        }
    }

    public func stopSession() async {
        await captureService.stopSession()
        status = .unknown
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

    public func setVideoPreviewPaused(_ paused: Bool) async {
        await captureService.setVideoPreviewPaused(paused)
    }

    public func focusAndExpose(at point: CGPoint) async { // func performs a one-time automatic focus and exposure operation
        await captureService.focusAndExpose(at: point)
    }

    public func setFocusMode(_ mode: AVCaptureDevice.FocusMode, focusPointOfInterest: CGPoint) async throws {
        try await captureService.setFocusMode(mode, focusPointOfInterest: focusPointOfInterest)
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

}

// MARK: - Private

private extension CameraModel {

    private func startObserving() {
        observeTasks.append(Task(operation: { [weak self] in
            guard let mediaLibraryActual = self?.mediaLibrary else {
                return
            }
            // await new thumbnails that the media library generates when saving a file
            for await thumbnail in mediaLibraryActual.thumbnails {
                if let thumbnail {
                    self?.thumbnail = thumbnail
                }
            }
        }))
        observeTasks.append(Task(operation: { [weak self] in
            guard let captureServiceActual = self?.captureService else {
                return
            }
            // await new capture activity values from the capture service
            for await activity in captureServiceActual.didUpdateCaptureActivity {
                if activity.willCapture {
                    // flash the screen to indicate capture is starting
                    self?.flashScreen()
                } else {
                    self?.captureActivity = activity
                }
            }
        }))
        observeTasks.append(Task(operation: { [weak self] in
            guard let captureServiceActual = self?.captureService else {
                return
            }
            for await capabilities in captureServiceActual.didUpdateCaptureCapabilities {
                guard let capabilitiesActual = capabilities else {
                    continue
                }
                self?.isHDRVideoSupported = capabilitiesActual.isHDRSupported
                self?.isVideoHDRSupported = capabilitiesActual.isHDRSupported
            }
        }))
        observeTasks.append(Task(operation: { [weak self] in
            guard let captureServiceActual = self?.captureService else {
                return
            }
            // await updates to a person's interaction with the Camera Control HUD
            for await isShowingFullscreenControls in captureServiceActual.didUpdateIsShowingFullscreenControls {
                withAnimation {
                    // prefer showing a minimized UI when capture controls enter a fullscreen appearance
                    self?.prefersMinimizedControlsUI = isShowingFullscreenControls
                }
            }
        }))
    }

    private func flashScreen() {
        shouldFlashScreen = true
        withAnimation(.linear(duration: 0.01), {
            shouldFlashScreen = false
        })
    }

}
