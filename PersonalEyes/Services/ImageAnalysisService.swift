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

/// Runs Apple Vision on a captured photo to gather evidence for describing
/// whatever the image shows — people, objects, animals, and scene.
struct ImageAnalysisService {
    /// - Parameter focusBox: Optional Vision-normalized box (origin bottom-left)
    ///   from live aiming. When present, that region is classified as a subject.
    func analyze(
        _ image: UIImage,
        preferences: AnalysisPreferences,
        focusBox: CGRect? = nil
    ) async throws -> ImageAnalysisResult {
        guard let cgImage = image.cgImage else {
            throw ImageAnalysisError.missingImageData
        }

        let orientation = image.cgImageOrientation

        async let fullClassification = classifyImage(cgImage, orientation: orientation)
        async let text = recognizeText(cgImage, orientation: orientation)
        async let detectedFocus = detectPrimaryObjectBox(cgImage, orientation: orientation)

        let (full, visibleText, saliencyBox) = try await (
            fullClassification,
            text,
            detectedFocus
        )
        let animalLabels = await recognizeAnimalsSafe(cgImage, orientation: orientation)
        let peopleCount = await detectPeopleCountSafe(cgImage, orientation: orientation)

        let objectBox = Self.pickFocusBox(preferred: focusBox, detected: saliencyBox)
        var cropClassification: ClassificationResult?
        if let objectBox,
           let crop = Self.crop(cgImage, toVisionBox: objectBox, padding: 0.08) {
            cropClassification = try await classifyImage(crop, orientation: .up)
        }

        let resolved = Self.resolvePrimarySubject(
            fullImage: full,
            objectCrop: cropClassification,
            animals: animalLabels,
            peopleCount: peopleCount
        )

        return ImageAnalysisResult(
            objectName: resolved.label,
            confidence: resolved.confidence,
            labels: resolved.allLabels,
            peopleCount: peopleCount,
            visibleText: preferences.includeVisibleText ? visibleText : [],
            timestamp: Date()
        )
    }

    // MARK: - Vision requests

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

                let observations = (request.results as? [VNClassificationObservation] ?? [])
                    .filter { $0.confidence > 0.08 }
                let labels = observations.prefix(8).map { Self.humanize($0.identifier) }
                let top = observations.first
                continuation.resume(
                    returning: ClassificationResult(
                        label: top.map { Self.humanize($0.identifier) },
                        confidence: top?.confidence,
                        allLabels: Array(labels)
                    )
                )
            }

            perform([request], on: cgImage, orientation: orientation, continuation: continuation)
        }
    }

    private func recognizeAnimalsSafe(
        _ cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async -> [String] {
        (try? await recognizeAnimals(cgImage, orientation: orientation)) ?? []
    }

    private func detectPeopleCountSafe(
        _ cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async -> Int {
        (try? await detectPeopleCount(cgImage, orientation: orientation)) ?? 0
    }

    private func detectPeopleCount(
        _ cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectHumanRectanglesRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let humans = request.results as? [VNHumanObservation] ?? []
                continuation.resume(returning: humans.count)
            }
            request.upperBodyOnly = false
            perform([request], on: cgImage, orientation: orientation, continuation: continuation)
        }
    }

    private func recognizeAnimals(
        _ cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeAnimalsRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedObjectObservation] ?? []
                let labels = observations.compactMap { observation -> String? in
                    guard let label = observation.labels.first else { return nil }
                    guard label.confidence > 0.35 else { return nil }
                    return Self.humanize(label.identifier)
                }
                continuation.resume(returning: Array(Set(labels)))
            }
            perform([request], on: cgImage, orientation: orientation, continuation: continuation)
        }
    }

    private func detectPrimaryObjectBox(
        _ cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async throws -> CGRect? {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNGenerateObjectnessBasedSaliencyImageRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard
                    let observation = request.results?.first as? VNSaliencyImageObservation,
                    let objects = observation.salientObjects,
                    !objects.isEmpty
                else {
                    continuation.resume(returning: nil)
                    return
                }

                let best = objects.max { lhs, rhs in
                    Self.boxScore(lhs.boundingBox) < Self.boxScore(rhs.boundingBox)
                }
                continuation.resume(returning: best?.boundingBox)
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

    // MARK: - Subject resolution

    static func pickFocusBox(preferred: CGRect?, detected: CGRect?) -> CGRect? {
        if let preferred, preferred.width > 0.04, preferred.height > 0.04 {
            return preferred.insetBy(dx: -0.02, dy: -0.02).standardized
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return detected
    }

    static func resolvePrimarySubject(
        fullImage: ClassificationResult,
        objectCrop: ClassificationResult?,
        animals: [String],
        peopleCount: Int
    ) -> ClassificationResult {
        if peopleCount > 0 {
            let peopleLabel = peopleCount == 1 ? "person" : "\(peopleCount) people"
            var labels = [peopleLabel] + animals + (objectCrop?.allLabels ?? []) + fullImage.allLabels
            labels = uniqued(labels)
            return ClassificationResult(
                label: peopleLabel,
                confidence: max(objectCrop?.confidence ?? 0, fullImage.confidence ?? 0, 0.75),
                allLabels: labels
            )
        }

        if let animal = animals.first {
            var labels = [animal] + (objectCrop?.allLabels ?? []) + fullImage.allLabels
            labels = uniqued(labels)
            return ClassificationResult(
                label: animal,
                confidence: max(objectCrop?.confidence ?? 0, fullImage.confidence ?? 0, 0.7),
                allLabels: labels
            )
        }

        let cropBest = objectCrop.flatMap { bestObjectCandidate(in: $0) }
        let fullBest = bestObjectCandidate(in: fullImage)

        if let cropBest, let fullBest {
            let cropLabel = cropBest.label ?? ""
            let fullLabel = fullBest.label ?? ""
            let cropConfidence = cropBest.confidence ?? 0
            let fullConfidence = fullBest.confidence ?? 0

            if isVagueSceneLabel(fullLabel), !isVagueSceneLabel(cropLabel) {
                return merging(primary: cropBest, secondary: fullImage)
            }
            if cropConfidence + 0.05 >= fullConfidence || !isVagueSceneLabel(cropLabel) {
                return merging(primary: cropBest, secondary: fullImage)
            }
            return merging(primary: fullBest, secondary: objectCrop ?? fullImage)
        }

        if let cropBest {
            return merging(primary: cropBest, secondary: fullImage)
        }
        if let fullBest {
            return fullBest
        }

        return ClassificationResult(
            label: fullImage.label,
            confidence: fullImage.confidence,
            allLabels: uniqued((objectCrop?.allLabels ?? []) + fullImage.allLabels)
        )
    }

    private static func bestObjectCandidate(
        in result: ClassificationResult
    ) -> ClassificationResult? {
        let ranked = result.allLabels.enumerated().compactMap { index, label -> (String, Float, Int)? in
            let confidence = index == 0
                ? (result.confidence ?? 0.2)
                : max(0.05, (result.confidence ?? 0.2) - Float(index) * 0.04)
            return (label, confidence, objectSpecificityScore(label))
        }
        .sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            return lhs.1 > rhs.1
        }

        guard let best = ranked.first else {
            guard let label = result.label else { return nil }
            return ClassificationResult(label: label, confidence: result.confidence, allLabels: result.allLabels)
        }
        return ClassificationResult(
            label: best.0,
            confidence: best.1,
            allLabels: result.allLabels
        )
    }

    private static func merging(
        primary: ClassificationResult,
        secondary: ClassificationResult
    ) -> ClassificationResult {
        ClassificationResult(
            label: primary.label,
            confidence: primary.confidence,
            allLabels: uniqued([primary.label].compactMap { $0 } + primary.allLabels + secondary.allLabels)
        )
    }

    private static func objectSpecificityScore(_ label: String) -> Int {
        let lower = label.lowercased()
        if isVagueSceneLabel(lower) { return 0 }
        let words = lower.split(separator: " ").count
        return 10 + min(words, 3) * 2 + min(lower.count, 24)
    }

    private static func isVagueSceneLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        if lower.contains("person") || lower.contains("people") || lower.contains("human") {
            return false
        }
        let sceneTerms = [
            "indoor", "outdoor", "outside", "inside", "room", "building", "street",
            "landscape", "nature", "sky", "floor", "wall", "ceiling", "background",
            "furniture", "interior", "exterior", "scene", "photo",
            "image", "screenshot", "text", "document", "pattern"
        ]
        return sceneTerms.contains { lower == $0 || lower.contains($0) }
    }

    static func humanize(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func uniqued(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.compactMap { label in
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return trimmed
        }
    }

    private static func boxScore(_ box: CGRect) -> CGFloat {
        let area = box.width * box.height
        guard area >= 0.02, area <= 0.75 else { return -1 }
        let dx = box.midX - 0.5
        let dy = box.midY - 0.5
        let centerDistance = sqrt(dx * dx + dy * dy)
        return area * 1.4 - centerDistance
    }

    static func crop(
        _ cgImage: CGImage,
        toVisionBox box: CGRect,
        padding: CGFloat
    ) -> CGImage? {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > 1, height > 1 else { return nil }

        var normalized = box.insetBy(dx: -padding, dy: -padding)
        normalized = normalized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard normalized.width > 0.05, normalized.height > 0.05 else { return nil }

        let rect = CGRect(
            x: normalized.minX * width,
            y: (1 - normalized.maxY) * height,
            width: normalized.width * width,
            height: normalized.height * height
        ).integral

        guard rect.width >= 16, rect.height >= 16 else { return nil }
        return cgImage.cropping(to: rect)
    }
}

struct ClassificationResult {
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
