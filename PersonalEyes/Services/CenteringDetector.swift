import CoreMedia
import CoreVideo
import ImageIO
import Vision

/// Uses Apple's built-in Vision object-detection saliency to find an object
/// in the camera frame and report how far its center is from the frame center.
/// We use the objectness-based variant (rather than attention-based) so the
/// detector reacts to actual objects in view, not just visually striking
/// regions like sky or shadows.
struct CenteringDetector {
    struct Reading {
        /// Distance from frame center, normalized to 0 (centered) ... 1 (corner).
        var distance: Float
        /// Normalized bounding box of the largest detected object in image
        /// coordinates (0,0 bottom-left, 1,1 top-right).
        var subjectBox: CGRect?
        /// True if Vision found a confident object in the frame.
        var hasSubject: Bool
    }

    func reading(
        for pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> Reading {
        let request = VNGenerateObjectnessBasedSaliencyImageRequest()
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
                return Reading(distance: 1.0, subjectBox: nil, hasSubject: false)
            }

            let box = subject.boundingBox
            let dx = box.midX - 0.5
            let dy = box.midY - 0.5
            let raw = sqrt(dx * dx + dy * dy)
            let maxDistance = sqrt(0.5)
            let normalized = Float(min(1.0, raw / maxDistance))
            return Reading(distance: normalized, subjectBox: box, hasSubject: true)
        } catch {
            return Reading(distance: 1.0, subjectBox: nil, hasSubject: false)
        }
    }

    /// Pick the most useful detected object: prefer the one closest to the
    /// frame center, weighted by area so a large central subject wins over a
    /// tiny edge artifact.
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
        // Larger area is better, closer to center is better.
        return Double(area) - Double(centerDistance) * 0.5
    }
}
