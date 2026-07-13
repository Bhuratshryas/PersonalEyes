import Foundation

struct ImageAnalysisResult: Equatable, Identifiable {
    var id = UUID()
    var objectName: String?
    var confidence: Float?
    var labels: [String] = []
    var peopleCount: Int = 0
    var visibleText: [String]
    var aiSummary: String?
    var usedAppleIntelligence: Bool = false
    var availabilityNote: String?
    var timestamp: Date

    /// Highest priority text used for spoken playback. Falls back from the
    /// Apple Intelligence summary down to a structured local description.
    var spokenSummary: String {
        if let aiSummary, !aiSummary.isEmpty {
            return aiSummary
        }
        return localSummary
    }

    var localSummary: String {
        var parts: [String] = []

        if peopleCount == 1 {
            parts.append("The photo shows a person.")
        } else if peopleCount > 1 {
            parts.append("The photo shows \(peopleCount) people.")
        }

        if let objectName {
            let name = objectName.replacingOccurrences(of: "_", with: " ").lowercased()
            let mentionsPeople = name.contains("person") || name.contains("people")
            if !(peopleCount > 0 && mentionsPeople) {
                let article: String = {
                    guard let first = name.unicodeScalars.first else { return "a" }
                    return "aeiou".unicodeScalars.contains(first) ? "an" : "a"
                }()
                if parts.isEmpty {
                    parts.append("The photo shows \(article) \(name).")
                } else {
                    parts.append("It also includes \(name).")
                }
            }
        } else if parts.isEmpty {
            parts.append("I could not confidently describe what is in the image.")
        }

        if !visibleText.isEmpty {
            let useful = visibleText
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
                .prefix(3)
            if !useful.isEmpty {
                parts.append("Visible text includes \(useful.joined(separator: ", ")).")
            }
        }

        return parts.joined(separator: " ")
    }

    static let empty = ImageAnalysisResult(
        objectName: nil,
        confidence: nil,
        visibleText: [],
        timestamp: Date()
    )
}
