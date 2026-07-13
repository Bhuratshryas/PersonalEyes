import Foundation

/// User-tunable behavior for the capture and summary pipeline.
///
/// Defaults favor clear spoken descriptions, directional aiming cues (a core
/// purpose of the app), and manual shutter control until auto-capture is enabled.
struct AnalysisPreferences: Equatable, Codable {
    /// When `true`, write a longer 1 to 2 sentence description. Otherwise the
    /// summary defaults to a 3-word reply for any object in view.
    var detailedDescription = true

    /// Read useful visible text when it is actually present (signs, labels,
    /// packaging). If no readable text is found, the spoken answer only
    /// describes the scene and objects.
    var includeVisibleText = true

    /// Auto-capture the photo when an object is detected near the center.
    /// When off, the user presses the round shutter button instead.
    var autoCaptureEnabled = false

    /// Centering Geiger beep, stereo pan, hold cue, capture chime, processing tone.
    /// On by default so aiming feedback works without opening Options first.
    var soundEffectsEnabled = true

    /// Spoken left/right/up/down / centered cues while aiming.
    var directionalGuidanceEnabled = true

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

    private let storageKey = "PersonalEyes.analysisPreferences.v2"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(AnalysisPreferences.self, from: data) {
            preferences = decoded
        } else if let legacy = defaults.data(forKey: "PersonalEyes.analysisPreferences.v1"),
                  let decoded = try? JSONDecoder().decode(LegacyPreferences.self, from: legacy) {
            preferences = AnalysisPreferences(
                detailedDescription: decoded.detailedDescription,
                includeVisibleText: decoded.includeVisibleText,
                autoCaptureEnabled: decoded.autoCaptureEnabled,
                soundEffectsEnabled: decoded.soundEffectsEnabled,
                directionalGuidanceEnabled: true,
                spokenSummaryEnabled: decoded.spokenSummaryEnabled
            )
        } else {
            preferences = AnalysisPreferences()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private struct LegacyPreferences: Codable {
    var detailedDescription = true
    var includeVisibleText = true
    var autoCaptureEnabled = false
    var soundEffectsEnabled = false
    var spokenSummaryEnabled = true
}
