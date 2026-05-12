import CoreGraphics
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

/// 智拍模式下的姿态差值引擎。
/// - 约束可在运行时由 MLX 导演动态替换；
/// - 内部使用滑动窗口平滑，避免文案抖动；
/// - 内部加锁保证多线程安全（Vision 队列 + MLX Task）。
final class PoseGuideEngine {
    private var constraints: [PoseConstraint]
    private var recentMessages: [String?] = []
    private let windowSize = 5
    private let confidenceThreshold: Float = 0.35
    private let lock = NSLock()

    static let defaultPortraitConstraints: [PoseConstraint] = [
        PoseConstraint(targetJoint: .leftWrist, referenceJoint: .nose, relation: .higherThan, threshold: 0.08, guidanceText: "请抬高左手")
    ]

    init(constraints: [PoseConstraint] = PoseGuideEngine.defaultPortraitConstraints) {
        self.constraints = constraints
    }

    func setConstraints(_ newConstraints: [PoseConstraint]) {
        lock.lock(); defer { lock.unlock() }
        constraints = newConstraints
        recentMessages.removeAll()
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        recentMessages.removeAll()
    }

    func evaluate(_ observation: VNHumanBodyPoseObservation) -> PoseGuideResult {
        lock.lock(); defer { lock.unlock() }
        guard !constraints.isEmpty else {
            return smoothedResultLocked(message: nil, direction: nil, isSatisfied: true)
        }
        for constraint in constraints {
            guard let targetPoint = try? observation.recognizedPoint(constraint.targetJoint),
                  let referencePoint = try? observation.recognizedPoint(constraint.referenceJoint),
                  targetPoint.confidence > confidenceThreshold,
                  referencePoint.confidence > confidenceThreshold else {
                return smoothedResultLocked(message: "请保持人物完整入镜", direction: nil, isSatisfied: false)
            }
            if !isSatisfied(target: targetPoint.location, reference: referencePoint.location, constraint: constraint) {
                return smoothedResultLocked(message: constraint.guidanceText, direction: constraint.relation, isSatisfied: false)
            }
        }
        return smoothedResultLocked(message: nil, direction: nil, isSatisfied: true)
    }

    private func isSatisfied(target: CGPoint, reference: CGPoint, constraint: PoseConstraint) -> Bool {
        switch constraint.relation {
        case .higherThan: return target.y > reference.y + constraint.threshold
        case .lowerThan:  return target.y < reference.y - constraint.threshold
        case .leftOf:     return target.x < reference.x - constraint.threshold
        case .rightOf:    return target.x > reference.x + constraint.threshold
        }
    }

    private func smoothedResultLocked(message: String?, direction: PoseRelation?, isSatisfied: Bool) -> PoseGuideResult {
        recentMessages.append(message)
        if recentMessages.count > windowSize {
            recentMessages.removeFirst()
        }
        let grouped = Dictionary(grouping: recentMessages.compactMap { $0 }, by: { $0 })
        let dominantMessage = grouped.max { $0.value.count < $1.value.count }?.key
        let enoughConfidence = (grouped[dominantMessage ?? ""]?.count ?? 0) >= 3
        if isSatisfied && recentMessages.filter({ $0 == nil }).count >= 3 {
            return PoseGuideResult(isSatisfied: true, message: nil, direction: nil)
        }
        return PoseGuideResult(isSatisfied: false, message: enoughConfidence ? dominantMessage : nil, direction: direction)
    }
}
