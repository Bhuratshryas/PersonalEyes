import CoreMedia
import CoreVideo
import ImageIO
import Vision

/// Uses Apple's built-in Vision object-detection saliency to find an object
/// in the camera frame and report how far its center is from the frame center,
/// plus signed offsets used for directional aiming cues.
final class CenteringDetector: @unchecked Sendable {
    struct Reading {
        /// Distance from frame center, normalized to 0 (centered) ... 1 (corner).
        var distance: Float
        /// Horizontal offset from center: negative = subject left, positive = right.
        var offsetX: Float
        /// Vertical offset from center: negative = subject down, positive = up
        /// (Vision image coordinates).
        var offsetY: Float
        /// Normalized bounding box of the largest detected object in image
        /// coordinates (0,0 bottom-left, 1,1 top-right).
        var subjectBox: CGRect?
        /// True if Vision found a confident object in the frame.
        var hasSubject: Bool

        static let empty = Reading(
            distance: 1.0,
            offsetX: 0,
            offsetY: 0,
            subjectBox: nil,
            hasSubject: false
        )
    }

    private let request = VNGenerateObjectnessBasedSaliencyImageRequest()

    func reading(
        for pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> Reading {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        do {
            try handler.perform([request])
            guard
                let observation = request.results?.first as? VNSaliencyImageObservation,
                let subject = mostProminentObject(in: observation)
            else {
                return .empty
            }

            let box = subject.boundingBox
            let dx = Float(box.midX - 0.5)
            let dy = Float(box.midY - 0.5)
            let raw = sqrt(dx * dx + dy * dy)
            let maxDistance = Float(sqrt(0.5))
            let normalized = min(1.0, raw / maxDistance)
            return Reading(
                distance: normalized,
                offsetX: dx,
                offsetY: dy,
                subjectBox: box,
                hasSubject: true
            )
        } catch {
            return .empty
        }
    }

    /// Prefer the subject closest to center, weighted by area so a large
    /// central object wins over a tiny edge artifact.
    private func mostProminentObject(
        in observation: VNSaliencyImageObservation
    ) -> VNRectangleObservation? {
        guard let objects = observation.salientObjects, !objects.isEmpty else {
            return nil
        }

        return objects.max { lhs, rhs in
            score(for: lhs.boundingBox) < score(for: rhs.boundingBox)
        }
    }

    private func score(for box: CGRect) -> Double {
        let dx = box.midX - 0.5
        let dy = box.midY - 0.5
        let centerDistance = sqrt(dx * dx + dy * dy)
        let area = max(0.0001, box.width * box.height)
        return Double(area) - Double(centerDistance) * 0.5
    }
}
