import Foundation

struct ImageAnalysisResult: Equatable, Identifiable {
    var id = UUID()
    var objectName: String?
    var confidence: Float?
    var visibleText: [String]
    var brandOrLabel: String?
    var freshnessSummary: String?
    var recipeIdea: String?
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

        if let brandOrLabel {
            parts.append("Label or brand text: \(brandOrLabel).")
        }

        if !visibleText.isEmpty {
            parts.append("Visible text includes \(visibleText.prefix(3).joined(separator: ", ")).")
        }

        if let freshnessSummary {
            parts.append(freshnessSummary)
        }

        if let recipeIdea {
            parts.append("Recipe idea: \(recipeIdea).")
        }

        return parts.joined(separator: " ")
    }

    static let empty = ImageAnalysisResult(
        objectName: nil,
        confidence: nil,
        visibleText: [],
        brandOrLabel: nil,
        freshnessSummary: nil,
        recipeIdea: nil,
        timestamp: Date()
    )
}
