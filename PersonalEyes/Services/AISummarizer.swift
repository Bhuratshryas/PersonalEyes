import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
/// Guided generation: describe what the photo shows (people, objects, scene).
@available(iOS 26.0, *)
@Generable(description: "A spoken description of what a photo shows for a blind or low-vision listener.")
struct SpokenSceneDescription {
    @Guide(description: "The main subject of the photo as a short phrase — a person, people, an object, an animal, or the overall scene (for example: a person smiling, coffee mug, two dogs, city street at dusk).")
    var mainSubject: String

    @Guide(description: "One or two short sentences describing what the image shows: people, objects, setting, and notable details. Use only facts supported by Vision evidence. Do not invent faces, ages, or emotions beyond what evidence supports. Statements only. Never ask questions. Do not repeat yourself. Mention readable text only when it is listed in the evidence and useful — if no text is listed, do not talk about text.")
    var narration: String
}
#endif

/// Produces a spoken description of the captured image using Apple Intelligence
/// when available.
///
/// Harness design (context + validation, not prompt-only):
/// 1. Ground on Vision evidence (labels, people, animals, optional OCR).
/// 2. Describe whatever the photo shows — people, objects, or scene.
/// 3. Prefer guided generation with a clear subject + narration.
/// 4. Validate output; repair once if needed; otherwise fall back.
struct AISummarizer {
    /// Status copy while the answer is being prepared (not a question to the user).
    static let processingStatus = "Reading the photo"

    struct Input {
        var image: UIImage?
        var visibleText: [String]
        /// Best guess for the primary subject (person, object, animal, or scene).
        var classification: String?
        var classificationConfidence: Float? = nil
        var allLabels: [String] = []
        var peopleCount: Int = 0
        var preferences: AnalysisPreferences
        var customQuestions: [String] = []
    }

    struct Output {
        var summary: String
        var usedAppleIntelligence: Bool
        var availabilityNote: String?
    }

    func summarize(_ input: Input) async -> Output {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                if let summary = await runAppleIntelligence(input: input) {
                    return Output(
                        summary: summary,
                        usedAppleIntelligence: true,
                        availabilityNote: nil
                    )
                }
                return Output(
                    summary: fallbackSummary(input: input),
                    usedAppleIntelligence: false,
                    availabilityNote: "Apple Intelligence did not return a usable description, so Personal Eyes used on-device Vision instead."
                )
            case .unavailable(let reason):
                return Output(
                    summary: fallbackSummary(input: input),
                    usedAppleIntelligence: false,
                    availabilityNote: availabilityMessage(for: reason)
                )
            }
        }
        #endif
        return Output(
            summary: fallbackSummary(input: input),
            usedAppleIntelligence: false,
            availabilityNote: "Apple Intelligence requires iOS 26 or later with Apple Intelligence turned on."
        )
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func runAppleIntelligence(input: Input) async -> String? {
        do {
            return try await withThrowingTimeout(seconds: 18) {
                try await self.runAppleIntelligenceBody(input: input)
            }
        } catch {
            return nil
        }
    }

    @available(iOS 26.0, *)
    private func runAppleIntelligenceBody(input: Input) async throws -> String? {
        try Task.checkCancellation()
        let session = LanguageModelSession(
            instructions: instructions(for: input)
        )
        var options = GenerationOptions()
        options.temperature = 0.15
        options.sampling = .greedy

        let first = try await generateDescription(
            session: session,
            input: input,
            options: options,
            repairContext: nil
        )
        try Task.checkCancellation()
        if let accepted = acceptIfValid(first, input: input) {
            return accepted
        }

        let repaired = try await generateDescription(
            session: session,
            input: input,
            options: options,
            repairContext: first
        )
        try Task.checkCancellation()
        return acceptIfValid(repaired, input: input)
    }

    private struct TimeoutError: Error {}

    private func withThrowingTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    @available(iOS 26.0, *)
    private func generateDescription(
        session: LanguageModelSession,
        input: Input,
        options: GenerationOptions,
        repairContext: String?
    ) async throws -> String {
        let promptText = prompt(from: input, repairContext: repairContext)

        if input.preferences.detailedDescription {
            let response = try await session.respond(
                to: promptText,
                generating: SpokenSceneDescription.self,
                options: options
            )
            let content = response.content
            return Self.composeSpokenAnswer(
                mainSubject: content.mainSubject,
                narration: content.narration,
                fallbackSubject: input.classification
            )
        } else {
            let response = try await session.respond(
                to: promptText,
                options: options
            )
            return response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func composeSpokenAnswer(
        mainSubject: String,
        narration: String,
        fallbackSubject: String?
    ) -> String {
        let spoken = narration.trimmingCharacters(in: .whitespacesAndNewlines)
        if !spoken.isEmpty {
            return spoken
        }

        let subject = humanizeName(mainSubject.isEmpty ? (fallbackSubject ?? "") : mainSubject)
        guard !subject.isEmpty else { return "" }
        return "The photo shows \(subject)."
    }

    static func humanizeName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func indefiniteArticle(for noun: String) -> String {
        guard let first = noun.lowercased().unicodeScalars.first else { return "a" }
        return "aeiou".unicodeScalars.contains(first) ? "an" : "a"
    }

    @available(iOS 26.0, *)
    private func acceptIfValid(_ raw: String, input: Input) -> String? {
        let cleaned = Self.sanitize(raw)
        guard !cleaned.isEmpty else { return nil }
        guard !Self.looksLikeUserFacingQuestion(cleaned) else { return nil }

        if !input.preferences.detailedDescription {
            let words = cleaned.split(whereSeparator: \.isWhitespace)
            if words.count > 6 { return words.prefix(3).joined(separator: " ") }
        }
        return cleaned
    }

    @available(iOS 26.0, *)
    private func availabilityMessage(
        for reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device does not support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to get richer spoken answers."
        case .modelNotReady:
            return "Apple Intelligence is still downloading. Try again in a moment."
        @unknown default:
            return "Apple Intelligence is unavailable right now."
        }
    }
    #endif

    private func instructions(for input: Input) -> String {
        var lines: [String] = []
        lines.append("You are Personal Eyes, an on-device visual assistant for blind and low-vision users.")
        lines.append("Your job is to describe what the photo shows — people, objects, animals, and the setting — so the listener understands the image.")
        lines.append("Ground every claim in the Vision evidence below. Do not invent people, objects, text, colors, or details that the evidence does not support.")
        lines.append("Write for listening: short, clear, natural sentences. No greetings, no markdown, no bullet lists, no numbered labels.")
        lines.append("Describe the image. If there are people, say so. If there is a clear main object, name it. If it is a broader scene, describe the scene.")
        lines.append("CRITICAL: You describe. The user does not. Never ask the user any question. Never say \"Tell me what you see\", \"What do you see\", \"What else would you like to know\", or similar.")
        lines.append("Say the description exactly once. Do not repeat paragraphs.")

        if input.preferences.detailedDescription {
            lines.append("Fill mainSubject with the main subject, and narration with 1 to 2 short sentences describing the image.")
        } else {
            lines.append("Output exactly 3 words naming the main subject. No punctuation. No questions.")
        }

        if input.peopleCount > 0 {
            lines.append("People were detected. Include them in the description.")
        }

        let hasUsefulText = Self.hasUsefulVisibleText(input.visibleText)
        if input.preferences.includeVisibleText, hasUsefulText {
            lines.append("Useful readable text was found. Mention only the most important words after describing what is in the image.")
        } else {
            lines.append("No useful readable text was found. Describe the image and what it contains. Do not mention text, OCR, signs, or say that no text was found.")
        }

        let extra = Self.normalizedQuestions(input.customQuestions)
        if !extra.isEmpty {
            lines.append("After the description, briefly answer each listed user question in natural sentences. Still never ask questions of your own. If unclear from the evidence, say that plainly.")
        }

        return lines.joined(separator: " ")
    }

    private func prompt(from input: Input, repairContext: String?) -> String {
        var lines: [String] = []

        if repairContext != nil {
            lines.append("Your previous reply was invalid (it asked a question or repeated itself).")
            lines.append("Describe what the photo shows in one or two sentences. Say it once. No questions.")
            lines.append("")
        }

        lines.append("Task: Describe this photo for a blind listener.")
        lines.append("Say what is in the image — people, objects, animals, and setting as supported by the evidence.")
        lines.append("Do not ask the listener anything.")
        lines.append("")
        lines.append("Vision evidence from the captured photo (use as grounding):")

        if input.peopleCount == 1 {
            lines.append("- People detected: 1 person")
        } else if input.peopleCount > 1 {
            lines.append("- People detected: \(input.peopleCount) people")
        } else {
            lines.append("- People detected: none")
        }

        if let classification = input.classification, !classification.isEmpty {
            let confidence = input.classificationConfidence.map { String(format: "%.0f%%", Double($0) * 100) }
            if let confidence {
                lines.append("- Primary subject: \(classification) (\(confidence) confidence)")
            } else {
                lines.append("- Primary subject: \(classification)")
            }
        } else {
            lines.append("- Primary subject: unclear")
        }

        let labels = input.allLabels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !labels.isEmpty {
            lines.append("- Supporting labels: \(labels.prefix(8).joined(separator: ", "))")
        }

        if input.preferences.includeVisibleText, Self.hasUsefulVisibleText(input.visibleText) {
            let text = input.visibleText
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { Self.isUsefulTextLine($0) }
            lines.append("- Readable text found (optional detail):")
            for row in text.prefix(20) {
                lines.append("  • \(row)")
            }
        }

        let extra = Self.normalizedQuestions(input.customQuestions)
        if !extra.isEmpty {
            lines.append("")
            lines.append("Also answer these user questions after the description (answers only):")
            for question in extra {
                lines.append("- \(question)")
            }
        }

        lines.append("")
        lines.append("Now write the spoken description of the image once.")
        return lines.joined(separator: "\n")
    }

    private func fallbackSummary(input: Input) -> String {
        var parts: [String] = []

        if input.peopleCount == 1 {
            parts.append("The photo shows a person.")
        } else if input.peopleCount > 1 {
            parts.append("The photo shows \(input.peopleCount) people.")
        }

        if let classification = input.classification, !classification.isEmpty {
            let subject = Self.humanizeName(classification)
            if input.preferences.detailedDescription {
                if parts.isEmpty {
                    let article = Self.indefiniteArticle(for: subject)
                    parts.append("The photo shows \(article) \(subject).")
                } else if !parts[0].lowercased().contains(subject) {
                    parts.append("It also includes \(subject).")
                }
            } else if parts.isEmpty {
                return threeWordPhrase(from: subject)
            }
        } else if parts.isEmpty {
            if input.preferences.detailedDescription {
                parts.append("I could not confidently describe what is in the image.")
            } else {
                return "unclear image"
            }
        }

        if input.preferences.includeVisibleText, Self.hasUsefulVisibleText(input.visibleText) {
            let highlights = input.visibleText
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { Self.isUsefulTextLine($0) }
                .prefix(3)
                .joined(separator: ", ")
            if !highlights.isEmpty, input.preferences.detailedDescription {
                parts.append("Visible text includes: \(highlights).")
            }
        }

        return parts.joined(separator: " ")
    }

    private func threeWordPhrase(from classification: String) -> String {
        let words = classification
            .split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }
        if words.isEmpty { return "unclear scene" }
        return words.prefix(3).joined(separator: " ").lowercased()
    }

    private static func normalizedQuestions(_ questions: [String]) -> [String] {
        questions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func hasUsefulVisibleText(_ lines: [String]) -> Bool {
        lines.contains { isUsefulTextLine($0) }
    }

    static func isUsefulTextLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letters >= 2
    }

    static func looksLikeUserFacingQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let lower = trimmed.lowercased()
        let bannedPhrases = [
            "tell me what you see",
            "what do you see",
            "describe what you see",
            "what else would you like",
            "would you like to know",
            "is there anything else you",
            "what can you tell me",
            "can you see",
            "what are you looking at"
        ]
        if bannedPhrases.contains(where: { lower.contains($0) }) {
            return true
        }

        if trimmed.hasSuffix("?") {
            let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
            if wordCount <= 12 { return true }
            if lower.hasPrefix("what ") || lower.hasPrefix("tell ") || lower.hasPrefix("can you ") {
                return true
            }
        }
        return false
    }

    static func sanitize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let leakPatterns = [
            #"(?i)\bTell me what you see\b[.?!]?"#,
            #"(?i)\bWhat do you see\b\??"#,
            #"(?i)\bDescribe what you see\b[.?!]?"#,
            #"(?i)\bWhat else would you like to know(?: about this image)?\b\??"#,
            #"(?i)\bWould you like to know(?: anything else)?(?: about this image)?\b\??"#,
            #"(?i)\bIs there anything else you(?:'d| would) like to know(?: about this image)?\b\??"#,
            #"(?i)\bLet me know if you(?:'d| would) like to know more\b\.?"#,
            #"(?i)\bDo you want(?: me)? to (?:tell|say) more\b\??"#
        ]
        for pattern in leakPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            }
        }

        result = deduplicateRepeatedContent(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deduplicateRepeatedContent(_ text: String) -> String {
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var kept: [String] = []
        for paragraph in paragraphs {
            if kept.contains(where: { normalizedForCompare($0) == normalizedForCompare(paragraph) }) {
                continue
            }
            kept.append(paragraph)
        }

        var joined = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if let single = firstCopyIfWholeTextDuplicated(joined) {
            joined = single
        }
        return joined
    }

    private static func normalizedForCompare(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func firstCopyIfWholeTextDuplicated(_ text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 16 else { return nil }

        let mid = words.count / 2
        for split in [mid, mid - 1, mid + 1, mid - 2, mid + 2] where split > 6 && split < words.count - 6 {
            let first = words[..<split].joined(separator: " ")
            let second = words[split...].joined(separator: " ")
            if normalizedForCompare(first) == normalizedForCompare(second) {
                return first
            }
        }
        return nil
    }
}
