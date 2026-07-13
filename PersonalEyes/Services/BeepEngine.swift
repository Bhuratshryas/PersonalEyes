import AVFoundation
import Foundation

/// Synthesizes the audible feedback used while the user is aiming the camera
/// and while the captured image is being processed. All tones are generated
/// procedurally so the app does not ship audio assets.
@MainActor
final class BeepEngine: ObservableObject {
    @Published var isMuted: Bool = false {
        didSet {
            guard oldValue != isMuted else { return }
            if isMuted {
                stopCenteringBeep()
                stopProcessingTone()
            }
        }
    }

    /// Set when audio engine startup fails so the UI can announce it once.
    @Published private(set) var startErrorMessage: String?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var beepTimer: Timer?
    private var processingTimer: Timer?
    private var processingStep: Int = 0
    private var isStarted = false

    init() {
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() {
        guard !isStarted else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .duckOthers]
            )
            try session.setActive(true, options: [])
            try engine.start()
            player.play()
            isStarted = true
            startErrorMessage = nil
        } catch {
            isStarted = false
            startErrorMessage = "Sound effects could not start. Spoken summaries may still work."
        }
    }

    func clearStartError() {
        startErrorMessage = nil
    }

    func stop() {
        beepTimer?.invalidate()
        beepTimer = nil
        processingTimer?.invalidate()
        processingTimer = nil
        if isStarted {
            player.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        isStarted = false
    }

    /// Updates the beep cadence based on how far the salient subject is from
    /// the frame center. `distance` is 0 when centered and 1 when at the edge.
    func updateCenteringBeep(distance: Float) {
        guard isStarted, !isMuted else {
            beepTimer?.invalidate()
            beepTimer = nil
            return
        }
        beepTimer?.invalidate()

        let clamped = max(0, min(1, distance))
        let frequency: Double = 660 + (1.0 - Double(clamped)) * 660
        let interval: TimeInterval = 0.10 + Double(clamped) * 0.55

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleTone(frequency: frequency, duration: 0.06, gain: 0.18)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        beepTimer = timer
        scheduleTone(frequency: frequency, duration: 0.06, gain: 0.18)
    }

    func stopCenteringBeep() {
        beepTimer?.invalidate()
        beepTimer = nil
    }

    /// A two-note rising chime that signals a successful auto-capture.
    func playConfirmation() {
        guard !isMuted else { return }
        beepTimer?.invalidate()
        beepTimer = nil
        scheduleTone(frequency: 1320, duration: 0.12, gain: 0.22)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            Task { @MainActor in
                self?.scheduleTone(frequency: 1760, duration: 0.18, gain: 0.22)
            }
        }
    }

    /// A "hold steady" cue: three sharp same-pitch pulses spaced over the
    /// hold window so the user knows to stop moving while the camera waits.
    func playHoldCue() {
        guard !isMuted else { return }
        beepTimer?.invalidate()
        beepTimer = nil
        let frequency: Double = 1100
        let duration: TimeInterval = 0.08
        let gain: Float = 0.26
        scheduleTone(frequency: frequency, duration: duration, gain: gain)
        for offset in [0.30, 0.60] {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak self] in
                Task { @MainActor in
                    self?.scheduleTone(frequency: frequency, duration: duration, gain: gain)
                }
            }
        }
    }

    /// Soft pulsing tone the user hears while analysis is in progress.
    func startProcessingTone() {
        guard isStarted, !isMuted else { return }
        processingTimer?.invalidate()
        processingStep = 0
        let timer = Timer(timeInterval: 0.42, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let frequencies: [Double] = [523, 659, 784, 659]
                let frequency = frequencies[self.processingStep % frequencies.count]
                self.scheduleTone(frequency: frequency, duration: 0.12, gain: 0.10)
                self.processingStep += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        processingTimer = timer
    }

    func stopProcessingTone() {
        processingTimer?.invalidate()
        processingTimer = nil
    }

    private func scheduleTone(frequency: Double, duration: TimeInterval, gain: Float) {
        guard isStarted, !isMuted else { return }

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        buffer.frameLength = frameCount

        let channelCount = Int(format.channelCount)
        let twoPi = 2.0 * Double.pi
        let attack: Double = 0.005
        let release: Double = 0.04

        for ch in 0..<channelCount {
            guard let data = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<Int(frameCount) {
                let t = Double(i) / sampleRate
                var envelope = 1.0
                if t < attack {
                    envelope = t / attack
                }
                let timeFromEnd = duration - t
                if timeFromEnd < release {
                    envelope *= max(0, timeFromEnd / release)
                }
                let value = sin(twoPi * frequency * t) * envelope * Double(gain)
                data[i] = Float(value)
            }
        }

        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }
}
