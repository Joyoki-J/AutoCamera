import CoreGraphics
import Foundation

/// 来自 MLX 大模型的"导演计划"，在智拍模式下驱动画面构图与姿态引导。
struct DirectorPlan {
    enum SubjectKind { case portrait, scene }
    var subject: SubjectKind
    var summary: String                 // 给用户看的一句中文构图建议
    var poseConstraints: [PoseConstraint]
    var suggestedZoom: CGFloat?         // 推荐变焦倍数（风景模式）
    var suggestedFocusPoint: CGPoint?   // 归一化 0~1 坐标
}
