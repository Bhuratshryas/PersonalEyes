import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Vision

/// A detected object with a YOLO-style axis-aligned box in Vision coordinates
/// (origin bottom-left, normalized 0…1).
struct DetectedObjectBox: Equatable, Sendable {
    var boundingBox: CGRect
    var confidence: Float
    var label: String?

    var center: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }
}

/// Live framing reading derived from the tracked object box.
struct ObjectBoxReading: Equatable, Sendable {
    var distance: Float
    var offsetX: Float
    var offsetY: Float
    var subjectBox: CGRect?
    var label: String?
    var hasSubject: Bool
    var isCentered: Bool

    static let empty = ObjectBoxReading(
        distance: 1,
        offsetX: 0,
        offsetY: 0,
        subjectBox: nil,
        label: nil,
        hasSubject: false,
        isCentered: false
    )
}

/// Detects objects and tracks a primary bounding box for aiming.
///
/// Pipeline matches the YOLO assistive-camera pattern:
/// 1. Detect candidate boxes in the frame
/// 2. Choose the most useful subject
/// 3. Measure how far the box center is from the frame center
/// 4. Drive beeps / speech / auto-capture from that distance
///
/// Uses Vision objectness saliency for on-device boxes (no bundled weights).
/// Swap ``detectBoxes`` for a Core ML YOLOv8n `VNCoreMLRequest` later without
/// changing the centering / capture loop.
final class ObjectBoxDetector: @unchecked Sendable {
    /// How close the box center must be to frame center (0…1 corner distance).
    var centeredThreshold: Float = 0.28
    /// Ignore tiny false positives.
    var minimumBoxArea: CGFloat = 0.02
    /// Ignore near-full-frame blobs (often background).
    var maximumBoxArea: CGFloat = 0.72
    /// Temporal smoothing so the creative overlay does not jitter.
    var boxSmoothing: CGFloat = 0.35

    private let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
    private var smoothedBox: CGRect?

    func reading(
        for pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> ObjectBoxReading {
        let boxes = detectBoxes(in: pixelBuffer, orientation: orientation)
        guard let best = selectPrimaryBox(from: boxes) else {
            smoothedBox = nil
            return .empty
        }

        let smoothed = smooth(best.boundingBox)
        smoothedBox = smoothed

        let dx = Float(smoothed.midX - 0.5)
        let dy = Float(smoothed.midY - 0.5)
        let raw = sqrt(dx * dx + dy * dy)
        let maxDistance = Float(sqrt(0.5))
        let distance = min(1, raw / maxDistance)
        let centered = distance < centeredThreshold

        return ObjectBoxReading(
            distance: distance,
            offsetX: dx,
            offsetY: dy,
            subjectBox: smoothed,
            label: best.label,
            hasSubject: true,
            isCentered: centered
        )
    }

    func resetTracking() {
        smoothedBox = nil
    }

    // MARK: - Detection

    /// Returns YOLO-like boxes. Replace this body with Core ML YOLO when a
    /// `YOLOv8n.mlpackage` (exported with `nms=True`) is added to the app bundle.
    private func detectBoxes(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> [DetectedObjectBox] {
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        do {
            try handler.perform([saliencyRequest])
            guard
                let observation = saliencyRequest.results?.first as? VNSaliencyImageObservation,
                let objects = observation.salientObjects,
                !objects.isEmpty
            else {
                return []
            }

            return objects.compactMap { object in
                let box = object.boundingBox
                let area = box.width * box.height
                guard area >= minimumBoxArea, area <= maximumBoxArea else { return nil }
                return DetectedObjectBox(
                    boundingBox: box,
                    confidence: Float(min(1, area * 4)),
                    label: nil
                )
            }
        } catch {
            return []
        }
    }

    private func selectPrimaryBox(from boxes: [DetectedObjectBox]) -> DetectedObjectBox? {
        guard !boxes.isEmpty else { return nil }

        // Prefer continuity with the previous smoothed box (tracking), else
        // the largest box nearest the frame center — same idea as YOLO "main subject".
        if let previous = smoothedBox {
            let continued = boxes.max { lhs, rhs in
                iou(lhs.boundingBox, previous) < iou(rhs.boundingBox, previous)
            }
            if let continued, iou(continued.boundingBox, previous) > 0.12 {
                return continued
            }
        }

        return boxes.max { lhs, rhs in
            score(lhs) < score(rhs)
        }
    }

    private func score(_ box: DetectedObjectBox) -> Double {
        let dx = box.boundingBox.midX - 0.5
        let dy = box.boundingBox.midY - 0.5
        let centerDistance = sqrt(dx * dx + dy * dy)
        let area = max(0.0001, box.boundingBox.width * box.boundingBox.height)
        return Double(area) * 1.4 - centerDistance + Double(box.confidence) * 0.2
    }

    private func smooth(_ box: CGRect) -> CGRect {
        guard let previous = smoothedBox else { return box }
        let t = boxSmoothing
        return CGRect(
            x: previous.minX * (1 - t) + box.minX * t,
            y: previous.minY * (1 - t) + box.minY * t,
            width: previous.width * (1 - t) + box.width * t,
            height: previous.height * (1 - t) + box.height * t
        )
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let union = a.width * a.height + b.width * b.height - inter.width * inter.height
        guard union > 0 else { return 0 }
        return (inter.width * inter.height) / union
    }
}
