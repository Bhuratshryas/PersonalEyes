@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UIKit

/// Drives the live capture pipeline used by the home screen. Frames are
/// analyzed by ``ObjectBoxDetector`` (YOLO-style boxes) so aiming beeps and
/// auto-capture track the object bounding-box center.
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
    @Published private(set) var subjectOffsetX: Float = 0
    @Published private(set) var subjectOffsetY: Float = 0
    @Published private(set) var hasSubject: Bool = false
    @Published private(set) var isCenteredEnoughForCapture: Bool = false

    nonisolated let session = AVCaptureSession()

    var onPhotoCaptured: ((UIImage, CGRect?) -> Void)?
    var onError: ((String) -> Void)?

    /// How close the object-box center must be to the frame center.
    var centeredThreshold: Float = 0.28

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
    nonisolated private let objectDetector = ObjectBoxDetector()

    @Published private(set) var subjectBox: CGRect?
    @Published private(set) var subjectLabel: String?

    /// Touched only on ``sessionQueue``.
    nonisolated(unsafe) private var isConfigured = false
    /// Touched only on ``frameQueue``.
    nonisolated(unsafe) private var lastFrameAnalysisDate: Date = .distantPast
    nonisolated private let readingLock = NSLock()
    nonisolated(unsafe) private var pendingReading: ObjectBoxReading?
    nonisolated(unsafe) private var isMainUpdateScheduled = false

    private var consecutiveCenteredFrames = 0
    nonisolated private let minimumAnalysisInterval: TimeInterval = 0.10
    private var holdTask: Task<Void, Never>?
    private var captureTimeoutTask: Task<Void, Never>?
    private var isCaptureInFlight = false

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
        cancelCaptureTimeout()
        isCaptureInFlight = false
        stopSession()
        resetFramingMetrics()
        if state != .unauthorized && state != .unavailable {
            state = .idle
        }
    }

    /// Stops the running session and waits until stop completes. Prefer this
    /// before starting again so stop/start cannot race on ``sessionQueue``.
    func stopAndWait() async {
        cancelHold()
        cancelCaptureTimeout()
        isCaptureInFlight = false
        await stopSessionAsync()
        resetFramingMetrics()
        if state != .unauthorized && state != .unavailable {
            state = .idle
        }
    }

    func enterShowingResult() {
        cancelHold()
        cancelCaptureTimeout()
        isCaptureInFlight = false
        // Keep the AVCaptureSession running. Repeated stop/start after every
        // photo wedges the camera after a few captures on many devices.
        resetFramingMetrics()
        state = .showingResult
    }

    /// Stops aiming feedback once a photo has been captured. Leaves the
    /// capture session running so the next photo can start quickly.
    func enterProcessing() {
        cancelHold()
        cancelCaptureTimeout()
        isCaptureInFlight = false
        consecutiveCenteredFrames = 0
        isCenteredEnoughForCapture = false
        state = .processing
    }

    /// After the user dismisses a result, reopen aiming without a full
    /// camera teardown when the session is still warm.
    func prepareForNextCapture() async {
        cancelHold()
        cancelCaptureTimeout()
        isCaptureInFlight = false
        resetFramingMetrics()

        if await isSessionRunning() {
            state = .aligning
            return
        }

        // Session died — restart with short backoff (avoids permanent hang).
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: UInt64(350_000_000 * attempt))
                await stopSessionAsync()
            }
            await requestAccessAndStart()
            if state == .aligning { return }
            if state == .unauthorized || state == .unavailable { return }
        }

        if state != .aligning && state != .unauthorized && state != .unavailable {
            state = .idle
            onError?("Camera could not restart. Tap the shutter to try again.")
        }
    }

    private func isSessionRunning() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            sessionQueue.async { [session] in
                continuation.resume(returning: session.isRunning)
            }
        }
    }

    private func resetFramingMetrics() {
        consecutiveCenteredFrames = 0
        isCenteredEnoughForCapture = false
        hasSubject = false
        centeringDistance = 1.0
        subjectOffsetX = 0
        subjectOffsetY = 0
        subjectBox = nil
        subjectLabel = nil
        objectDetector.resetTracking()
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.readingLock.lock()
            self.pendingReading = nil
            self.readingLock.unlock()
        }
    }

    /// Manual capture that mirrors the auto-capture path. Skips the hold cue
    /// because the user has already committed to capturing right now.
    func captureNow() {
        guard state == .aligning || state == .holding else { return }
        guard !isCaptureInFlight else { return }
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

    private func cancelCaptureTimeout() {
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
    }

    private func configureAndStart() async {
        state = .starting
        let configured = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                let ok = self.configureSessionIfNeeded()
                if ok {
                    self.session.startRunning()
                }
                continuation.resume(returning: ok && self.session.isRunning)
            }
        }

        guard configured else {
            // Never leave the UI stuck in `.starting` after a failed restart.
            if state == .starting {
                state = .idle
                onError?("Camera could not start. Tap the shutter to try again.")
            }
            return
        }
        guard state == .starting else { return }
        isCaptureInFlight = false
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
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
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
        guard !isCaptureInFlight else { return }
        holdTask?.cancel()
        holdTask = nil
        isCaptureInFlight = true
        state = .capturing
        consecutiveCenteredFrames = 0
        isCenteredEnoughForCapture = false

        scheduleCaptureTimeout()
        capturePhoto()
    }

    private func scheduleCaptureTimeout() {
        cancelCaptureTimeout()
        captureTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.state == .capturing, self.isCaptureInFlight else { return }
            self.isCaptureInFlight = false
            self.onError?("Capture timed out. Point again and tap the shutter.")
            await self.stopAndWait()
        }
    }

    nonisolated private func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        let output = self.photoOutput
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                DispatchQueue.main.async {
                    Task { @MainActor in
                        self.isCaptureInFlight = false
                        self.cancelCaptureTimeout()
                        self.onError?("Camera was not ready. Try capturing again.")
                        self.state = .idle
                    }
                }
                return
            }
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func applyReading(_ reading: ObjectBoxReading) {
        guard state == .aligning || state == .holding else { return }

        centeringDistance = reading.distance
        subjectOffsetX = reading.offsetX
        subjectOffsetY = reading.offsetY
        hasSubject = reading.hasSubject
        subjectBox = reading.subjectBox
        subjectLabel = reading.label

        let isCentered = reading.isCentered

        if state == .aligning {
            if isCentered {
                consecutiveCenteredFrames += 1
                isCenteredEnoughForCapture = consecutiveCenteredFrames >= framesNeededForHolding
                if isCenteredEnoughForCapture && isAutoCaptureEnabled {
                    beginHolding()
                }
            } else {
                consecutiveCenteredFrames = max(0, consecutiveCenteredFrames - 1)
                isCenteredEnoughForCapture = false
            }
        } else if state == .holding {
            if !isCentered {
                cancelHold()
                consecutiveCenteredFrames = 0
                isCenteredEnoughForCapture = false
            }
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastFrameAnalysisDate) >= minimumAnalysisInterval else { return }
        lastFrameAnalysisDate = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let reading = objectDetector.reading(for: pixelBuffer, orientation: .right)

        readingLock.lock()
        pendingReading = reading
        let shouldSchedule = !isMainUpdateScheduled
        if shouldSchedule {
            isMainUpdateScheduled = true
        }
        readingLock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.flushPendingReading()
        }
    }
}

extension CameraController {
    @MainActor
    fileprivate func flushPendingReading() {
        readingLock.lock()
        let latest = pendingReading ?? .empty
        pendingReading = nil
        isMainUpdateScheduled = false
        readingLock.unlock()
        applyReading(latest)
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
                self.cancelCaptureTimeout()
                self.isCaptureInFlight = false
                self.onError?(error.localizedDescription)
                await self.stopAndWait()
            }
            return
        }

        guard
            let data = photo.fileDataRepresentation(),
            let image = UIImage(data: data)
        else {
            Task { @MainActor in
                self.cancelCaptureTimeout()
                self.isCaptureInFlight = false
                self.onError?("Could not read the captured photo.")
                await self.stopAndWait()
            }
            return
        }

        Task { @MainActor in
            self.cancelCaptureTimeout()
            self.isCaptureInFlight = false
            // Snapshot the aiming box before processing clears framing state.
            let focusBox = self.subjectBox
            self.enterProcessing()
            self.onPhotoCaptured?(image, focusBox)
        }
    }
}
