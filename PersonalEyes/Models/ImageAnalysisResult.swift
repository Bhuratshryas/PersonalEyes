import Foundation

struct ImageAnalysisResult: Equatable, Identifiable {
    var id = UUID()
    var objectName: String?
    var confidence: Float?
    var visibleText: [String]
    var aiSummary: String?
    var usedAppleIntelligence: Bool = false
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

        if let objectName {
            parts.append("I see \(objectName).")
        } else {
            parts.append("I could not confidently identify the main object.")
        }

        if !visibleText.isEmpty {
            parts.append("Visible text includes \(visibleText.prefix(3).joined(separator: ", ")).")
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
