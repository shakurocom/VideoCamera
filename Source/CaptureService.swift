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

    private static let queueIDKey = DispatchSpecificKey<ObjectIdentifier>()

    private let queue: DispatchQueue
    private let queueID: ObjectIdentifier

    init(_ queue: DispatchQueue) {
        self.queue = queue
        self.queueID = ObjectIdentifier(queue)
        queue.setSpecific(key: Self.queueIDKey, value: queueID)
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

    public func isIsolatingCurrentContext() -> Bool {
        return DispatchQueue.getSpecific(key: Self.queueIDKey) == queueID
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
        let cameraPosition: AVCaptureDevice.Position
        let videoGravity: AVLayerVideoGravity
        let captureSessionPreset: AVCaptureSession.Preset?
        let isIOS18ControlsEnabled: Bool
        let isIOS17RotationCoordinatorEnabled: Bool
        let isSubjectAreaObserverEnabled: Bool

        let isVideoFeedEnabled: Bool
        let isVideoFeedShouldDiscardLateFrames: Bool
        let videoFeedSettings: [String: any Sendable]

    }

    struct CaptureCapabilities {

        let isLivePhotoCaptureSupported: Bool
        let isHDRSupported: Bool

        init(isLivePhotoCaptureSupported: Bool = false,
             isHDRSupported: Bool = false) {
            self.isLivePhotoCaptureSupported = isLivePhotoCaptureSupported
            self.isHDRSupported = isHDRSupported
        }

    }

    private struct CaptureSessionContainer: Sendable {
        let captureSession: AVCaptureSession
    }

    nonisolated static let sessionQueue: DispatchQueue = DispatchQueue(label: "com.videoCamera.sessionQueue")

    private(set) var captureActivity: CaptureActivity = .idle
    private(set) var captureCapabilities: CaptureCapabilities?
    private(set) var isShowingFullscreenControls = false

    let previewSource: PreviewSource  // connects a preview destination with the capture session.

    let didUpdateCaptureActivity: AsyncStream<CaptureActivity>
    let didUpdateCaptureCapabilities: AsyncStream<CaptureCapabilities?>
    let didUpdateIsShowingFullscreenControls: AsyncStream<Bool>
    let didOutputSampleBuffer: AsyncStream<CMSampleBufferUncheckedSendable>

    private let options: Options
    private let captureSessionContainer: CaptureSessionContainer
    private let photoCapture: PhotoCapture?
    private let movieCapture: MovieCapture?
    private let deviceLookup = DeviceLookup()
    private let systemPreferredCamera = SystemPreferredCameraObserver() // monitors the state of the system-preferred camera

    private let didUpdateCaptureActivityContinuation: AsyncStream<CaptureActivity>.Continuation
    private let didUpdateCaptureCapabilitiesContinuation: AsyncStream<CaptureCapabilities?>.Continuation
    private let didUpdateIsShowingFullscreenControlsContinuation: AsyncStream<Bool>.Continuation
    private let didOutputSampleBufferContinuation: AsyncStream<CMSampleBufferUncheckedSendable>.Continuation

    private var activeVideoInput: AVCaptureDeviceInput? // video input for the currently selected device camera
    private(set) var captureMode: CaptureMode?
    private var isSessionConfigured = false
    private var isHDRVideoEnabled = false
    // indicates whether a higher priority event, like receiving a phone call, interrupts the app.
    private var isInterrupted = false
    private var rotationCoordinator: NSObject! // AVCaptureDevice.RotationCoordinator - monitors video device rotations
    private var rotationObservers = [AnyObject]()
    private var controlsMap: [String: [Any]] = [:] // device identifier : capture control (AVCaptureControl)
    // object that responds to capture control activation and presentation events
    private var controlsDelegate: CaptureControlsDelegate?
    private var subjectAreaChangeTask: Task<Void, Never>?
    private var observeTasks: [Task<Void, Never>] = []

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

    var isAuthorized: Bool {
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

    var hasTorch: Bool {
        if let device = currentDevice() {
            return device.hasTorch
        } else {
            return false
        }
    }

    func torchMode() -> AVCaptureDevice.TorchMode {
        if hasTorch, let device = currentDevice() {
            return device.torchMode
        } else {
            return AVCaptureDevice.TorchMode.off
        }
    }

    func setTorchMode(_ mode: AVCaptureDevice.TorchMode) throws {
        guard hasTorch, let device = currentDevice() else {
            return
        }
        if device.isTorchModeSupported(mode) {
            try device.lockForConfiguration()
            device.torchMode = mode
            device.unlockForConfiguration()
        } else {
            throw VideoCameraError.torchModeUnsupported(requestedMode: mode)
        }
    }

    // MARK: - Initialization

    @MainActor
    init(options: Options) {
        self.options = options
        let session = AVCaptureSession()
        self.captureSessionContainer = CaptureSessionContainer(captureSession: session)
        self.previewSource = DefaultPreviewSource(session: session, videoGravity: options.videoGravity)
        self.photoCapture = options.captureModes.contains(.photo) ? PhotoCapture() : nil
        self.movieCapture = options.captureModes.contains(.video) ? MovieCapture() : nil

        let (didUpdateCaptureActivity, didUpdateCaptureActivityContinuation) = AsyncStream.makeStream(of: CaptureActivity.self)
        self.didUpdateCaptureActivity = didUpdateCaptureActivity
        self.didUpdateCaptureActivityContinuation = didUpdateCaptureActivityContinuation

        let (didUpdateCaptureCapabilities, didUpdateCaptureCapabilitiesContinuation) = AsyncStream.makeStream(of: CaptureCapabilities?.self)
        self.didUpdateCaptureCapabilities = didUpdateCaptureCapabilities
        self.didUpdateCaptureCapabilitiesContinuation = didUpdateCaptureCapabilitiesContinuation

        let (didUpdateIsShowingFullscreenControls, didUpdateIsShowingFullscreenControlsContinuation) = AsyncStream.makeStream(of: Bool.self)
        self.didUpdateIsShowingFullscreenControls = didUpdateIsShowingFullscreenControls
        self.didUpdateIsShowingFullscreenControlsContinuation = didUpdateIsShowingFullscreenControlsContinuation

        let (didOutputSampleBuffer, didOutputSampleBufferContinuation) = AsyncStream.makeStream(of: CMSampleBufferUncheckedSendable.self)
        self.didOutputSampleBuffer = didOutputSampleBuffer
        self.didOutputSampleBufferContinuation = didOutputSampleBufferContinuation
    }

    deinit {
        didUpdateCaptureActivityContinuation.finish()
        didUpdateCaptureCapabilitiesContinuation.finish()
        didUpdateIsShowingFullscreenControlsContinuation.finish()
        didOutputSampleBufferContinuation.finish()
        subjectAreaChangeTask?.cancel()
        observeTasks.forEach({ $0.cancel() })
    }

    // MARK: - Public

    func start(newCaptureMode: CaptureMode?, isVideoHDREnabledNew: Bool) async throws {
        captureMode = newCaptureMode
        isHDRVideoEnabled = isVideoHDREnabledNew
        guard await isAuthorized, !captureSession.isRunning else {
            return
        }
        try setupSessionIfNotConfigured()
        captureSession.startRunning()
    }

    func stopSession() async {
        guard captureSession.isRunning else {
            return
        }
        let session = captureSession
        await MainActor.run {
            for connection in session.connections where connection.videoPreviewLayer != nil {
                connection.videoPreviewLayer?.session = nil
            }
        }
        session.stopRunning()
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

    func setVideoPreviewPaused(_ paused: Bool) {
        let connection = videoPreviewLayer?.connection
        Task(operation: { @MainActor in
            connection?.isEnabled = !paused
        })
    }

    /// performs a one-time automatic focus and expose operation when person tapping on the preview area.
    func focusAndExpose(at point: CGPoint) {
        // point is in view-space coordinates - converting this point to device coordinates.
        guard let devicePoint = videoPreviewLayer?.captureDevicePointConverted(fromLayerPoint: point) else {
            return
        }
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

    func capturePhoto(with features: PhotoCapture.PhotoFeatures) async throws -> PhotoCapture.Photo {
        guard let photoCaptureActual = photoCapture else {
            throw CameraError.photoCaptureNotAllowed
        }
        return try await photoCaptureActual.capturePhoto(with: features)
    }

    func startRecording() {
        try? movieCapture?.startRecording()
    }

    func stopRecording() async throws -> MovieCapture.Movie {
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
        } catch {
            CaptureService.logger.error("Unable to obtain lock on device and can't enable HDR video capture.")
        }
        captureSession.commitConfiguration()
    }

    // MARK: - Private

    private func setupSessionIfNotConfigured() throws {
        guard !isSessionConfigured else {
            return
        }

        observeOutputServices()
        observeNotifications()

        do {
            guard let defaultCamera = deviceLookup.getCamera(position: options.cameraPosition) else {
                throw CameraError.videoDeviceUnavailable
            }

            // problem is monitorSystemPreferredCamera() switches camera
            // Set user preferred camera to match our requested camera position
            // This prevents the system from automatically switching to a different camera
            if #available(iOS 17.0, *) {
                AVCaptureDevice.userPreferredCamera = defaultCamera
            }

            if let preset = options.captureSessionPreset {
                if captureSession.canSetSessionPreset(preset) {
                    captureSession.sessionPreset = preset
                } else {
                    CaptureService.logger.error("Unable to set capture session preset: \(String(describing: preset)); fallback to \(String(describing: self.captureSession.sessionPreset))")
                }
            } else {
                if let captureModeActual = captureMode {
                    captureSession.sessionPreset = captureModeActual == .photo ? .photo : .high
                }
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
            if #available(iOS 18.0, *), options.isIOS18ControlsEnabled {
                configureControls(for: defaultCamera)
            }
            if #available(iOS 17.0, *), options.isIOS17RotationCoordinatorEnabled {
                createRotationCoordinator(for: defaultCamera)
            }
            monitorSystemPreferredCamera()
            if options.isSubjectAreaObserverEnabled {
                observeSubjectAreaChanges(of: defaultCamera)
            }
            updateCaptureCapabilities()

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
        let delegate = CaptureControlsDelegate(didUpdateIsShowingFullscreenControlsContinuation: didUpdateIsShowingFullscreenControlsContinuation)
        controlsDelegate = delegate
        captureSession.setControlsDelegate(delegate, queue: CaptureService.sessionQueue)
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

    private func observeSubjectAreaChanges(of device: AVCaptureDevice) {
        subjectAreaChangeTask?.cancel()
        subjectAreaChangeTask = Task(operation: { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVCaptureDevice.subjectAreaDidChangeNotification,
                                                                    object: device).compactMap({ _ in true }) {
                // perform a system-initiated focus and expose
                try? self?.focusAndExpose(at: CGPoint(x: 0.5, y: 0.5), isUserInitiated: false)
            }
        })
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
        // remove the existing video input before attempting to connect a new one
        captureSession.removeInput(currentInput)
        do {
            activeVideoInput = try addInput(for: device)
            if #available(iOS 18.0, *), options.isIOS18ControlsEnabled {
                configureControls(for: device)
            }
            if #available(iOS 17.0, *), options.isIOS17RotationCoordinatorEnabled {
                createRotationCoordinator(for: device)
            }
            if options.isSubjectAreaObserverEnabled {
                observeSubjectAreaChanges(of: device)
            }
            updateCaptureCapabilities()
        } catch {
            captureSession.addInput(currentInput)
        }
        captureSession.commitConfiguration()
    }

    /// iPadOS supports external cameras. When someone connects an external camera to their iPad,
    /// they're signaling the intent to use the device. The system responds by updating the
    /// system-preferred camera (SPC) selection to this new device. When this occurs, if the SPC
    /// isn't the currently selected camera, switch to the new device.
    private func monitorSystemPreferredCamera() {
        observeTasks.append(Task(operation: { [weak self] in
            guard let changes = self?.systemPreferredCamera.changes else {
                return
            }
            for await camera in changes {
                if let camera, self?.currentDevice() != camera {
                    CaptureService.logger.debug("Switching camera selection to the system-preferred camera.")
                    self?.changeCaptureDevice(to: camera)
                }
            }
        }))
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
                Task(operation: { await self.updatePreviewRotation(angle) })
            }
        )
        rotationObservers.append(
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: .new) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                Task(operation: { await self.updateCaptureRotation(angle) })
            }
        )
        rotationCoordinator = coordinator
    }

    @available(iOS 17.0, *)
    private func updatePreviewRotation(_ angle: CGFloat) {
        let connection = videoPreviewLayer?.connection
        Task(operation: { @MainActor in
            connection?.videoRotationAngle = angle
        })
    }

    @available(iOS 17.0, *)
    private func updateCaptureRotation(_ angle: CGFloat) {
        outputServices.forEach { $0.setVideoRotationAngle(angle) }
    }

    private var videoPreviewLayer: AVCaptureVideoPreviewLayer? {
        guard let previewLayer = captureSession.connections.compactMap({ $0.videoPreviewLayer }).first else {
            debugPrint("The app is misconfigured. The capture session should have a connection to a preview layer.")
            return nil
        }
        return previewLayer
    }

    /// when the capture session changes, such as changing modes or input devices, the service
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
            didUpdateCaptureCapabilitiesContinuation.yield(captureCapabilities)
        case .video:
            captureCapabilities = movieCapture?.capabilities
            didUpdateCaptureCapabilitiesContinuation.yield(captureCapabilities)
        case .none:
            break
        }
    }

    private func observeOutputServices() {
        if let photoCaptureActual = photoCapture {
            observeTasks.append(Task(operation: { [weak self] in
                for await captureActivity in photoCaptureActual.didUpdateCaptureActivity where self?.captureActivity != captureActivity {
                    self?.captureActivity = captureActivity
                    self?.didUpdateCaptureActivityContinuation.yield(captureActivity)
                }
            }))
        }
        if let movieCaptureActual = movieCapture {
            observeTasks.append(Task(operation: { [weak self] in
                for await captureActivity in movieCaptureActual.didUpdateCaptureActivity where self?.captureActivity != captureActivity {
                    self?.captureActivity = captureActivity
                    self?.didUpdateCaptureActivityContinuation.yield(captureActivity)
                }
            }))
        }
    }

    private func observeNotifications() {
        observeTasks.append(Task(operation: { [weak self] in
            for await reason in NotificationCenter.default.notifications(named: AVCaptureSession.wasInterruptedNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject? })
                .compactMap({ AVCaptureSession.InterruptionReason(rawValue: $0.integerValue) }) {
                self?.isInterrupted = [.audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient].contains(reason)
            }
        }))

        observeTasks.append(Task(operation: { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVCaptureSession.interruptionEndedNotification) {
                self?.isInterrupted = false
            }
        }))

        observeTasks.append(Task(operation: { [weak self] in
            for await error in NotificationCenter.default.notifications(named: AVCaptureSession.runtimeErrorNotification)
                .compactMap({ $0.userInfo?[AVCaptureSessionErrorKey] as? AVError }) {
                // if the system resets media services, the capture session stops running
                guard error.code == .mediaServicesWereReset else {
                    continue
                }
                if let session = self?.captureSession, !session.isRunning {
                    session.startRunning()
                }
            }
        }))
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let sampleBufferUncheckedSendable: CMSampleBufferUncheckedSendable = CMSampleBufferUncheckedSendable(buffer: sampleBuffer)
        Task(operation: { @CaptureServiceActor [weak self] in
            self?.didOutputSampleBufferContinuation.yield(sampleBufferUncheckedSendable)
        })
    }

}

// MARK: - CaptureControlsDelegate

private class CaptureControlsDelegate: NSObject, AVCaptureSessionControlsDelegate {

    private var isShowingFullscreenControls = false
    private let didUpdateIsShowingFullscreenControlsContinuation: AsyncStream<Bool>.Continuation

    init(didUpdateIsShowingFullscreenControlsContinuation: AsyncStream<Bool>.Continuation) {
        self.didUpdateIsShowingFullscreenControlsContinuation = didUpdateIsShowingFullscreenControlsContinuation
    }

    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {
        CaptureService.logger.debug("Capture controls active.")
    }

    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        if !isShowingFullscreenControls {
            isShowingFullscreenControls = true
            didUpdateIsShowingFullscreenControlsContinuation.yield(isShowingFullscreenControls)
            CaptureService.logger.debug("Capture controls will enter fullscreen appearance.")
        }
    }

    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        if isShowingFullscreenControls {
            isShowingFullscreenControls = false
            didUpdateIsShowingFullscreenControlsContinuation.yield(isShowingFullscreenControls)
            CaptureService.logger.debug("Capture controls will exit fullscreen appearance.")
        }
    }

    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        CaptureService.logger.debug("Capture controls inactive.")
    }

}
