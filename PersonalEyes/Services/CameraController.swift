@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UIKit

/// Drives the live capture pipeline used by the home screen. The controller
/// owns an ``AVCaptureSession`` that produces both photo data and a stream of
/// video frames. A ``CenteringDetector`` is applied to a throttled subset of
/// the video frames so the UI can react to how well the user has the subject
/// framed in real time.
@MainActor
final class CameraController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case unauthorized
        /// Camera hardware is missing or could not be configured.
        case unavailable
        case starting
        case aligning
        /// Subject has been centered for long enough that a "hold" cue is
        /// played and the actual capture is scheduled to fire after a brief
        /// delay so the user can steady the phone.
        case holding
        case capturing
        case processing
        case showingResult
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var centeringDistance: Float = 1.0
    @Published private(set) var hasSubject: Bool = false
    @Published private(set) var isCenteredEnoughForCapture: Bool = false

    nonisolated let session = AVCaptureSession()

    var onPhotoCaptured: ((UIImage) -> Void)?
    var onError: ((String) -> Void)?

    /// Tunable: how close to the center the object must be (0 = exact center,
    /// 1 = corner). Loose enough that the user just needs the object somewhere
    /// in the frame, not perfectly centered.
    var centeredThreshold: Float = 0.45

    /// Tunable: how many consecutive frames Apple's object-detection must
    /// see the object before the hold cue starts. Two frames at ~10 Hz
    /// reduces noise without making the user wait.
    var framesNeededForHolding: Int = 2

    /// Tunable: how long the "Stop" cue plays before capturing. Short on
    /// purpose so the user does not have to be perfectly steady.
    var holdDuration: TimeInterval = 0.35

    /// When false, capture only happens via ``captureNow()`` (manual shutter).
    /// The centering beep continues to fire so the user still hears framing feedback.
    var isAutoCaptureEnabled: Bool = false

    nonisolated private let sessionQueue = DispatchQueue(
        label: "com.camoulabs.PersonalEyes.session"
    )
    nonisolated private let frameQueue = DispatchQueue(
        label: "com.camoulabs.PersonalEyes.frames",
        qos: .userInteractive
    )
    nonisolated private let photoOutput = AVCapturePhotoOutput()
    nonisolated private let videoOutput = AVCaptureVideoDataOutput()
    nonisolated private let centeringDetector = CenteringDetector()

    /// Touched only on ``sessionQueue``.
    nonisolated(unsafe) private var isConfigured = false
    /// Touched only on ``frameQueue``.
    nonisolated(unsafe) private var lastFrameAnalysisDate: Date = .distantPast

    private var consecutiveCenteredFrames = 0
    nonisolated private let minimumAnalysisInterval: TimeInterval = 0.10
    private var holdTask: Task<Void, Never>?

    func requestAccessAndStart() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            await configureAndStart()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                await configureAndStart()
            } else {
                state = .unauthorized
            }
        case .denied, .restricted:
            state = .unauthorized
        @unknown default:
            state = .unauthorized
        }
    }

    func stop() {
        cancelHold()
        stopSession()
        consecutiveCenteredFrames = 0
        isCenteredEnoughForCapture = false
        hasSubject = false
        centeringDistance = 1.0
        if state != .unauthorized && state != .unavailable {
            state = .idle
        }
    }

    /// Stops the running session and waits until stop completes. Prefer this
    /// before starting again so stop/start cannot race on ``sessionQueue``.
    func stopAndWait() async {
        cancelHold()
        await stopSessionAsync()
        consecutiveCenteredFrames = 0
        isCenteredEnoughForCapture = false
        hasSubject = false
        centeringDistance = 1.0
        if state != .unauthorized && state != .unavailable {
            state = .idle
        }
    }

    func enterShowingResult() {
        cancelHold()
        stopSession()
        consecutiveCenteredFrames = 0
        isCenteredEnoughForCapture = false
        hasSubject = false
        centeringDistance = 1.0
        state = .showingResult
    }

    /// Stops the live preview once a photo has been captured so analysis
    /// does not keep the camera warm.
    func enterProcessing() {
        cancelHold()
        stopSession()
        consecutiveCenteredFrames = 0
        isCenteredEnoughForCapture = false
        state = .processing
    }

    /// Manual capture that mirrors the auto-capture path. Skips the hold cue
    /// because the user has already committed to capturing right now.
    func captureNow() {
        guard state == .aligning || state == .holding else { return }
        cancelHold()
        triggerCapture()
    }

    private func beginHolding() {
        guard isAutoCaptureEnabled else { return }
        guard state == .aligning else { return }
        state = .holding
        holdTask?.cancel()
        let duration = holdDuration
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            } catch {
                return
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard self.state == .holding else { return }
            self.holdTask = nil
            self.triggerCapture()
        }
        holdTask = task
    }

    private func cancelHold() {
        holdTask?.cancel()
        holdTask = nil
        if state == .holding {
            state = .aligning
        }
    }

    private func configureAndStart() async {
        state = .starting
        let configured = await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                // Always stop first so a quick re-shutter cannot race a prior stop.
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                let ok = self.configureSessionIfNeeded()
                if ok {
                    self.session.startRunning()
                }
                continuation.resume(returning: ok)
            }
        }

        guard configured else { return }
        guard state == .starting else { return }
        state = .aligning
    }

    nonisolated private func stopSession() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func stopSessionAsync() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [session] in
                if session.isRunning {
                    session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    /// Configures inputs/outputs once. Subsequent starts only restart the session.
    /// Must run on ``sessionQueue``.
    nonisolated private func configureSessionIfNeeded() -> Bool {
        if isConfigured {
            return true
        }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ),
            let input = try? AVCaptureDeviceInput(device: device)
        else {
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor in
                    self?.onError?("Camera is not available on this device.")
                    self?.state = .unavailable
                }
            }
            return false
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        photoOutput.maxPhotoQualityPrioritization = .balanced

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // Rotate still photos so UIImage is upright in portrait. Leave the
        // video data output in sensor orientation and tell Vision `.right`.
        if let photoConnection = photoOutput.connection(with: .video),
           photoConnection.isVideoRotationAngleSupported(90) {
            photoConnection.videoRotationAngle = 90
        }

        session.commitConfiguration()
        isConfigured = true
        return true
    }

    private func triggerCapture() {
        guard state == .aligning || state == .holding else { return }
        holdTask?.cancel()
        holdTask = nil
        state = .capturing
        consecutiveCenteredFrames = 0
        isCenteredEnoughForCapture = false

        capturePhoto()
    }

    nonisolated private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        let output = self.photoOutput
        sessionQueue.async { [weak self] in
            guard let self else { return }
            output.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Throttle Vision work on the frame queue before running saliency.
        let now = Date()
        guard now.timeIntervalSince(lastFrameAnalysisDate) >= minimumAnalysisInterval else { return }
        lastFrameAnalysisDate = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Back camera buffers stay in landscape sensor orientation; portrait
        // apps map that to CGImagePropertyOrientation.right.
        let reading = centeringDetector.reading(for: pixelBuffer, orientation: .right)

        Task { @MainActor in
            // Centering is only meaningful while the user is actively framing.
            guard self.state == .aligning || self.state == .holding else { return }

            self.centeringDistance = reading.distance
            self.hasSubject = reading.hasSubject

            let isCentered = reading.hasSubject && reading.distance < self.centeredThreshold

            if self.state == .aligning {
                if isCentered {
                    self.consecutiveCenteredFrames += 1
                    self.isCenteredEnoughForCapture = self.consecutiveCenteredFrames >= self.framesNeededForHolding
                    if self.isCenteredEnoughForCapture && self.isAutoCaptureEnabled {
                        self.beginHolding()
                    }
                } else {
                    self.consecutiveCenteredFrames = max(0, self.consecutiveCenteredFrames - 1)
                    self.isCenteredEnoughForCapture = false
                }
            } else if self.state == .holding {
                if !isCentered {
                    // User drifted off-center during the hold; bail back to
                    // aligning so they can re-center without capturing a
                    // mis-framed photo.
                    self.cancelHold()
                    self.consecutiveCenteredFrames = 0
                    self.isCenteredEnoughForCapture = false
                }
            }
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            Task { @MainActor in
                self.onError?(error.localizedDescription)
                self.stop()
            }
            return
        }

        guard
            let data = photo.fileDataRepresentation(),
            let image = UIImage(data: data)
        else {
            Task { @MainActor in
                self.onError?("Could not read the captured photo.")
                self.stop()
            }
            return
        }

        Task { @MainActor in
            self.enterProcessing()
            self.onPhotoCaptured?(image)
        }
    }
}
