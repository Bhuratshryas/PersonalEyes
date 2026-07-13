import AVFoundation
import UIKit

/// Speaks aiming cues and result answers. Prepares the audio session before
/// each utterance so BeepEngine cycles cannot leave TTS unable to speak.
@MainActor
final class SpeechAnnouncer: NSObject, ObservableObject {
    enum Style {
        /// Short aiming cues — calm but brief.
        case cue
        /// Full answers — slower and softer for listening comfort.
        case answer
    }

    @Published private(set) var isSpeaking: Bool = false

    /// When true, aiming cues are ignored so a result answer can finish.
    private(set) var isHoldingForAnswer = false

    private var synthesizer = AVSpeechSynthesizer()
    private var utteranceCount = 0
    private var speakWatchdog: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, style: Style = .answer) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if style == .cue, isHoldingForAnswer {
            return
        }

        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: trimmed)
            return
        }

        prepareAudioSessionForSpeech()
        refreshSynthesizerIfNeeded()

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        if style == .answer {
            isHoldingForAnswer = true
        }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = preferredVoice()
        switch style {
        case .cue:
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
            utterance.pitchMultiplier = 0.96
            utterance.preUtteranceDelay = 0.02
            utterance.postUtteranceDelay = 0.05
            utterance.volume = 0.85
        case .answer:
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.80
            utterance.pitchMultiplier = 0.92
            utterance.preUtteranceDelay = 0.15
            utterance.postUtteranceDelay = 0.18
            utterance.volume = 1.0
        }
        utterance.prefersAssistiveTechnologySettings = true
        synthesizer.speak(utterance)
        isSpeaking = true
        utteranceCount += 1
        scheduleSpeakWatchdog(for: style)
    }

    func stop() {
        speakWatchdog?.cancel()
        speakWatchdog = nil
        isHoldingForAnswer = false
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        // Recreate every stop so TTS cannot wedge after several captures.
        recreateSynthesizer()
    }

    /// Call when returning to aiming so a stuck answer hold cannot block cues.
    func resetForNextCapture() {
        stop()
    }

    /// Clears the answer hold without interrupting current speech.
    func releaseAnswerHold() {
        isHoldingForAnswer = false
    }

    private func prepareAudioSessionForSpeech() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try session.setActive(true, options: [])
        } catch {
            // Best-effort — still attempt to speak.
        }
    }

    /// AVSpeechSynthesizer can wedge after many start/stop cycles; recreate it.
    private func refreshSynthesizerIfNeeded() {
        guard utteranceCount > 0, utteranceCount % 4 == 0, !synthesizer.isSpeaking else { return }
        recreateSynthesizer()
    }

    private func recreateSynthesizer() {
        synthesizer.delegate = nil
        let replacement = AVSpeechSynthesizer()
        replacement.delegate = self
        synthesizer = replacement
    }

    private func scheduleSpeakWatchdog(for style: Style) {
        speakWatchdog?.cancel()
        let limitNs: UInt64 = style == .answer ? 60_000_000_000 : 12_000_000_000
        speakWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: limitNs)
            guard let self, !Task.isCancelled else { return }
            guard self.isSpeaking || self.isHoldingForAnswer else { return }
            self.recreateSynthesizer()
            self.isSpeaking = false
            self.isHoldingForAnswer = false
        }
    }

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let localeID = Locale.current.identifier
        let lang = String(localeID.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        if let premium = voices.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = voices.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: localeID)
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

extension SpeechAnnouncer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            isSpeaking = true
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            speakWatchdog?.cancel()
            speakWatchdog = nil
            isSpeaking = false
            isHoldingForAnswer = false
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            speakWatchdog?.cancel()
            speakWatchdog = nil
            isSpeaking = false
            isHoldingForAnswer = false
        }
    }
}
