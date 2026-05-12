import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Vision
#if canImport(MLX) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLXVLM) && canImport(Tokenizers)
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers
#endif

actor MLXFrameProcessor {
    static let shared = MLXFrameProcessor()

    private let targetSize = CGSize(width: 384, height: 384)
    #if canImport(MLX) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLXVLM) && canImport(Tokenizers)
    private let modelConfiguration = VLMRegistry.qwen2VL2BInstruct4Bit
    private var modelContainer: ModelContainer?
    #endif

    private var lastPlan: DirectorPlan?

    func preload(progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        #if canImport(MLX) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLXVLM) && canImport(Tokenizers)
        _ = try await loadContainer(progressHandler: progressHandler)
        #else
        progressHandler?(1)
        #endif
    }

    /// 智拍模式下根据是否检测到人物，组织相应提示词产出结构化导演计划。
    func process(pixelBuffer: CVPixelBuffer, hasPerson: Bool) async -> DirectorPlan? {
        guard let resized = MLXFrameProcessor.resize(pixelBuffer: pixelBuffer, to: targetSize) else { return nil }

        #if canImport(MLX) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLXVLM) && canImport(Tokenizers)
        let image = CIImage(cvPixelBuffer: resized)
        let systemPrompt = hasPerson
            ? "你是一位专业摄影导演，正在指导用户拍人物。严格输出 JSON：{\"subject\":\"portrait\",\"summary\":\"一句中文构图建议\",\"pose\":\"(可选)简短姿态指令\"}"
            : "你是一位专业摄影导演，正在拍风景。严格输出 JSON：{\"subject\":\"scene\",\"summary\":\"一句中文构图建议\",\"zoom\":1.0,\"focus_x\":0.5,\"focus_y\":0.5}。zoom 1.0~3.0，focus_x/y 为兴趣主体的归一化坐标。"
        do {
            let container = try await loadContainer(progressHandler: nil)
            let userInput = UserInput(
                chat: [
                    .system(systemPrompt),
                    .user("请分析当前画面并严格返回 JSON。", images: [.ciImage(image)])
                ],
                processing: .init(resize: targetSize)
            )
            let input = try await container.prepare(input: userInput)
            let stream = try await container.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 120, temperature: 0.2)
            )
            var response = ""
            loop: for await g in stream {
                switch g {
                case .chunk(let t):
                    response += t
                    if response.count >= 240 { break loop }
                case .info, .toolCall:
                    break
                }
            }
            Memory.clearCache()
            let plan = MLXFrameProcessor.parsePlan(from: response, fallbackPortrait: hasPerson)
            lastPlan = plan
            return plan
        } catch {
            Memory.clearCache()
            // 不把权重不匹配等冗长错误吐到 UI；保留上一次的导演计划，避免文案抖动。
            print("[MLX] inference failed: \(error)")
            return lastPlan ?? DirectorPlan(
                subject: hasPerson ? .portrait : .scene,
                summary: hasPerson
                    ? "AI 导演正在加载中，可以先调整姿态后按快门拍摄。"
                    : "AI 导演正在加载中，可以试试三分线构图，再按快门。",
                poseConstraints: [],
                suggestedZoom: nil,
                suggestedFocusPoint: nil)
        }
        #else
        let fallback = DirectorPlan(
            subject: hasPerson ? .portrait : .scene,
            summary: hasPerson ? "让主体稍微偏向三分线，肩膀放松微笑。" : "把地平线放在下三分之一线，突出天空层次。",
            poseConstraints: [],
            suggestedZoom: nil,
            suggestedFocusPoint: nil)
        lastPlan = fallback
        return fallback
        #endif
    }

    #if canImport(MLX) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLXVLM) && canImport(Tokenizers)
    private func loadContainer(progressHandler: (@Sendable (Double) -> Void)?) async throws -> ModelContainer {
        if let modelContainer {
            progressHandler?(1)
            return modelContainer
        }

        let container = try await loadModelContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: modelConfiguration) { progress in
                progressHandler?(progress.fractionCompleted)
            }
        modelContainer = container
        return container
    }
    #endif

    private static func parsePlan(from text: String, fallbackPortrait: Bool) -> DirectorPlan {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start < end {
            let jsonString = String(cleaned[start...end])
            if let data = jsonString.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let subject: DirectorPlan.SubjectKind = (obj["subject"] as? String == "scene") ? .scene : .portrait
                let summary = (obj["summary"] as? String) ?? cleaned
                var constraints: [PoseConstraint] = []
                if let pose = obj["pose"] as? String, !pose.isEmpty {
                    constraints = MLXFrameProcessor.constraints(fromPoseText: pose)
                }
                var zoom: CGFloat?
                if let z = obj["zoom"] as? Double { zoom = CGFloat(z) }
                var focus: CGPoint?
                if let fx = obj["focus_x"] as? Double, let fy = obj["focus_y"] as? Double {
                    focus = CGPoint(x: fx, y: fy)
                }
                return DirectorPlan(subject: subject,
                                    summary: summary.isEmpty ? cleaned : summary,
                                    poseConstraints: constraints,
                                    suggestedZoom: zoom,
                                    suggestedFocusPoint: focus)
            }
        }
        return DirectorPlan(subject: fallbackPortrait ? .portrait : .scene,
                            summary: cleaned.isEmpty ? "正在分析构图与姿态..." : cleaned,
                            poseConstraints: [],
                            suggestedZoom: nil,
                            suggestedFocusPoint: nil)
    }

    /// 把模型输出的中文姿态指令映射为可执行的姿态约束（简化关键词匹配）。
    private static func constraints(fromPoseText text: String) -> [PoseConstraint] {
        let t = text
        var result: [PoseConstraint] = []
        if t.contains("举起左手") || t.contains("抬起左手") || t.contains("左手高") {
            result.append(PoseConstraint(targetJoint: .leftWrist, referenceJoint: .nose,
                                         relation: .higherThan, threshold: 0.08,
                                         guidanceText: "请抬高左手"))
        }
        if t.contains("举起右手") || t.contains("抬起右手") || t.contains("右手高") {
            result.append(PoseConstraint(targetJoint: .rightWrist, referenceJoint: .nose,
                                         relation: .higherThan, threshold: 0.08,
                                         guidanceText: "请抬高右手"))
        }
        if t.contains("叉腰") {
            result.append(PoseConstraint(targetJoint: .leftWrist, referenceJoint: .leftShoulder,
                                         relation: .lowerThan, threshold: 0.05,
                                         guidanceText: "左手放到腰间"))
            result.append(PoseConstraint(targetJoint: .rightWrist, referenceJoint: .rightShoulder,
                                         relation: .lowerThan, threshold: 0.05,
                                         guidanceText: "右手放到腰间"))
        }
        if t.contains("侧脸") || t.contains("看向左") {
            result.append(PoseConstraint(targetJoint: .nose, referenceJoint: .leftEye,
                                         relation: .leftOf, threshold: 0.02,
                                         guidanceText: "脸稍稍偏向左侧"))
        }
        return result
    }

    private static func resize(pixelBuffer: CVPixelBuffer, to size: CGSize) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]
        var dest: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                                         kCVPixelFormatType_32BGRA, attributes as CFDictionary, &dest)
        guard status == kCVReturnSuccess, let dest else { return nil }
        let src = CIImage(cvPixelBuffer: pixelBuffer)
        let sx = size.width / max(src.extent.width, 1)
        let sy = size.height / max(src.extent.height, 1)
        let scaled = src.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let ctx = CIContext(options: [.cacheIntermediates: false])
        ctx.render(scaled, to: dest)
        return dest
    }
}
