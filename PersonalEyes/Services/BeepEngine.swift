import AVFoundation
import Foundation

/// Soft aiming tones while framing. Once a photo is captured, call
/// ``silenceAll()`` so speech and Apple Intelligence answers are uninterrupted.
@MainActor
final class BeepEngine: ObservableObject {
    @Published var isMuted: Bool = false {
        didSet {
            guard oldValue != isMuted else { return }
            if isMuted {
                silenceAll()
            }
        }
    }

    @Published private(set) var startErrorMessage: String?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var beepTimer: Timer?
    private var processingTimer: Timer?
    private var isStarted = false
    /// When true, ignore delayed tone callbacks from earlier cues.
    private var isSilenced = false

    init() {
        engine.attach(player)
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() {
        guard !isStarted else {
            isSilenced = false
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.mixWithOthers, .duckOthers]
            )
            try session.setActive(true, options: [])
            try engine.start()
            player.play()
            isStarted = true
            isSilenced = false
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
        silenceAll()
        if isStarted {
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        isStarted = false
    }

    /// Hard stop for all aiming / processing tones. Call as soon as a photo is taken.
    func silenceAll() {
        isSilenced = true
        beepTimer?.invalidate()
        beepTimer = nil
        processingTimer?.invalidate()
        processingTimer = nil
        player.pan = 0
        if isStarted {
            player.stop()
            player.reset()
            player.play()
        }
    }

    /// Soft Geiger-style pulse: lower, warmer, slower than a hard beep.
    func updateCenteringBeep(distance: Float, offsetX: Float = 0, hasSubject: Bool = true) {
        guard isStarted, !isMuted else {
            beepTimer?.invalidate()
            beepTimer = nil
            return
        }
        isSilenced = false
        beepTimer?.invalidate()

        // Gentle stereo lean — keep pan narrow so it stays comfortable.
        player.pan = max(-0.55, min(0.55, offsetX * 1.4))

        let clamped = max(0, min(1, distance))
        let frequency: Double
        let interval: TimeInterval
        let gain: Float

        if !hasSubject {
            frequency = 312
            interval = 1.15
            gain = 0.045
        } else {
            // Warm mid tones; never pierce into high registers.
            frequency = 340 + (1.0 - Double(clamped)) * 220
            interval = 0.22 + Double(clamped) * 0.75
            gain = 0.06
        }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleTone(frequency: frequency, duration: 0.12, gain: gain)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        beepTimer = timer
        scheduleTone(frequency: frequency, duration: 0.12, gain: gain)
    }

    func stopCenteringBeep() {
        beepTimer?.invalidate()
        beepTimer = nil
        player.pan = 0
    }

    /// Soft two-note chime confirming capture, then stays silent.
    func playConfirmation() {
        silenceAll()
        guard isStarted, !isMuted else { return }
        isSilenced = false
        scheduleTone(frequency: 480, duration: 0.16, gain: 0.07)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            Task { @MainActor in
                guard let self, !self.isSilenced, !self.isMuted else { return }
                self.scheduleTone(frequency: 620, duration: 0.22, gain: 0.06)
                // After the soft chime, stay quiet for speech / Intelligence.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    Task { @MainActor in
                        self?.silenceAll()
                    }
                }
            }
        }
    }

    /// Soft triple pulse for hold-still, kept quieter than aiming tones.
    func playHoldCue() {
        guard isStarted, !isMuted else { return }
        isSilenced = false
        beepTimer?.invalidate()
        beepTimer = nil
        player.pan = 0
        let frequency: Double = 440
        let duration: TimeInterval = 0.10
        let gain: Float = 0.08
        scheduleTone(frequency: frequency, duration: duration, gain: gain)
        for offset in [0.32, 0.64] {
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) { [weak self] in
                Task { @MainActor in
                    guard let self, !self.isSilenced, !self.isMuted else { return }
                    self.scheduleTone(frequency: frequency, duration: duration, gain: gain)
                }
            }
        }
    }

    /// Processing tone disabled — keep the line clear for spoken answers.
    func startProcessingTone() {
        silenceAll()
    }

    func stopProcessingTone() {
        processingTimer?.invalidate()
        processingTimer = nil
    }

    private func scheduleTone(frequency: Double, duration: TimeInterval, gain: Float) {
        guard isStarted, !isMuted, !isSilenced else { return }

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return }
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        buffer.frameLength = frameCount

        let channelCount = Int(format.channelCount)
        let twoPi = 2.0 * Double.pi
        // Soft attack/release so tones feel rounded, not clicky.
        let attack: Double = 0.035
        let release: Double = 0.055

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
                // Slight fundamental + quiet octave for a warmer timbre.
                let fundamental = sin(twoPi * frequency * t)
                let warmth = 0.22 * sin(twoPi * frequency * 0.5 * t)
                let value = (fundamental + warmth) * envelope * Double(gain)
                data[i] = Float(value)
            }
        }

        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }
}
