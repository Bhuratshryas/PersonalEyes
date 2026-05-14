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

    private var consecutiveCenteredFrames = 0
    private var lastAnalysisDate: Date = .distantPast
    private let minimumAnalysisInterval: TimeInterval = 0.10
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
        if state != .unauthorized {
            state = .idle
        }
    }

    func resumeAligning() {
        cancelHold()
        consecutiveCenteredFrames = 0
        isCenteredEnoughForCapture = false
        startSession()
        state = .aligning
    }

    func enterShowingResult() {
        // The camera session is paused while the user reads or listens to the
        // result. ``resumeAligning()`` will restart it on dismiss.
        cancelHold()
        stopSession()
        consecutiveCenteredFrames = 0
        isCenteredEnoughForCapture = false
        state = .showingResult
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
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.configureSession()
                self.session.startRunning()
                continuation.resume()
            }
        }
        state = .aligning
    }

    nonisolated private func startSession() {
        let session = self.session
        sessionQueue.async {
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    nonisolated private func stopSession() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    nonisolated private func configureSession() {
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
                    self?.state = .unauthorized
                }
            }
            return
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
            if let connection = videoOutput.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
        }

        if let photoConnection = photoOutput.connection(with: .video),
           photoConnection.isVideoRotationAngleSupported(90) {
            photoConnection.videoRotationAngle = 90
        }

        session.commitConfiguration()
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
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let now = Date()
        let reading = centeringDetector.reading(for: pixelBuffer, orientation: .up)

        Task { @MainActor in
            // Centering is only meaningful while the user is actively framing.
            // During a hold, the lock is enforced by the holdTask itself.
            guard self.state == .aligning || self.state == .holding else { return }
            guard now.timeIntervalSince(self.lastAnalysisDate) >= self.minimumAnalysisInterval else { return }
            self.lastAnalysisDate = now

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
            self.state = .processing
            self.onPhotoCaptured?(image)
        }
    }
}
