import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Produces a clear, accurate, spoken-style summary of a captured image using
/// the on-device Apple Intelligence Foundation Models when available, falling
/// back to a deterministic summary otherwise. The OCR pass is treated as the
/// primary source of text truth, augmented with a high-level visual
/// classification.
struct AISummarizer {
    struct Input {
        var visibleText: [String]
        var classification: String?
        var preferences: AnalysisPreferences
        var customQuestions: [String] = []
    }

    struct Output {
        var summary: String
        var usedAppleIntelligence: Bool
    }

    func summarize(_ input: Input) async -> Output {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let summary = await runAppleIntelligence(input: input) {
                return Output(summary: summary, usedAppleIntelligence: true)
            }
        }
        #endif
        return Output(summary: fallbackSummary(input: input), usedAppleIntelligence: false)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func runAppleIntelligence(input: Input) async -> String? {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            return nil
        }

        do {
            let session = LanguageModelSession(instructions: instructions(for: input))
            let response = try await session.respond(to: prompt(from: input))
            let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }
    #endif

    private func instructions(for input: Input) -> String {
        let cleanedQuestions = input.customQuestions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var lines: [String] = []
        lines.append("You are a visual assistant for a blind or low-vision user. They captured a photo.")
        lines.append("Be concise, accurate, and natural. Never invent details that are not supported by the input. Never start with greetings or meta phrases.")

        if input.preferences.detailedDescription {
            lines.append("Write a description in 1 to 2 short sentences.")
            if input.preferences.includeVisibleText {
                lines.append("Include the most useful visible text from the image, such as brand names, prices, instructions, dates, signs, or warnings, when present.")
            }
        } else {
            lines.append("Reply with exactly 3 words describing the main object or scene. No punctuation, no leading article, no greeting. Example: \"red ceramic mug\".")
            if input.preferences.includeVisibleText {
                lines.append("If readable text is present and important, append it on the next line prefixed with \"Text:\" followed by the text.")
            }
        }

        if !cleanedQuestions.isEmpty {
            lines.append("After the description, answer each user question on its own new line, in order, prefixed with \"Q1:\", \"Q2:\", and so on. Each answer is one short sentence. If the input does not contain enough information, answer \"Unclear from the image\".")
        }

        return lines.joined(separator: " ")
    }

    private func prompt(from input: Input) -> String {
        var lines: [String] = []
        lines.append("Visual classification: \(input.classification ?? "unclear").")

        if input.preferences.includeVisibleText {
            if input.visibleText.isEmpty {
                lines.append("OCR result: no readable text was detected.")
            } else {
                lines.append("OCR text from the image, one line per row:")
                for line in input.visibleText.prefix(60) {
                    let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        lines.append("- \(cleaned)")
                    }
                }
            }
        }

        let cleanedQuestions = input.customQuestions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanedQuestions.isEmpty {
            lines.append("\nUser questions, in order:")
            for (index, question) in cleanedQuestions.enumerated() {
                lines.append("\(index + 1). \(question)")
            }
        }

        lines.append("\nWrite the response now.")
        return lines.joined(separator: "\n")
    }

    private func fallbackSummary(input: Input) -> String {
        var parts: [String] = []

        if let classification = input.classification {
            if input.preferences.detailedDescription {
                parts.append("This appears to be \(classification).")
            } else {
                parts.append(threeWordPhrase(from: classification))
            }
        } else if input.preferences.detailedDescription {
            parts.append("I could not confidently identify the main object.")
        } else {
            parts.append("unclear main object")
        }

        if input.preferences.includeVisibleText, !input.visibleText.isEmpty {
            let highlights = input.visibleText
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(3)
                .joined(separator: ", ")
            if !highlights.isEmpty {
                if input.preferences.detailedDescription {
                    parts.append("Visible text includes: \(highlights).")
                } else {
                    parts.append("Text: \(highlights)")
                }
            }
        }

        let cleanedQuestions = input.customQuestions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanedQuestions.isEmpty {
            parts.append("Custom questions need Apple Intelligence, which is not available right now.")
        }

        return parts.joined(separator: " ")
    }

    /// Keeps the short mode honest when Vision returns a long label string.
    private func threeWordPhrase(from classification: String) -> String {
        let words = classification
            .split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }
        if words.isEmpty { return "unclear object" }
        return words.prefix(3).joined(separator: " ").lowercased()
    }
}
