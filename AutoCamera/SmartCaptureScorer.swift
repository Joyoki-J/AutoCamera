import Foundation
import Vision

struct SmartCaptureScore {
    let value: Float
    let captureQuality: Float
    let smileProbability: Float
}

final class SmartCaptureScorer {
    private var passingFrameCount = 0
    private let threshold: Float = 0.8
    private let requiredPassingFrames = 3

    func evaluate(_ observations: [VNFaceObservation]) -> SmartCaptureScore? {
        evaluate(qualityObservations: observations, landmarkObservations: observations)
    }

    func evaluate(qualityObservations: [VNFaceObservation], landmarkObservations: [VNFaceObservation]) -> SmartCaptureScore? {
        guard let bestFace = qualityObservations.max(by: { lhs, rhs in
            faceQuality(lhs) < faceQuality(rhs)
        }) else {
            passingFrameCount = 0
            return nil
        }

        let landmarkFace = matchedLandmarkObservation(for: bestFace, in: landmarkObservations)
        let quality = faceQuality(bestFace)
        let smile = landmarkFace.map(smileProbability) ?? 0
        let value = quality * 0.6 + smile * 0.4

        if value > threshold {
            passingFrameCount += 1
        } else {
            passingFrameCount = 0
        }

        return SmartCaptureScore(value: value, captureQuality: quality, smileProbability: smile)
    }

    func shouldCapture(score: SmartCaptureScore?) -> Bool {
        guard score != nil else { return false }
        return passingFrameCount >= requiredPassingFrames
    }

    func reset() {
        passingFrameCount = 0
    }

    private func faceQuality(_ observation: VNFaceObservation) -> Float {
        if let quality = observation.faceCaptureQuality {
            return clamped(quality)
        }
        return clamped(observation.confidence)
    }

    private func smileProbability(_ observation: VNFaceObservation) -> Float {
        guard let points = observation.landmarks?.outerLips?.normalizedPoints, points.count >= 4 else { return 0 }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let width = maxX - minX
        let height = max(maxY - minY, 0.001)
        let ratio = Float(width / height)
        return clamped((ratio - 2.0) / 1.5)
    }

    private func matchedLandmarkObservation(for observation: VNFaceObservation, in observations: [VNFaceObservation]) -> VNFaceObservation? {
        observations.min { lhs, rhs in
            boundingBoxDistance(lhs.boundingBox, observation.boundingBox) < boundingBoxDistance(rhs.boundingBox, observation.boundingBox)
        }
    }

    private func boundingBoxDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY) + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private func clamped(_ value: Float) -> Float {
        max(0, min(1, value))
    }
}
