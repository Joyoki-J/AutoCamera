import Vision
import CoreGraphics
import Foundation
import QuartzCore

// MARK: - 1. 全方位行为与运动学特征签名
public struct FullBehavioralSignature {
    let expressionExpressiveness: Float
    let gestureEnergy: Float
    let faceCenter: CGPoint
    let yaw: Float
    let pitch: Float
    
    // 👶 针对儿童高动态场景的身体运动学指标
    let bodyJointConfidence: Float
    let bodyCenterY: Float
    let bodyTiltAngle: Float
    let timestamp: TimeInterval
}

// MARK: - 2. 智能抓拍引擎
public class UltimateSmartCaptureEngine {
    
    private var lock = NSLock()
    
    // --- 状态控制变量 ---
    private var cooldownFrames = 0
    private var recentSignatures: [FullBehavioralSignature] = []
    private var lastCapturedSignature: FullBehavioralSignature? = nil
    private var stableFrameCount = 0
    private var hasMovedOrRelaxedSinceLastCapture = false
    private var significantExpressionCount = 0  // 连续显著表情帧计数
    
    // --- 智能场景阈值（针对高动态抓拍调优） ---
    private let stabilityThreshold: Float = 0.06
    private let fallDropThreshold: Float = 0.12
    private let expressionSpikeThreshold: Float = 0.30
    private let windowSize = 15
    private let minFaceQualityForExpression: Float = 0.22  // 表情触发最低人脸质量
    
    public init() {}

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        cooldownFrames = 0
        recentSignatures.removeAll()
        lastCapturedSignature = nil
        stableFrameCount = 0
        hasMovedOrRelaxedSinceLastCapture = false
        significantExpressionCount = 0
    }

    // MARK: - 核心审计方法
    public func evaluate(validFace: VNFaceObservation?,
                         bodyPoseObservations: [VNHumanBodyPoseObservation],
                         handPoseObservations: [VNHumanHandPoseObservation] = []) -> Bool {
        
        lock.lock(); defer { lock.unlock() }
        
        if cooldownFrames > 0 { cooldownFrames -= 1 }
        
        // 1. 提取面部基础特征
        let hasFace = validFace != nil && validFace!.confidence > 0.5
        let currentExpressiveness = hasFace ? calculateExpressiveness(validFace!) : 0.0
        let faceCenter = hasFace ? CGPoint(x: validFace!.boundingBox.midX, y: validFace!.boundingBox.midY) : .zero
        let yawAngle = hasFace ? (validFace!.yaw?.floatValue ?? 0.0) : 0.0
        let pitchAngle = hasFace ? estimatePitchAngle(validFace!) : 0.0
        
        // 2. 提取手势
        let gestureScore = extractHandGestureScore(handPoseObservations)
        
        // 3. 👶 提取身体运动学和质心数据
        let bodyMetrics = extractBodyMetrics(bodyPoseObservations)
        
        // 4. 生成这一帧的复合行为签名
        let currentSig = FullBehavioralSignature(
            expressionExpressiveness: currentExpressiveness,
            gestureEnergy: gestureScore,
            faceCenter: faceCenter,
            yaw: yawAngle,
            pitch: pitchAngle,
            bodyJointConfidence: bodyMetrics.confidence,
            bodyCenterY: bodyMetrics.centerY,
            bodyTiltAngle: bodyMetrics.tiltAngle,
            timestamp: CACurrentMediaTime()
        )
        
        recentSignatures.append(currentSig)
        if recentSignatures.count > windowSize { recentSignatures.removeFirst() }
        
        // 5. 状态重置判定
        if let lastCap = lastCapturedSignature {
            let spatialDiff = calculateSpatialDifference(currentSig, lastCap)
            if spatialDiff > 0.25 || currentExpressiveness < 0.25 {
                hasMovedOrRelaxedSinceLastCapture = true
            }
        } else {
            hasMovedOrRelaxedSinceLastCapture = true
        }
        
        if cooldownFrames > 0 { return false }
        guard recentSignatures.count >= 4 else { return false }
        
        // 获取历史参考帧
        let prevSigShort = recentSignatures[recentSignatures.count - 3]
        
        // ==========================================
        // 轨一：【跌倒/失衡紧急突变轨】
        // ==========================================
        if currentSig.bodyJointConfidence > 0.5 && prevSigShort.bodyJointConfidence > 0.5 {
            let centerDrop = prevSigShort.bodyCenterY - currentSig.bodyCenterY
            let tiltSpike = Swift.abs(currentSig.bodyTiltAngle - prevSigShort.bodyTiltAngle)
            
            if centerDrop > fallDropThreshold || tiltSpike > 0.6 {
                print("🚨 捕获到紧急突变：孩子失去重心或跌倒瞬间！")
                triggerCapture(with: currentSig)
                return true
            }
        }
        
        // ==========================================
        // 轨二：【跳跃最高点/运动转折轨】
        // ==========================================
        if recentSignatures.count >= 6 {
            let prevSigLong = recentSignatures[recentSignatures.count - 5]
            let yCurrent = currentSig.bodyCenterY
            let yPrev = prevSigShort.bodyCenterY
            let yOld = prevSigLong.bodyCenterY
            
            if yPrev > yOld && yCurrent <= yPrev && currentSig.bodyJointConfidence > 0.6 {
                print("🚀 捕获到高动态瞬间：跳跃至最高点定格！")
                triggerCapture(with: currentSig)
                return true
            }
        }
        
        // ==========================================
        // 轨三：【高能情绪爆发轨】（帧间突变 + 绝对高分）
        // ==========================================
        let expressivenessSpike = currentSig.expressionExpressiveness - prevSigShort.expressionExpressiveness
        if expressivenessSpike > expressionSpikeThreshold {
            print("💥 捕获到情绪爆发：表情突然变化的高能瞬间！")
            triggerCapture(with: currentSig)
            return true
        }

        // 轨三扩展：显著表情持续高分（微笑、伸舌头、瞪眼等持续夸张表情）
        let faceQuality = validFace?.faceCaptureQuality ?? (hasFace ? validFace!.confidence : 0.0)
        if currentExpressiveness >= 0.35 && faceQuality >= minFaceQualityForExpression {
            significantExpressionCount += 1
            if significantExpressionCount >= 3 {
                print("😄 捕获到显著表情：微笑、伸舌头或瞪眼等夸张表情！")
                triggerCapture(with: currentSig)
                return true
            }
        } else {
            significantExpressionCount = max(0, significantExpressionCount - 2)
        }

        // 轨三扩展 B：惊讶/瞪眼直接触发（高分瞬间立即响应，无需等待连续帧）
        if currentExpressiveness >= 0.50 && faceQuality >= minFaceQualityForExpression {
            print("😲 捕获到惊讶/瞪眼瞬间！")
            triggerCapture(with: currentSig)
            return true
        }

        // ==========================================
        // 轨四：【美学/舞蹈动作定格轨】
        // ==========================================
        let variance = calculateVariance(recentSignatures)
        let isStabilized = variance < stabilityThreshold

        // 提高 hasIntent 门槛：单纯"平静脸"不再算 intent，必须有手势或身体动作
        let hasIntent = (currentExpressiveness > 0.40 || gestureScore > 0.5 || currentSig.bodyJointConfidence > 0.6)

        if isStabilized && hasIntent && hasMovedOrRelaxedSinceLastCapture {
            stableFrameCount += 1
            if stableFrameCount >= 5 {
                print("📸 捕获到定格瞬间：玩耍/跳舞中的精彩 Pose！")
                triggerCapture(with: currentSig)
                return true
            }
        } else {
            stableFrameCount = max(0, stableFrameCount - 1)
        }

        return false
    }
    
    private func triggerCapture(with signature: FullBehavioralSignature) {
        lastCapturedSignature = signature
        hasMovedOrRelaxedSinceLastCapture = false
        cooldownFrames = 45
        stableFrameCount = 0
        significantExpressionCount = 0
    }
    
    // MARK: - 3. 内部核心运动学算法
    
    /// 🧠 修复问题：通过提取鼻子最高点 Y 轴坐标（鼻根）与轮廓坐标极值，进行非数组安全计算
    private func estimatePitchAngle(_ observation: VNFaceObservation) -> Float {
        guard let landmarks = observation.landmarks,
              let nose = landmarks.nose,
              let contour = landmarks.faceContour else { return 0.0 }
        
        let noseYs = nose.normalizedPoints.map { Float($0.y) }
        let contourYs = contour.normalizedPoints.map { Float($0.y) }
        
        // 修复：从数组中安全过滤极值点，避免直接调用 .y 报错
        guard let noseTipY = noseYs.max(),           // 鼻尖 Y 最大（Vision 坐标系向下为正）
              let topY = contourYs.min(),             // 额头/头顶 Y 最小
              let chinY = contourYs.max() else { return 0.0 }  // 下巴 Y 最大

        let upperLength = Swift.abs(topY - noseTipY)   // 额头到鼻尖
        let lowerLength = Swift.abs(noseTipY - chinY)  // 鼻尖到下巴
        
        if lowerLength == 0 { return 0.0 }
        return (upperLength / lowerLength) - 1.0
    }
    
    /// 🎭 修复问题：全面改用 map 提取浮点数数组后求极值差的方式计算开合度
    private func calculateExpressiveness(_ observation: VNFaceObservation) -> Float {
        guard let landmarks = observation.landmarks else { return 0.0 }
        
        var eyeExaggeration: Float = 0.0
        if let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye {
            let leftYs = leftEye.normalizedPoints.map { Float($0.y) }
            let rightYs = rightEye.normalizedPoints.map { Float($0.y) }
            if let lMax = leftYs.max(), let lMin = leftYs.min(), let rMax = rightYs.max(), let rMin = rightYs.min() {
                // 提高放大系数：平静睁眼约 0.25~0.35，夸张瞪眼约 0.7~1.0
                eyeExaggeration = ((lMax - lMin) + (rMax - rMin)) * 7.0
            }
        }

        var mouthOpenness: Float = 0.0
        if let outerLips = landmarks.outerLips {
            let lipYs = outerLips.normalizedPoints.map { Float($0.y) }
            if let mMax = lipYs.max(), let mMin = lipYs.min() {
                // 提高放大系数：自然闭合约 0.1~0.2，大笑/伸舌头约 0.6~1.0
                mouthOpenness = (mMax - mMin) * 7.0
            }
        }

        // 微笑检测：精确找到嘴角并计算上扬幅度
        var smileBonus: Float = 0.0
        if let outerLips = landmarks.outerLips, outerLips.normalizedPoints.count >= 6 {
            let points = outerLips.normalizedPoints
            if let leftCorner = points.min(by: { $0.x < $1.x }),
               let rightCorner = points.max(by: { $0.x < $1.x }) {
                let centerY = points.map { $0.y }.reduce(0, +) / CGFloat(points.count)
                let cornerLift = (Float(leftCorner.y) + Float(rightCorner.y)) * 0.5 - Float(centerY)
                // 嘴角上扬时 cornerLift 为负（Vision Y 轴向下为正）
                smileBonus = max(0, -cornerLift) * 6.0
            }
        }

        let rawScore = (eyeExaggeration * 0.25) + (mouthOpenness * 0.45) + (smileBonus * 0.30)
        return min(max(rawScore, 0.0), 1.0)
    }
    
    private func extractBodyMetrics(_ observations: [VNHumanBodyPoseObservation]) -> (confidence: Float, centerY: Float, tiltAngle: Float) {
        guard let body = observations.first else { return (0.0, 0.0, 0.0) }
        
        guard let neckJoint = try? body.recognizedPoint(.neck),
              let rootJoint = try? body.recognizedPoint(.root),
              neckJoint.confidence > 0.3 && rootJoint.confidence > 0.3 else {
            
            if let lShoulder = try? body.recognizedPoint(.leftShoulder),
               let rShoulder = try? body.recognizedPoint(.rightShoulder),
               lShoulder.confidence > 0.3 && rShoulder.confidence > 0.3 {
                let midY = Float(lShoulder.location.y + rShoulder.location.y) * 0.5
                return (Float(lShoulder.confidence), midY, 0.0)
            }
            return (0.0, 0.0, 0.0)
        }
        
        let centerY = Float(neckJoint.location.y + rootJoint.location.y) * 0.5
        
        let deltaX = Float(neckJoint.location.x - rootJoint.location.x)
        let deltaY = Float(neckJoint.location.y - rootJoint.location.y)
        let tiltAngle = deltaY != 0 ? atan(deltaX / deltaY) : 0.0
        
        let avgConfidence = Float(neckJoint.confidence + rootJoint.confidence) * 0.5
        return (avgConfidence, centerY, tiltAngle)
    }
    
    private func calculateSpatialDifference(_ a: FullBehavioralSignature, _ b: FullBehavioralSignature) -> Float {
        let dExp = pow(a.expressionExpressiveness - b.expressionExpressiveness, 2)
        let dPos = pow(Float(a.faceCenter.x - b.faceCenter.x), 2) + pow(Float(a.faceCenter.y - b.faceCenter.y), 2)
        let dBody = pow(a.bodyCenterY - b.bodyCenterY, 2)
        return sqrt(dExp + dPos * 1.5 + dBody * 2.0)
    }
    
    private func calculateVariance(_ sigs: [FullBehavioralSignature]) -> Float {
        guard sigs.count >= 3 else { return 0.0 }
        let count = Float(sigs.count)
        let avgExp = sigs.map { $0.expressionExpressiveness }.reduce(0, +) / count
        let avgBodyY = sigs.map { $0.bodyCenterY }.reduce(0, +) / count
        
        let varExp = sigs.map { pow($0.expressionExpressiveness - avgExp, 2) }.reduce(0, +) / count
        let varBodyY = sigs.map { pow($0.bodyCenterY - avgBodyY, 2) }.reduce(0, +) / count
        
        return (varExp * 0.4 + varBodyY * 0.6)
    }
    
    private func extractHandGestureScore(_ handObservations: [VNHumanHandPoseObservation]) -> Float {
        guard let primaryHand = handObservations.first else { return 0.0 }
        return Float(primaryHand.confidence)
    }
}
