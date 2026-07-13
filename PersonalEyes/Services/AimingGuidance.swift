import Foundation

/// Throttled directional aiming cues inspired by Vazquez & Steinfeld
/// (ASSETS/TOCHI assisted photography) and AIDEN-style Geiger guidance:
/// speak left/right/up/down toward the subject, and announce when centered.
@MainActor
final class AimingGuidance {
    enum Direction: Equatable {
        case searching
        case left
        case right
        case up
        case down
        case centered

        var spokenCue: String {
            switch self {
            case .searching: return "Scanning. Move slowly."
            case .left: return "Left"
            case .right: return "Right"
            case .up: return "Up"
            case .down: return "Down"
            case .centered: return "Object centered. Tap shutter."
            }
        }

        var statusPhrase: String {
            switch self {
            case .searching: return "Looking for an object box"
            case .left: return "Point left"
            case .right: return "Point right"
            case .up: return "Point up"
            case .down: return "Point down"
            case .centered: return "Object box centered"
            }
        }
    }

    /// Minimum time between spoken direction cues so speech stays usable.
    var speechInterval: TimeInterval = 1.15
    /// How far from center (normalized) before issuing a direction cue.
    var directionDeadZone: Float = 0.10

    private var lastSpokenDirection: Direction?
    private var lastSpokenAt: Date = .distantPast
    private var lastHapticCenteredAt: Date = .distantPast

    func direction(
        hasSubject: Bool,
        offsetX: Float,
        offsetY: Float,
        distance: Float,
        centeredThreshold: Float
    ) -> Direction {
        guard hasSubject else { return .searching }
        if distance < centeredThreshold {
            return .centered
        }

        let ax = abs(offsetX)
        let ay = abs(offsetY)
        if ax < directionDeadZone && ay < directionDeadZone {
            return .centered
        }

        // Vision coordinates: +x right, +y up. Cue tells the user which way
        // to point so the subject moves toward frame center.
        if ax >= ay {
            return offsetX < 0 ? .left : .right
        }
        return offsetY < 0 ? .down : .up
    }

    /// Returns a spoken cue when enough time has passed and the direction changed
    /// or needs reinforcing. Returns nil when silent.
    func spokenCueIfNeeded(for direction: Direction, speechEnabled: Bool) -> String? {
        guard speechEnabled else { return nil }
        let now = Date()
        let changed = direction != lastSpokenDirection
        let elapsed = now.timeIntervalSince(lastSpokenAt)
        let interval = direction == .searching ? speechInterval * 2.2 : speechInterval
        guard changed || elapsed >= interval else { return nil }

        // Don't re-announce "Centered" every interval — only on transition.
        if direction == .centered, !changed {
            return nil
        }

        lastSpokenDirection = direction
        lastSpokenAt = now
        return direction.spokenCue
    }

    func shouldPlayCenterHaptic(for direction: Direction) -> Bool {
        guard direction == .centered else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastHapticCenteredAt) > 0.8 else { return false }
        lastHapticCenteredAt = now
        return true
    }

    func reset() {
        lastSpokenDirection = nil
        lastSpokenAt = .distantPast
        lastHapticCenteredAt = .distantPast
    }
}
