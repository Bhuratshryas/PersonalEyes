import UIKit
import Vision
import ImageIO

enum ImageAnalysisError: LocalizedError {
    case missingImageData

    var errorDescription: String? {
        switch self {
        case .missingImageData:
            "The selected image could not be read."
        }
    }
}

/// Runs Apple Vision classification and OCR on a captured photo and returns
/// the raw findings. The ``AISummarizer`` is responsible for shaping the
/// spoken response from the user's preferences.
struct ImageAnalysisService {
    func analyze(_ image: UIImage, preferences: AnalysisPreferences) async throws -> ImageAnalysisResult {
        guard let cgImage = image.cgImage else {
            throw ImageAnalysisError.missingImageData
        }

        async let classification = classifyImage(cgImage, orientation: image.cgImageOrientation)
        async let text = recognizeText(cgImage, orientation: image.cgImageOrientation)

        let (classificationResult, visibleText) = try await (classification, text)

        return ImageAnalysisResult(
            objectName: classificationResult.label,
            confidence: classificationResult.confidence,
            visibleText: preferences.includeVisibleText ? visibleText : [],
            brandOrLabel: nil,
            freshnessSummary: nil,
            recipeIdea: nil,
            timestamp: Date()
        )
    }

    private func classifyImage(
        _ cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> ClassificationResult {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNClassifyImageRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNClassificationObservation] ?? []
                let confidentLabels = observations
                    .filter { $0.confidence > 0.12 }
                    .prefix(5)
                    .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }

                let top = observations.first
                continuation.resume(
                    returning: ClassificationResult(
                        label: top?.identifier.replacingOccurrences(of: "_", with: " "),
                        confidence: top?.confidence,
                        allLabels: Array(confidentLabels)
                    )
                )
            }

            perform([request], on: cgImage, orientation: orientation, continuation: continuation)
        }
    }

    private func recognizeText(
        _ cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let strings = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }

                continuation.resume(returning: deduplicated(strings))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            perform([request], on: cgImage, orientation: orientation, continuation: continuation)
        }
    }

    private func perform<T>(
        _ requests: [VNRequest],
        on cgImage: CGImage,
        orientation: CGImagePropertyOrientation,
        continuation: CheckedContinuation<T, Error>
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let handler = VNImageRequestHandler(
                    cgImage: cgImage,
                    orientation: orientation,
                    options: [:]
                )
                try handler.perform(requests)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func deduplicated(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { string in
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, !seen.contains(normalized.lowercased()) else {
                return false
            }
            seen.insert(normalized.lowercased())
            return true
        }
    }
}

private struct ClassificationResult {
    var label: String?
    var confidence: Float?
    var allLabels: [String]
}

private extension UIImage {
    var cgImageOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
