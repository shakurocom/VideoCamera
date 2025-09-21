import Foundation
@preconcurrency import AVFoundation
import Combine
import os.log

@globalActor actor CaptureServiceActor: GlobalActor {

    internal static let shared = CaptureServiceActor()

    nonisolated private let executor: any SerialExecutor = DispatchQueueExecutor(CaptureService.sessionQueue)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        return executor.asUnownedSerialExecutor()
    }

}

private final class DispatchQueueExecutor: SerialExecutor {

    private let queue: DispatchQueue

    init(_ queue: DispatchQueue) {
        self.queue = queue
    }

    public func enqueue(_ job: UnownedJob) {
        self.queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    public func checkIsolated() {
        dispatchPrecondition(condition: .onQueue(self.queue))
    }

}

public struct CMSampleBufferUncheckedSendable: @unchecked Sendable {
    public let buffer: CMSampleBuffer
}

@CaptureServiceActor
final class CaptureService: NSObject {

    nonisolated static let logger = Logger()

    struct Options: Sendable {

        let isAudioAllowed: Bool
        let captureModes: [CaptureMode]

        let isVideoFeedEnabled: Bool
        let isVideoFeedShouldDiscardLateFrames: Bool
        let videoFeedSettings: [String: any Sendable]

    }

    private struct CaptureSessionContainer: Sendable {
        let captureSession: AVCaptureSession
    }

    nonisolated static let sessionQueue: DispatchQueue = DispatchQueue(label: "com.videoCamera.sessionQueue")

    // TODO: implement - remove @Published
    /// A value that indicates whether the capture service is idle or capturing a photo or movie.
    @Published private(set) var captureActivity: CaptureActivity = .idle
    /// A value that indicates the current capture capabilities of the service.
    @Published private(set) var captureCapabilities: CaptureCapabilities?
    /// A Boolean value that indicates whether a higher priority event, like receiving a phone call, interrupts the app.
    @Published private(set) var isInterrupted = false
    /// A Boolean value that indicates whether the user enables HDR video capture.
    @Published var isHDRVideoEnabled = false
    /// A Boolean value that indicates whether capture controls are in a fullscreen appearance.
    @Published var isShowingFullscreenControls = false

    let previewSource: PreviewSource  // connects a preview destination with the capture session.

    let didOutputSampleBuffer: AsyncStream<CMSampleBufferUncheckedSendable>

    private let options: Options
    private let captureSessionContainer: CaptureSessionContainer
    private let photoCapture: PhotoCapture?
    private let movieCapture: MovieCapture?
    private let deviceLookup = DeviceLookup()
    private let systemPreferredCamera = SystemPreferredCameraObserver() // monitors the state of the system-preferred camera

    private let didOutputSampleBufferContinuation: AsyncStream<CMSampleBufferUncheckedSendable>.Continuation

    private var activeVideoInput: AVCaptureDeviceInput? // video input for the currently selected device camera
    private(set) var captureMode: CaptureMode?
    private var isSessionConfigured = false
    private var rotationCoordinator: NSObject! // AVCaptureDevice.RotationCoordinator - monitors video device rotations
    private var rotationObservers = [AnyObject]()
    private var controlsMap: [String: [Any]] = [:] // device identifier : capture control (AVCaptureControl)
    private var controlsDelegate = CaptureControlsDelegate() // object that responds to capture control activation and presentation events
    private var subjectAreaChangeTask: Task<Void, Never>?

    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var videoDataOutputQueue: DispatchQueue?

    private var outputServices: [any OutputService] {
        var result: [any OutputService] = []
        if let photoCaptureActual = photoCapture {
            result.append(photoCaptureActual)
        }
        if let movieCaptureActual = movieCapture {
            result.append(movieCaptureActual)
        }
        return result
    }

    private var captureSession: AVCaptureSession {
        return captureSessionContainer.captureSession
    }

    var isAuthorized: Bool { // TODO: implement
        get async {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            var isAuthorized = status == .authorized
            if status == .notDetermined {
                isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            }
            return isAuthorized
        }
    }

    var videoDataOutputSize: CGSize {
        guard let output = videoDataOutput else {
            return CGSize.zero
        }
        if let width = (output.videoSettings[kCVPixelBufferWidthKey as String]) as? NSNumber,
           let height = output.videoSettings[kCVPixelBufferHeightKey as String] as? NSNumber {
            return CGSize(width: width.doubleValue, height: height.doubleValue)
        } else {
            return CGSize.zero
        }
    }

    var videoDataOutputOrientation: AVCaptureVideoOrientation {
        guard let output = videoDataOutput,
              let connection = output.connection(with: AVMediaType.video)
        else {
            return AVCaptureVideoOrientation.portrait
        }
        return connection.videoOrientation
    }

    func smoothAutoFocusEnabled() -> Bool {
        if let device = currentDevice() {
            return device.isSmoothAutoFocusEnabled
        } else {
            return false
        }
    }

    func setSmoothAutoFocusEnabled(_ enabled: Bool) throws {
        guard let device = currentDevice(),
              device.isSmoothAutoFocusSupported,
              device.isSmoothAutoFocusEnabled != enabled
        else {
            return
        }
        try device.lockForConfiguration()
        device.isSmoothAutoFocusEnabled = enabled
        device.unlockForConfiguration()
    }

    // MARK: - Initialization

    @MainActor
    init(options: Options) {
        self.options = options
        let session = AVCaptureSession()
        self.captureSessionContainer = CaptureSessionContainer(captureSession: session)
        self.previewSource = DefaultPreviewSource(session: session)
        self.photoCapture = options.captureModes.contains(.photo) ? PhotoCapture() : nil
        self.movieCapture = options.captureModes.contains(.video) ? MovieCapture() : nil
        let (didOutputSampleBuffer, didOutputSampleBufferContinuation) = AsyncStream.makeStream(of: CMSampleBufferUncheckedSendable.self)
        self.didOutputSampleBuffer = didOutputSampleBuffer
        self.didOutputSampleBufferContinuation = didOutputSampleBufferContinuation
    }

    deinit {
        didOutputSampleBufferContinuation.finish()
    }

    // MARK: - Public

    func start(newCaptureMode: CaptureMode?, isVideoHDREnabledNew: Bool) async throws {
        captureMode = newCaptureMode
        isHDRVideoEnabled = isVideoHDREnabledNew
        guard await isAuthorized, !captureSession.isRunning else { // TODO: implement - isAuthorized
            return
        }
        try setupSession()
        captureSession.startRunning()
    }

    func setCaptureMode(_ captureMode: CaptureMode) throws {
        guard options.captureModes.contains(captureMode) else {
            return
        }
        self.captureMode = captureMode
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        switch captureMode {
        case .photo:
            if photoCapture != nil {
                captureSession.sessionPreset = .photo
                if let movieCaptureActual = movieCapture {
                    // movie capture output should be removed to perform Live Photo capture
                    captureSession.removeOutput(movieCaptureActual.avCaptureOutput)
                }
            }
        case .video:
            if let movieCaptureActual = movieCapture {
                captureSession.sessionPreset = .high
                try addOutput(movieCaptureActual.avCaptureOutput)
                if isHDRVideoEnabled {
                    setHDRVideoEnabled(true)
                }
            }
        }
        updateCaptureCapabilities()
    }

    /// implementation switches between the front and back cameras and, in iPadOS, connected external cameras.
    func selectNextVideoDevice() {
        let videoDevices = deviceLookup.cameras
        guard !videoDevices.isEmpty else {
            return
        }
        let currentDevice = currentDevice()
        let selectedIndex: Int
        if let device = currentDevice, let index = videoDevices.firstIndex(of: device) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }
        var nextIndex = selectedIndex + 1
        if nextIndex == videoDevices.endIndex {
            nextIndex = 0
        }
        let nextDevice = videoDevices[nextIndex]
        guard currentDevice != nextDevice else {
            return
        }
        changeCaptureDevice(to: nextDevice)
        if #available(iOS 17.0, *) {
            AVCaptureDevice.userPreferredCamera = nextDevice
        }
    }

    /// performs a one-time automatic focus and expose operation when person tapping on the preview area.
    func focusAndExpose(at point: CGPoint) {
        // point is in view-space coordinates - converting this point to device coordinates.
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
        do {
            try focusAndExpose(at: devicePoint, isUserInitiated: true)
        } catch {
            CaptureService.logger.debug("Unable to perform focus and exposure operation. \(error)")
        }
    }

    func setFocusMode(_ mode: AVCaptureDevice.FocusMode, focusPointOfInterest: CGPoint) throws {
        guard let device = self.currentDevice() else {
            return
        }
        guard device.isFocusPointOfInterestSupported,
              device.isFocusModeSupported(mode)
        else {
            return
        }
        try device.lockForConfiguration()
        device.focusPointOfInterest = focusPointOfInterest
        device.focusMode = mode
        device.unlockForConfiguration()
    }

    func capturePhoto(with features: PhotoFeatures) async throws -> Photo {
        guard let photoCaptureActual = photoCapture else {
            throw CameraError.photoCaptureNotAllowed
        }
        return try await photoCaptureActual.capturePhoto(with: features)
    }

    func startRecording() {
        movieCapture?.startRecording()
    }

    func stopRecording() async throws -> Movie {
        guard let movieCaptureActual = movieCapture else {
            throw CameraError.movieCaptureNotAllowed
        }
        return try await movieCaptureActual.stopRecording()
    }

    func setHDRVideoEnabled(_ isEnabled: Bool) {
        guard let device = self.currentDevice() else {
            return
        }
        captureSession.beginConfiguration()
        do {
            // if the current device provides a 10-bit HDR format, enable it
            if isEnabled, let format = device.activeFormat10BitVariant {
                try device.lockForConfiguration()
                device.activeFormat = format
                device.unlockForConfiguration()
                isHDRVideoEnabled = true
            } else {
                captureSession.sessionPreset = .high
                isHDRVideoEnabled = false
            }
            captureSession.commitConfiguration()
        } catch {
            CaptureService.logger.error("Unable to obtain lock on device and can't enable HDR video capture.")
            captureSession.commitConfiguration()
        }
    }

    // MARK: - Private

    private func setupSession() throws {
        guard !isSessionConfigured else {
            return
        }

        observeOutputServices()
        observeNotifications()
        observeCaptureControlsState()

        do {
            // TODO: implement - add position: AVCaptureDevice.Position to configuration
            guard let defaultCamera = deviceLookup.getCamera(position: .back) else {
                throw CameraError.videoDeviceUnavailable
            }
            activeVideoInput = try addInput(for: defaultCamera)
            if options.isAudioAllowed {
                let defaultMic = try deviceLookup.defaultMic
                if #available(iOS 26.0, *) {
                    // enable AirPods usage as a high-quality microphone
                    captureSession.configuresApplicationAudioSessionForBluetoothHighQualityRecording = true
                }
                try addInput(for: defaultMic)
            }
            if photoCapture != nil || movieCapture != nil {
                captureSession.sessionPreset = captureMode == .photo ? .photo : .high
                if let photoCaptureActual = photoCapture {
                    try addOutput(photoCaptureActual.avCaptureOutput)
                }
                if let movieCaptureActual = movieCapture, captureMode == .video {
                    try addOutput(movieCaptureActual.avCaptureOutput)
                    setHDRVideoEnabled(isHDRVideoEnabled)
                }
            }
            // video data output
            if options.isVideoFeedEnabled {
                videoDataOutputQueue = DispatchQueue(label: "com.shakuro.devicecamera.videofeedqueue")
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = options.isVideoFeedShouldDiscardLateFrames
                output.videoSettings = options.videoFeedSettings
                output.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
                try addOutput(output)
                videoDataOutput = output
            }
            if #available(iOS 18.0, *) {
                configureControls(for: defaultCamera) // TODO: implement
            }
            monitorSystemPreferredCamera()
            if #available(iOS 17.0, *) {
                createRotationCoordinator(for: defaultCamera) // TODO: implement
            } else {
                // TODO: implement
            }
            observeSubjectAreaChanges(of: defaultCamera) // TODO: implement
            updateCaptureCapabilities() // TODO: implement

            isSessionConfigured = true
        } catch {
            throw CameraError.setupFailed
        }
    }

    @discardableResult
    private func addInput(for device: AVCaptureDevice) throws -> AVCaptureDeviceInput {
        let input = try AVCaptureDeviceInput(device: device)
        if captureSession.canAddInput(input) {
            captureSession.addInput(input)
        } else {
            throw CameraError.addInputFailed
        }
        return input
    }

    private func addOutput(_ output: AVCaptureOutput) throws {
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        } else {
            throw CameraError.addOutputFailed
        }
    }

    private func currentDevice() -> AVCaptureDevice? {
        guard let device = activeVideoInput?.device else {
            return nil
        }
        return device
    }

    @available(iOS 18.0, *)
    private func configureControls(for device: AVCaptureDevice) {
        guard captureSession.supportsControls else {
            return
        }
        captureSession.beginConfiguration()
        for control in captureSession.controls {
            captureSession.removeControl(control)
        }
        for control in createControls(for: device) {
            if captureSession.canAddControl(control) {
                captureSession.addControl(control)
            } else {
                CaptureService.logger.info("Unable to add control \(control).")
            }
        }
        captureSession.setControlsDelegate(controlsDelegate, queue: CaptureService.sessionQueue)
        captureSession.commitConfiguration()
    }

    @available(iOS 18.0, *)
    private func createControls(for device: AVCaptureDevice) -> [AVCaptureControl] {
        if let anyControls = controlsMap[device.uniqueID], let controls = anyControls as? [AVCaptureControl] {
            return controls
        }
        var controls: [AVCaptureControl] = [
            AVCaptureSystemZoomSlider(device: device),
            AVCaptureSystemExposureBiasSlider(device: device)
        ]
        // create a lens position control if the device supports setting a custom position
        if device.isLockingFocusWithCustomLensPositionSupported {
            // create a slider to adjust the value from 0 to 1
            let lensSlider = AVCaptureSlider("Lens Position", symbolName: "circle.dotted.circle", in: 0...1)
            lensSlider.setActionQueue(CaptureService.sessionQueue) { lensPosition in
                do {
                    try device.lockForConfiguration()
                    device.setFocusModeLocked(lensPosition: lensPosition)
                    device.unlockForConfiguration()
                } catch {
                    CaptureService.logger.info("Unable to change the lens position: \(error)")
                }
            }
            controls.append(lensSlider)
        }
        controlsMap[device.uniqueID] = controls.map { $0 as Any }
        return controls
    }

    // Observe notifications of type `subjectAreaDidChangeNotification` for the specified device.
    private func observeSubjectAreaChanges(of device: AVCaptureDevice) {
        // TODO: implement - disable in options???
        subjectAreaChangeTask?.cancel()
        subjectAreaChangeTask = Task {
            for await _ in NotificationCenter.default.notifications(named: AVCaptureDevice.subjectAreaDidChangeNotification,
                                                                    object: device).compactMap({ _ in true }) {
                // perform a system-initiated focus and expose
                try? focusAndExpose(at: CGPoint(x: 0.5, y: 0.5), isUserInitiated: false)
            }
        }
    }

    private func focusAndExpose(at devicePoint: CGPoint, isUserInitiated: Bool) throws {
        guard let device = currentDevice() else {
            return
        }
        // the following mode and point of interest configuration requires obtaining an exclusive lock on the device
        try device.lockForConfiguration()
        let focusMode = isUserInitiated ? AVCaptureDevice.FocusMode.autoFocus : .continuousAutoFocus
        if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
            device.focusPointOfInterest = devicePoint
            device.focusMode = focusMode
        }
        let exposureMode = isUserInitiated ? AVCaptureDevice.ExposureMode.autoExpose : .continuousAutoExposure
        if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
            device.exposurePointOfInterest = devicePoint
            device.exposureMode = exposureMode
        }
        // Enable subject-area change monitoring when performing a user-initiated automatic focus and exposure operation.
        // If this method enables change monitoring, when the device's subject area changes, the app calls this method a
        // second time and resets the device to continuous automatic focus and exposure.
        device.isSubjectAreaChangeMonitoringEnabled = isUserInitiated
        device.unlockForConfiguration()
    }

    // changes the device the service uses for video capture
    private func changeCaptureDevice(to device: AVCaptureDevice) {
        guard let currentInput = activeVideoInput else {
            return
        }
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        // remove the existing video input before attempting to connect a new one
        captureSession.removeInput(currentInput)
        do {
            activeVideoInput = try addInput(for: device)
            if #available(iOS 18.0, *) {
                configureControls(for: device)
            } else {
                // TODO: implement
            }
            if #available(iOS 17.0, *) {
                createRotationCoordinator(for: device)
            } else {
                // TODO: implement
            }
            observeSubjectAreaChanges(of: device)
            updateCaptureCapabilities()
        } catch {
            captureSession.addInput(currentInput)
        }
    }

    /// Monitors changes to the system's preferred camera selection.
    ///
    /// iPadOS supports external cameras. When someone connects an external camera to their iPad,
    /// they're signaling the intent to use the device. The system responds by updating the
    /// system-preferred camera (SPC) selection to this new device. When this occurs, if the SPC
    /// isn't the currently selected camera, switch to the new device.
    private func monitorSystemPreferredCamera() {
        Task(operation: {
            for await camera in systemPreferredCamera.changes {
                if let camera, currentDevice() != camera {
                    CaptureService.logger.debug("Switching camera selection to the system-preferred camera.")
                    changeCaptureDevice(to: camera)
                }
            }
        })
    }

    @available(iOS 17.0, *)
    private func createRotationCoordinator(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: videoPreviewLayer)
        updatePreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        updateCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservers.removeAll()
        rotationObservers.append(
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: .new) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                Task { await self.updatePreviewRotation(angle) }
            }
        )
        rotationObservers.append(
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                Task { await self.updateCaptureRotation(angle) }
            }
        )
        rotationCoordinator = coordinator
    }

    @available(iOS 17.0, *)
    private func updatePreviewRotation(_ angle: CGFloat) {
        let connection = videoPreviewLayer.connection
        Task(operation: { @MainActor in
            connection?.videoRotationAngle = angle
        })
    }

    @available(iOS 17.0, *)
    private func updateCaptureRotation(_ angle: CGFloat) {
        outputServices.forEach { $0.setVideoRotationAngle(angle) }
    }

    private var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        guard let previewLayer = captureSession.connections.compactMap({ $0.videoPreviewLayer }).first else {
            fatalError("The app is misconfigured. The capture session should have a connection to a preview layer.")
        }
        return previewLayer
    }

    /// When the capture session changes, such as changing modes or input devices, the service
    /// calls this method to update its configuration and capabilities. The app uses this state to
    /// determine which features to enable in the user interface.
    private func updateCaptureCapabilities() {
        guard let device = currentDevice() else {
            return
        }
        outputServices.forEach { $0.updateConfiguration(for: device) }
        switch captureMode {
        case .photo:
            captureCapabilities = photoCapture?.capabilities
        case .video:
            captureCapabilities = movieCapture?.capabilities
        case .none:
            break
        }
    }

    /// Merge the `captureActivity` values of the photo and movie capture services,
    /// and assign the value to the actor's property.`
    private func observeOutputServices() {
        if let photoCaptureActual = photoCapture, let movieCaptureActual = movieCapture {
            Publishers.Merge(photoCaptureActual.$captureActivity, movieCaptureActual.$captureActivity).assign(to: &$captureActivity)
        } else if let photoCaptureActual = photoCapture {
            photoCaptureActual.$captureActivity.assign(to: &$captureActivity)
        } else if let movieCaptureActual = movieCapture {
            movieCaptureActual.$captureActivity.assign(to: &$captureActivity)
        }
    }

    /// observe when capture control enter and exit a fullscreen appearance
    private func observeCaptureControlsState() {
        controlsDelegate.$isShowingFullscreenControls
            .assign(to: &$isShowingFullscreenControls)
    }

    private func observeNotifications() {
        Task(operation: {
            for await reason in NotificationCenter.default.notifications(named: AVCaptureSession.wasInterruptedNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject? })
                .compactMap({ AVCaptureSession.InterruptionReason(rawValue: $0.integerValue) }) {
                isInterrupted = [.audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient].contains(reason)
            }
        })

        Task(operation: {
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.interruptionEndedNotification) {
                isInterrupted = false
            }
        })

        Task(operation: {
            for await error in NotificationCenter.default.notifications(named: AVCaptureSession.runtimeErrorNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionErrorKey] as? AVError }) {
                // if the system resets media services, the capture session stops running
                guard error.code == .mediaServicesWereReset else {
                    continue
                }
                if !captureSession.isRunning {
                    captureSession.startRunning()
                }
            }
        })
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let sampleBufferUncheckedSendable: CMSampleBufferUncheckedSendable = CMSampleBufferUncheckedSendable(buffer: sampleBuffer)
        Task(operation: { @CaptureServiceActor in
            didOutputSampleBufferContinuation.yield(sampleBufferUncheckedSendable)
        })
    }

}

// MARK - CaptureControlsDelegate

private class CaptureControlsDelegate: NSObject, AVCaptureSessionControlsDelegate {

    @Published private(set) var isShowingFullscreenControls = false

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        CaptureService.logger.debug("Capture controls active.")
    }

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        isShowingFullscreenControls = true
        CaptureService.logger.debug("Capture controls will enter fullscreen appearance.")
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        isShowingFullscreenControls = false
        CaptureService.logger.debug("Capture controls will exit fullscreen appearance.")
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        CaptureService.logger.debug("Capture controls inactive.")
    }

}
