import Foundation

/// User-tunable behavior for the capture and summary pipeline.
///
/// Personal Eyes is a general-purpose visual assistant. Defaults favor clear
/// spoken descriptions, optional audio cues, and manual shutter control until
/// the user enables auto-capture.
struct AnalysisPreferences: Equatable, Codable {
    /// When `true`, write a longer 1 to 2 sentence description. Otherwise the
    /// summary defaults to a 3-word reply for any object in view.
    var detailedDescription = true

    /// Read short visible text from the image (signs, labels, packaging) into
    /// the spoken summary. Helpful for menus, package labels, and signage.
    var includeVisibleText = true

    /// Auto-capture the photo when an object is detected near the center.
    /// When off, the user presses the round shutter button instead.
    var autoCaptureEnabled = false

    /// Centering beep, hold cue, capture chime, and processing tone.
    var soundEffectsEnabled = false

    /// Spoken summary playback (text to speech) after each capture.
    /// Independent from the system VoiceOver screen reader.
    var spokenSummaryEnabled = true
}

/// Persists ``AnalysisPreferences`` across launches.
@MainActor
final class PreferenceStore: ObservableObject {
    @Published var preferences: AnalysisPreferences {
        didSet { persist() }
    }

    private let storageKey = "PersonalEyes.analysisPreferences.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(AnalysisPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = AnalysisPreferences()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
