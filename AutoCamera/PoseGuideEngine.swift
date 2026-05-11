import Foundation
import Vision

enum PoseRelation {
    case higherThan
    case lowerThan
    case leftOf
    case rightOf
}

struct PoseConstraint {
    let targetJoint: VNHumanBodyPoseObservation.JointName
    let referenceJoint: VNHumanBodyPoseObservation.JointName
    let relation: PoseRelation
    let threshold: CGFloat
    let guidanceText: String
}

struct PoseGuideResult {
    let isSatisfied: Bool
    let message: String?
    let direction: PoseRelation?
}

final class PoseGuideEngine {
    private let constraints: [PoseConstraint]
    private var recentMessages: [String?] = []
    private let windowSize = 5

    init(constraints: [PoseConstraint] = [
        PoseConstraint(targetJoint: .leftWrist, referenceJoint: .nose, relation: .higherThan, threshold: 0.08, guidanceText: "请抬高左手")
    ]) {
        self.constraints = constraints
    }

    func evaluate(_ observation: VNHumanBodyPoseObservation) -> PoseGuideResult {
        for constraint in constraints {
            guard let targetPoint = try? observation.recognizedPoint(constraint.targetJoint),
                  let referencePoint = try? observation.recognizedPoint(constraint.referenceJoint),
                  targetPoint.confidence > 0.35,
                  referencePoint.confidence > 0.35 else {
                return smoothedResult(message: "请保持人物完整入镜", direction: nil, isSatisfied: false)
            }

            let satisfied = isSatisfied(target: targetPoint.location, reference: referencePoint.location, constraint: constraint)
            if !satisfied {
                return smoothedResult(message: constraint.guidanceText, direction: constraint.relation, isSatisfied: false)
            }
        }

        return smoothedResult(message: nil, direction: nil, isSatisfied: true)
    }

    private func isSatisfied(target: CGPoint, reference: CGPoint, constraint: PoseConstraint) -> Bool {
        switch constraint.relation {
        case .higherThan:
            return target.y > reference.y + constraint.threshold
        case .lowerThan:
            return target.y < reference.y - constraint.threshold
        case .leftOf:
            return target.x < reference.x - constraint.threshold
        case .rightOf:
            return target.x > reference.x + constraint.threshold
        }
    }

    private func smoothedResult(message: String?, direction: PoseRelation?, isSatisfied: Bool) -> PoseGuideResult {
        recentMessages.append(message)
        if recentMessages.count > windowSize {
            recentMessages.removeFirst()
        }

        let grouped = Dictionary(grouping: recentMessages.compactMap { $0 }, by: { $0 })
        let dominantMessage = grouped.max { $0.value.count < $1.value.count }?.key
        let enoughConfidence = grouped[dominantMessage ?? ""]?.count ?? 0 >= 3

        if isSatisfied && recentMessages.filter({ $0 == nil }).count >= 3 {
            return PoseGuideResult(isSatisfied: true, message: nil, direction: nil)
        }

        return PoseGuideResult(isSatisfied: false, message: enoughConfidence ? dominantMessage : nil, direction: direction)
    }
}
