import Foundation
@preconcurrency import AVFoundation
import Combine

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

@CaptureServiceActor
final class CaptureService {

    struct Options {
        let isAudioAvailable: Bool
    }

    private struct CaptureSessionContainer: Sendable {
        let captureSession: AVCaptureSession
    }

    nonisolated static let sessionQueue: DispatchQueue = DispatchQueue(label: "com.videoCamera.sessionQueue")

    // TODO: implement - remove @Published
    /// A value that indicates whether the capture service is idle or capturing a photo or movie.
    @Published private(set) var captureActivity: CaptureActivity = .idle
    /// A value that indicates the current capture capabilities of the service.
    @Published private(set) var captureCapabilities = CaptureCapabilities.unknown
    /// A Boolean value that indicates whether a higher priority event, like receiving a phone call, interrupts the app.
    @Published private(set) var isInterrupted = false
    /// A Boolean value that indicates whether the user enables HDR video capture.
    @Published var isHDRVideoEnabled = false
    /// A Boolean value that indicates whether capture controls are in a fullscreen appearance.
    @Published var isShowingFullscreenControls = false

    let previewSource: PreviewSource  // connects a preview destination with the capture session.

    private let options: Options
    private let captureSessionContainer: CaptureSessionContainer
    private let photoCapture: PhotoCapture // TODO: implement - make optional and configurable ?
    private let movieCapture: MovieCapture // TODO: implement - make optional and configurable ?

    // The video input for the currently selected device camera.
    private var activeVideoInput: AVCaptureDeviceInput?

    // The mode of capture, either photo or video. Defaults to photo.
    private(set) var captureMode = CaptureMode.photo

    // An object the service uses to retrieve capture devices.
    private let deviceLookup = DeviceLookup()

    // An object that monitors the state of the system-preferred camera.
    private let systemPreferredCamera = SystemPreferredCameraObserver()

    // An object that monitors video device rotations.
    private var rotationCoordinator: NSObject! // AVCaptureDevice.RotationCoordinator
    private var rotationObservers = [AnyObject]()

    // A Boolean value that indicates whether the actor finished its required configuration.
    private var isSessionConfigured = false

    private var controlsMap: [String: [Any]] = [:] // device identifier : capture control (AVCaptureControl)
    private var controlsDelegate = CaptureControlsDelegate() // object that responds to capture control activation and presentation events
    private var subjectAreaChangeTask: Task<Void, Never>?

    private var outputServices: [any OutputService] {
        return [photoCapture, movieCapture]
    }

    @MainActor
    init(options: Options) {
        self.options = options
        let session = AVCaptureSession()
        self.captureSessionContainer = CaptureSessionContainer(captureSession: session)
        self.previewSource = DefaultPreviewSource(session: session)
        self.photoCapture = PhotoCapture()
        self.movieCapture = MovieCapture()
    }

    private var captureSession: AVCaptureSession {
        return captureSessionContainer.captureSession
    }

    // MARK: - Authorization
    /// A Boolean value that indicates whether a person authorizes this app to use
    /// device cameras and microphones. If they haven't previously authorized the
    /// app, querying this property prompts them for authorization.
    var isAuthorized: Bool {
        get async {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            // Determine whether a person previously authorized camera access.
            var isAuthorized = status == .authorized
            // If the system hasn't determined their authorization status,
            // explicitly prompt them for approval.
            if status == .notDetermined {
                isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            }
            return isAuthorized
        }
    }

    // MARK: - Capture session life cycle
    func start(with state: CameraState) async throws {
        captureMode = state.captureMode
        isHDRVideoEnabled = state.isVideoHDREnabled
        guard await isAuthorized, !captureSession.isRunning else {
            return
        }
        try setupSession()
        captureSession.startRunning()
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
            // camera
            guard let defaultCamera = deviceLookup.getCamera(position: .back) else {
                throw CameraError.videoDeviceUnavailable
            }
            activeVideoInput = try addInput(for: defaultCamera)
            // audio
            if options.isAudioAvailable {
                let defaultMic = try deviceLookup.defaultMic
                if #available(iOS 26.0, *) {
                    // enable AirPods usage as a high-quality microphone
                    captureSession.configuresApplicationAudioSessionForBluetoothHighQualityRecording = true
                }
                try addInput(for: defaultMic)
            }

            // TODO: implement - configurable
            captureSession.sessionPreset = captureMode == .photo ? .photo : .high // TODO: implement
            try addOutput(photoCapture.avCaptureOutput)

            // TODO: implement - configurable
            if captureMode == .video {
                try addOutput(movieCapture.avCaptureOutput)
                setHDRVideoEnabled(isHDRVideoEnabled)
            }
            if #available(iOS 18.0, *) {
                configureControls(for: defaultCamera)
            }
            monitorSystemPreferredCamera()
            if #available(iOS 17.0, *) {
                createRotationCoordinator(for: defaultCamera)
            } else {
                // TODO: implement
            }
            observeSubjectAreaChanges(of: defaultCamera)
            updateCaptureCapabilities()

            isSessionConfigured = true
        } catch {
            throw CameraError.setupFailed
        }
    }

    // Adds an input to the capture session to connect the specified capture device.
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

    // Adds an output to the capture session to connect the specified capture device, if allowed.
    private func addOutput(_ output: AVCaptureOutput) throws {
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        } else {
            throw CameraError.addOutputFailed
        }
    }

    // The device for the active video input.
    private var currentDevice: AVCaptureDevice {
        guard let device = activeVideoInput?.device else {
            fatalError("No device found for current video input.")
        }
        return device
    }

    @available(iOS 18.0, *)
    private func configureControls(for device: AVCaptureDevice) {
        guard captureSession.supportsControls else {
            return
        }

        // Begin configuring the capture session.
        captureSession.beginConfiguration()

        // Remove previously configured controls, if any.
        for control in captureSession.controls {
            captureSession.removeControl(control)
        }

        // Create controls and add them to the capture session.
        for control in createControls(for: device) {
            if captureSession.canAddControl(control) {
                captureSession.addControl(control)
            } else {
                logger.info("Unable to add control \(control).")
            }
        }

        // Set the controls delegate.
        captureSession.setControlsDelegate(controlsDelegate, queue: CaptureService.sessionQueue)

        // Commit the capture session configuration.
        captureSession.commitConfiguration()
    }

    @available(iOS 18.0, *)
    func createControls(for device: AVCaptureDevice) -> [AVCaptureControl] {
        if let anyControls = controlsMap[device.uniqueID], let controls = anyControls as? [AVCaptureControl] {
            return controls
        }
        // Define the default controls.
        var controls: [AVCaptureControl] = [
            AVCaptureSystemZoomSlider(device: device),
            AVCaptureSystemExposureBiasSlider(device: device)
        ]
        // Create a lens position control if the device supports setting a custom position.
        if device.isLockingFocusWithCustomLensPositionSupported {
            // Create a slider to adjust the value from 0 to 1.
            let lensSlider = AVCaptureSlider("Lens Position", symbolName: "circle.dotted.circle", in: 0...1)
            // Perform the slider's action on the session queue.
            lensSlider.setActionQueue(CaptureService.sessionQueue) { lensPosition in
                do {
                    try device.lockForConfiguration()
                    device.setFocusModeLocked(lensPosition: lensPosition)
                    device.unlockForConfiguration()
                } catch {
                    logger.info("Unable to change the lens position: \(error)")
                }
            }
            // Add the slider the controls array.
            controls.append(lensSlider)
        }
        // Store the controls for future use.
        controlsMap[device.uniqueID] = controls.map { $0 as Any }
        // Return typed controls.
        return controls
    }

    // Observe notifications of type `subjectAreaDidChangeNotification` for the specified device.
    private func observeSubjectAreaChanges(of device: AVCaptureDevice) {
        // Cancel the previous observation task.
        subjectAreaChangeTask?.cancel()
        subjectAreaChangeTask = Task {
            // Signal true when this notification occurs.
            for await _ in NotificationCenter.default.notifications(named: AVCaptureDevice.subjectAreaDidChangeNotification, object: device).compactMap({ _ in true }) {
                // Perform a system-initiated focus and expose.
                try? focusAndExpose(at: CGPoint(x: 0.5, y: 0.5), isUserInitiated: false)
            }
        }
    }

    private func focusAndExpose(at devicePoint: CGPoint, isUserInitiated: Bool) throws {
        // Configure the current device.
        let device = currentDevice

        // The following mode and point of interest configuration requires obtaining an exclusive lock on the device.
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

        // Release the lock.
        device.unlockForConfiguration()
    }

    // MARK: - Capture mode selection

    /// Changes the mode of capture, which can be `photo` or `video`.
    ///
    /// - Parameter `captureMode`: The capture mode to enable.
    func setCaptureMode(_ captureMode: CaptureMode) throws {
        // Update the internal capture mode value before performing the session configuration.
        self.captureMode = captureMode

        // Change the configuration atomically.
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Configure the capture session for the selected capture mode.
        switch captureMode {
        case .photo:
            // The app needs to remove the movie capture output to perform Live Photo capture.
            captureSession.sessionPreset = .photo
            captureSession.removeOutput(movieCapture.avCaptureOutput)
        case .video:
            captureSession.sessionPreset = .high
            try addOutput(movieCapture.avCaptureOutput)
            if isHDRVideoEnabled {
                setHDRVideoEnabled(true)
            }
        }

        // Update the advertised capabilities after reconfiguration.
        updateCaptureCapabilities()
    }

    // MARK: - Device selection

    /// Changes the capture device that provides video input.
    ///
    /// The app calls this method in response to the user tapping the button in the UI to change cameras.
    /// The implementation switches between the front and back cameras and, in iPadOS,
    /// connected external cameras.
    func selectNextVideoDevice() {
        // The array of available video capture devices.
        let videoDevices = deviceLookup.cameras

        // Find the index of the currently selected video device.
        let selectedIndex = videoDevices.firstIndex(of: currentDevice) ?? 0
        // Get the next index.
        var nextIndex = selectedIndex + 1
        // Wrap around if the next index is invalid.
        if nextIndex == videoDevices.endIndex {
            nextIndex = 0
        }

        let nextDevice = videoDevices[nextIndex]
        // Change the session's active capture device.
        changeCaptureDevice(to: nextDevice)

        // The app only calls this method in response to the user requesting to switch cameras.
        // Set the new selection as the user's preferred camera.
        //        AVCaptureDevice.userPreferredCamera = nextDevice
    }

    // Changes the device the service uses for video capture.
    private func changeCaptureDevice(to device: AVCaptureDevice) {
        // The service must have a valid video input prior to calling this method.
        guard let currentInput = activeVideoInput else { fatalError() }

        // Bracket the following configuration in a begin/commit configuration pair.
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Remove the existing video input before attempting to connect a new one.
        captureSession.removeInput(currentInput)
        do {
            // Attempt to connect a new input and device to the capture session.
            activeVideoInput = try addInput(for: device)
            // Configure capture controls for new device selection.
            if #available(iOS 18.0, *) {
                configureControls(for: device)
            } else {
                // TODO: implement
            }
            // Configure a new rotation coordinator for the new device.
            if #available(iOS 17.0, *) {
                createRotationCoordinator(for: device)
            } else {
                // TODO: implement
            }
            // Register for device observations.
            observeSubjectAreaChanges(of: device)
            // Update the service's advertised capabilities.
            updateCaptureCapabilities()
        } catch {
            // Reconnect the existing camera on failure.
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
        Task {
            // An object monitors changes to system-preferred camera (SPC) value.
            for await camera in systemPreferredCamera.changes {
                // If the SPC isn't the currently selected camera, attempt to change to that device.
                if let camera, currentDevice != camera {
                    logger.debug("Switching camera selection to the system-preferred camera.")
                    changeCaptureDevice(to: camera)
                }
            }
        }
    }

    // MARK: - Rotation handling

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
        Task { @MainActor in
            connection?.videoRotationAngle = angle
        }
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

    // MARK: - Automatic focus and exposure

    /// Performs a one-time automatic focus and expose operation.
    ///
    /// The app calls this method as the result of a person tapping on the preview area.
    func focusAndExpose(at point: CGPoint) {
        // The point this call receives is in view-space coordinates. Convert this point to device coordinates.
        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: point)
        do {
            // Perform a user-initiated focus and expose.
            try focusAndExpose(at: devicePoint, isUserInitiated: true)
        } catch {
            logger.debug("Unable to perform focus and exposure operation. \(error)")
        }
    }

    func capturePhoto(with features: PhotoFeatures) async throws -> Photo {
        return try await photoCapture.capturePhoto(with: features)
    }

    func startRecording() {
        movieCapture.startRecording()
    }

    func stopRecording() async throws -> Movie {
        try await movieCapture.stopRecording()
    }

    /// Sets whether the app captures HDR video.
    func setHDRVideoEnabled(_ isEnabled: Bool) {
        // Bracket the following configuration in a begin/commit configuration pair.
        captureSession.beginConfiguration()
        do {
            // If the current device provides a 10-bit HDR format, enable it for use.
            if isEnabled, let format = currentDevice.activeFormat10BitVariant {
                try currentDevice.lockForConfiguration()
                currentDevice.activeFormat = format
                currentDevice.unlockForConfiguration()
                isHDRVideoEnabled = true
            } else {
                captureSession.sessionPreset = .high
                isHDRVideoEnabled = false
            }
            captureSession.commitConfiguration()
        } catch {
            logger.error("Unable to obtain lock on device and can't enable HDR video capture.")
            captureSession.commitConfiguration()
        }
    }

    // MARK: - Internal state management
    /// Updates the state of the actor to ensure its advertised capabilities are accurate.
    ///
    /// When the capture session changes, such as changing modes or input devices, the service
    /// calls this method to update its configuration and capabilities. The app uses this state to
    /// determine which features to enable in the user interface.
    private func updateCaptureCapabilities() {
        // Update the output service configuration.
        outputServices.forEach { $0.updateConfiguration(for: currentDevice) }
        // Set the capture service's capabilities for the selected mode.
        switch captureMode {
        case .photo:
            captureCapabilities = photoCapture.capabilities
        case .video:
            captureCapabilities = movieCapture.capabilities
        }
    }

    /// Merge the `captureActivity` values of the photo and movie capture services,
    /// and assign the value to the actor's property.`
    private func observeOutputServices() {
        Publishers.Merge(photoCapture.$captureActivity, movieCapture.$captureActivity)
            .assign(to: &$captureActivity)
    }

    /// Observe when capture control enter and exit a fullscreen appearance.
    private func observeCaptureControlsState() {
        controlsDelegate.$isShowingFullscreenControls
            .assign(to: &$isShowingFullscreenControls)
    }

    /// Observe capture-related notifications.
    private func observeNotifications() {
        Task {
            for await reason in NotificationCenter.default.notifications(named: AVCaptureSession.wasInterruptedNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject? })
                .compactMap({ AVCaptureSession.InterruptionReason(rawValue: $0.integerValue) }) {
                /// Set the `isInterrupted` state as appropriate.
                isInterrupted = [.audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient].contains(reason)
            }
        }

        Task {
            // Await notification of the end of an interruption.
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.interruptionEndedNotification) {
                isInterrupted = false
            }
        }

        Task {
            for await error in NotificationCenter.default.notifications(named: AVCaptureSession.runtimeErrorNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionErrorKey] as? AVError }) {
                // If the system resets media services, the capture session stops running.
                if error.code == .mediaServicesWereReset {
                    if !captureSession.isRunning {
                        captureSession.startRunning()
                    }
                }
            }
        }
    }
}

class CaptureControlsDelegate: NSObject, AVCaptureSessionControlsDelegate {

    @Published private(set) var isShowingFullscreenControls = false

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        logger.debug("Capture controls active.")
    }

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        isShowingFullscreenControls = true
        logger.debug("Capture controls will enter fullscreen appearance.")
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        isShowingFullscreenControls = false
        logger.debug("Capture controls will exit fullscreen appearance.")
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        logger.debug("Capture controls inactive.")
    }
}

