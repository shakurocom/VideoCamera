import AVFoundation
import Combine

@CaptureServiceActor
final class MovieCapture: OutputService {

    let didUpdateCaptureActivity: AsyncStream<CaptureActivity>

    private(set) var captureActivity: CaptureActivity = .idle
    let avCaptureOutput = AVCaptureMovieFileOutput()

    private let didUpdateCaptureActivityContinuation: AsyncStream<CaptureActivity>.Continuation

    private var movieOutput: AVCaptureMovieFileOutput { avCaptureOutput }
    private var movieCaptureDelegate: MovieCaptureDelegate?
    private let refreshInterval = TimeInterval(0.25) // interval at which to update the recording time
    private var timerCancellable: AnyCancellable?
    private var isHDRSupported = false

    var capabilities: CaptureCapabilities? {
        return CaptureCapabilities(isHDRSupported: isHDRSupported)
    }

    // MARK: - Initialization

    @MainActor
    init() {
        let (didUpdateCaptureActivity, didUpdateCaptureActivityContinuation) = AsyncStream.makeStream(of: CaptureActivity.self)
        self.didUpdateCaptureActivity = didUpdateCaptureActivity
        self.didUpdateCaptureActivityContinuation = didUpdateCaptureActivityContinuation
    }

    deinit {
        didUpdateCaptureActivityContinuation.finish()
    }

    // MARK: - Public

    func startRecording() {
        guard !movieOutput.isRecording else {
            return
        }
        guard let connection = movieOutput.connection(with: .video) else {
            fatalError("Configuration error. No video connection found.")
        }
        // configure connection for HEVC capture
        if movieOutput.availableVideoCodecTypes.contains(.hevc) {
            movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        }
        // enable video stabilization if the connection supports it
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
        // start a timer to update the recording time
        startMonitoringDuration()
        let delegate = MovieCaptureDelegate()
        movieCaptureDelegate = delegate
        movieOutput.startRecording(to: URL.movieFileURL, recordingDelegate: delegate)
    }

    func stopRecording() async throws -> Movie {
        return try await withCheckedThrowingContinuation { (continuation) in
            movieCaptureDelegate?.continuation = continuation
            // stops recording, which causes the output to call the `MovieCaptureDelegate` object.
            movieOutput.stopRecording()
            stopMonitoringDuration()
        }
    }

    func updateConfiguration(for device: AVCaptureDevice) {
        // app supports HDR video capture if the active format supports it
        isHDRSupported = device.activeFormat10BitVariant != nil
    }

    // MARK: - Private

    // starts a timer to update the recording time
    private func startMonitoringDuration() {
        captureActivity = .movieCapture()
        didUpdateCaptureActivityContinuation.yield(captureActivity)
        timerCancellable = Timer.publish(every: refreshInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                // poll the movie output for its recorded duration
                let duration = movieOutput.recordedDuration.seconds
                captureActivity = .movieCapture(duration: duration)
                didUpdateCaptureActivityContinuation.yield(captureActivity)
            }
    }

    private func stopMonitoringDuration() {
        timerCancellable?.cancel()
        captureActivity = .idle
        didUpdateCaptureActivityContinuation.yield(captureActivity)
    }

}

extension MovieCapture {

    private class MovieCaptureDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {

        var continuation: CheckedContinuation<Movie, Error>?

        func fileOutput(_ output: AVCaptureFileOutput,
                        didFinishRecordingTo outputFileURL: URL,
                        from connections: [AVCaptureConnection],
                        error: Error?) {
            if let errorActual = error {
                continuation?.resume(throwing: errorActual)
            } else {
                continuation?.resume(returning: Movie(url: outputFileURL))
            }
        }
    }

}
