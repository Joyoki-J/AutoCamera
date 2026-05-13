import CoreGraphics
import Foundation
import Vision

struct SmartCaptureScore {
    let value: Float
    let captureQuality: Float
    let smileProbability: Float
    let compositionScore: Float
    let emotionScore: Float
    let motionScore: Float
    let momentScore: Float
    let gestureScore: Float
    let wideEyesScore: Float      // 睁大眼睛检测
    let eyeOpenness: Float        // 眼睛睁开程度
}

enum SmartCaptureGesture {
    case peace        // 比耶
    case thumbsUp     // 比个大拇哥
    case openPalm     // 五指张开挥手
}

private struct PoseSignature {
    let smile: Float
    let eyeOpen: Float
    let wideEyes: Float
    let mouthOpen: Float
    let eyebrowLift: Float
    let gesture: Float
    let emotion: Float
    let motion: Float
    let faceCenter: CGPoint
    let faceSize: Float
}

final class SmartCaptureScorer {
    private let threshold: Float = 0.42
    private let peakThreshold: Float = 0.55
    private let requiredPassingFrames = 2
    private let cooldownFrames = 15                // ≈0.75s @ 20fps
    private let minRawFaceQuality: Float = 0.22
    private let minFaceArea: Float = 0.018
    private let noveltyMargin: Float = 0.12
    private let signatureChangeThreshold: Float = 0.22

    private var passingFrameCount = 0
    private var cooldown = 0
    private var recentScores: [SmartCaptureScore] = []
    private var recentFaceBoxes: [CGRect] = []
    private var previousMouthOpenness: Float?
    private var previousEyebrowLift: Float?
    private var previousEyeOpenness: Float?
    private var previousWideEyes: Float?
    private var previousPoseCenter: CGPoint?
    private let windowSize = 40
    private let lock = NSLock()

    // 签名状态机：记录上次拍照的pose特征，检测用户是否摆出了新pose
    private var lastCapturedSignature: PoseSignature?
    private var currentSignature: PoseSignature?
    private var stableSignature: PoseSignature?
    private var stableFrameCount = 0
    private let stableFramesRequired = 6

    func reset() {
        lock.lock(); defer { lock.unlock() }
        passingFrameCount = 0
        cooldown = 0
        recentScores.removeAll()
        recentFaceBoxes.removeAll()
        previousMouthOpenness = nil
        previousEyebrowLift = nil
        previousEyeOpenness = nil
        previousWideEyes = nil
        previousPoseCenter = nil
        stableFrameCount = 0
        // 保留 lastCapturedSignature，避免拍照后立即重复触发
    }

    /// 彻底清空签名状态（模式切换/摄像头切换时调用）
    func clearCapturedSignature() {
        lock.lock(); defer { lock.unlock() }
        lastCapturedSignature = nil
        stableSignature = nil
        stableFrameCount = 0
        currentSignature = nil
    }

    func evaluate(qualityObservations: [VNFaceObservation],
                  landmarkObservations: [VNFaceObservation],
                  bodyPoseObservations: [VNHumanBodyPoseObservation] = [],
                  handPoseObservations: [VNHumanHandPoseObservation] = []) -> SmartCaptureScore? {
        lock.lock(); defer { lock.unlock() }
        if cooldown > 0 { cooldown -= 1 }

        guard let best = qualityObservations.max(by: { rawFaceQuality($0) < rawFaceQuality($1) }) else {
            passingFrameCount = 0
            return nil
        }

        // 硬门槛：脸必须足够清晰、足够大、且大致完整处于画面内。
        let rawQuality = rawFaceQuality(best)
        let area = Float(best.boundingBox.width * best.boundingBox.height)
        let visibleArea = best.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let visibleRatio: Float = area > 0
            ? Float(visibleArea.width * visibleArea.height) / area
            : 0
        let faceUsable = rawQuality >= minRawFaceQuality && area >= minFaceArea && visibleRatio >= 0.85

        let landmarkFace = matched(for: best, in: landmarkObservations) ?? best
        let quality = normalizedQuality(rawFaceQuality(best))
        let expression = expressionMetrics(landmarkFace)
        let smile = expression.smile
        let wideEyes = expression.wideEyes
        let eyeOpen = expression.eyeOpen
        let expressionChange = expressionChangeScore(mouthOpenness: expression.mouthOpenness,
                                                     eyebrowLift: expression.eyebrowLift,
                                                     eyeOpenness: eyeOpen,
                                                     wideEyes: wideEyes)
        let emotion = clamped(max(expression.smile, expression.surprise, expression.squintJoy, expression.wideEyes * 0.88) * 0.75 + expressionChange * 0.25)
        let motion = motionScore(faceBox: best.boundingBox, bodyPoseObservations: bodyPoseObservations)
        let gesture = handGestureScore(handPoseObservations)
        let composition = compositionScore(for: best)
        let moment = clamped(emotion * 0.50 + max(motion, expressionChange) * 0.22 + gesture * 0.20 + composition * 0.08)
        let value = clamped(emotion * 0.38 + gesture * 0.22 + motion * 0.14 + composition * 0.12 + quality * 0.08 + expressionChange * 0.04 + wideEyes * 0.02)

        let score = SmartCaptureScore(value: value,
                                      captureQuality: quality,
                                      smileProbability: smile,
                                      compositionScore: composition,
                                      emotionScore: emotion,
                                      motionScore: motion,
                                      momentScore: moment,
                                      gestureScore: gesture,
                                      wideEyesScore: wideEyes,
                                      eyeOpenness: eyeOpen)
        recentScores.append(score)
        if recentScores.count > windowSize { recentScores.removeFirst() }
        recentFaceBoxes.append(best.boundingBox)
        if recentFaceBoxes.count > windowSize { recentFaceBoxes.removeFirst() }

        // 更新签名状态机：记录当前pose特征，用于检测用户是否摆出新pose
        let sig = PoseSignature(
            smile: smile,
            eyeOpen: eyeOpen,
            wideEyes: wideEyes,
            mouthOpen: expression.mouthOpenness,
            eyebrowLift: expression.eyebrowLift,
            gesture: gesture,
            emotion: emotion,
            motion: motion,
            faceCenter: CGPoint(x: best.boundingBox.midX, y: best.boundingBox.midY),
            faceSize: Float(best.boundingBox.width * best.boundingBox.height)
        )
        currentSignature = sig
        updateStableState(signature: sig)

        if faceUsable && (value > threshold || moment > threshold) {
            passingFrameCount += 1
        } else {
            passingFrameCount = max(0, passingFrameCount - 1)
        }
        if !faceUsable { passingFrameCount = 0 }

        return score
    }

    func shouldCapture(score: SmartCaptureScore?) -> Bool {
        guard let score else { return false }
        lock.lock(); defer { lock.unlock() }
        guard cooldown == 0 else { return false }

        // 硬门槛复核
        guard score.captureQuality >= 0.20, score.compositionScore >= 0.20 else { return false }

        // 计算与上次拍照的签名差异
        let sigDist: Float
        let hasLastCapture: Bool
        if let last = lastCapturedSignature, let current = currentSignature {
            sigDist = signatureDistance(current: current, previous: last)
            hasLastCapture = true
        } else {
            sigDist = 0
            hasLastCapture = false
        }

        // 传统 novelty 检测
        let baseline = recentBaseline()
        let isNovel = score.value >= baseline + noveltyMargin
            || score.momentScore >= baseline + noveltyMargin

        // 核心：新Pose触发 —— 与上次拍照的pose差异足够大，且当前值得拍
        let novelPoseTrigger = hasLastCapture
            && sigDist >= signatureChangeThreshold
            && score.emotionScore >= 0.28
            && score.value >= 0.38
            && passingFrameCount >= 1

        // 手势直接触发（阈值降低，响应更快）
        let gestureTrigger = score.gestureScore >= 0.60 && gestureNoveltyOK()

        // 情绪峰值（降低门槛）
        let emotionalPeak = score.emotionScore >= peakThreshold && score.compositionScore >= 0.25 && isNovel

        // 动作峰值
        let actionPeak = score.motionScore >= 0.50
            && (score.emotionScore >= 0.30 || score.gestureScore >= 0.40)

        // 持续高分
        let sustained = passingFrameCount >= requiredPassingFrames && isNovel && score.value >= 0.42

        let should = novelPoseTrigger || gestureTrigger || emotionalPeak || actionPeak || sustained
        if should {
            cooldown = cooldownFrames
            passingFrameCount = 0
            if let current = currentSignature {
                lastCapturedSignature = current
            }
        }
        return should
    }

    /// 手势需“出现 → 消失 → 再出现”才算一次新动作，不会一直比耶被吃成连拍。
    private func gestureNoveltyOK() -> Bool {
        let recent = recentScores.suffix(8).map(\.gestureScore)
        guard recent.contains(where: { $0 < 0.35 }) else { return false }
        return true
    }

    private func recentBaseline() -> Float {
        let window = recentScores.suffix(12).map(\.value).sorted()
        guard !window.isEmpty else { return 0 }
        return window[window.count / 2]
    }

    // MARK: - Signature state machine

    private func signatureDistance(current: PoseSignature, previous: PoseSignature) -> Float {
        var dist: Float = 0
        dist += abs(current.smile - previous.smile) * 0.25
        dist += abs(current.wideEyes - previous.wideEyes) * 0.20
        dist += abs(current.mouthOpen - previous.mouthOpen) * 0.12
        dist += abs(current.eyebrowLift - previous.eyebrowLift) * 0.08
        dist += abs(current.gesture - previous.gesture) * 0.30
        dist += abs(current.emotion - previous.emotion) * 0.15
        dist += abs(current.motion - previous.motion) * 0.08
        dist += Float(hypot(current.faceCenter.x - previous.faceCenter.x, current.faceCenter.y - previous.faceCenter.y)) * 0.30
        dist += abs(current.faceSize - previous.faceSize) * 0.15
        return clamped(dist)
    }

    private func updateStableState(signature: PoseSignature) {
        guard stableSignature != nil else {
            stableSignature = signature
            stableFrameCount = 1
            return
        }
        guard let stable = stableSignature else { return }
        let dist = signatureDistance(current: signature, previous: stable)
        if dist < 0.08 {
            stableFrameCount += 1
            if stableFrameCount >= stableFramesRequired {
                stableSignature = signature
            }
        } else {
            stableFrameCount = max(0, stableFrameCount - 2)
        }
    }

    // MARK: - Hand gesture

    private func handGestureScore(_ observations: [VNHumanHandPoseObservation]) -> Float {
        var best: Float = 0
        for hand in observations {
            if let g = classifyHand(hand) {
                let s: Float
                switch g {
                case .thumbsUp: s = 0.95
                case .peace:    s = 0.90
                case .openPalm: s = 0.78
                }
                if s > best { best = s }
            }
        }
        return best
    }

    private func classifyHand(_ hand: VNHumanHandPoseObservation) -> SmartCaptureGesture? {
        guard let wrist = try? hand.recognizedPoint(.wrist), wrist.confidence > 0.3 else { return nil }

        let thumb = fingerExtension(hand, tip: .thumbTip, mid: .thumbIP, base: .thumbCMC, wrist: wrist)
        let index = fingerExtension(hand, tip: .indexTip, mid: .indexPIP, base: .indexMCP, wrist: wrist)
        let middle = fingerExtension(hand, tip: .middleTip, mid: .middlePIP, base: .middleMCP, wrist: wrist)
        let ring = fingerExtension(hand, tip: .ringTip, mid: .ringPIP, base: .ringMCP, wrist: wrist)
        let little = fingerExtension(hand, tip: .littleTip, mid: .littlePIP, base: .littleMCP, wrist: wrist)

        // 大拇哥：拇指伸直且高于手腕，其他手指抱拳。
        if let thumb, thumb.extended,
           let thumbTip = pointIfConfident(hand, .thumbTip),
           thumbTip.y > wrist.location.y + 0.05,
           !(index?.extended ?? false),
           !(middle?.extended ?? false),
           !(ring?.extended ?? false),
           !(little?.extended ?? false) {
            return .thumbsUp
        }

        // 比耶：食指 + 中指伸直；无名指 + 小拇抱拳。
        if let index, index.extended,
           let middle, middle.extended,
           !(ring?.extended ?? false),
           !(little?.extended ?? false) {
            return .peace
        }

        // 五指张开：重要手指都伸直。
        let extendedCount = [index, middle, ring, little].compactMap { $0 }.filter { $0.extended }.count
        if extendedCount >= 3 {
            return .openPalm
        }
        return nil
    }

    private struct FingerState { let extended: Bool; let ratio: Float }

    private func fingerExtension(_ hand: VNHumanHandPoseObservation,
                                 tip: VNHumanHandPoseObservation.JointName,
                                 mid: VNHumanHandPoseObservation.JointName,
                                 base: VNHumanHandPoseObservation.JointName,
                                 wrist: VNRecognizedPoint) -> FingerState? {
        guard let tipP = pointIfConfident(hand, tip),
              let midP = pointIfConfident(hand, mid),
              let baseP = pointIfConfident(hand, base) else { return nil }
        let tipDist = hypot(tipP.x - wrist.location.x, tipP.y - wrist.location.y)
        let baseDist = hypot(baseP.x - wrist.location.x, baseP.y - wrist.location.y)
        let midDist = hypot(midP.x - wrist.location.x, midP.y - wrist.location.y)
        guard baseDist > 0.001 else { return nil }
        let ratio = Float(tipDist / baseDist)
        // 伸直手指：TIP 明显远于 MCP，且 “wrist→MCP→PIP→TIP” 距离递增。
        let extended = ratio > 1.35 && midDist > baseDist * 0.95 && tipDist > midDist
        return FingerState(extended: extended, ratio: ratio)
    }

    private func pointIfConfident(_ hand: VNHumanHandPoseObservation,
                                  _ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
        guard let p = try? hand.recognizedPoint(joint), p.confidence > 0.25 else { return nil }
        return p.location
    }

    // MARK: - Sub-scores

    private func rawFaceQuality(_ f: VNFaceObservation) -> Float {
        if let q = f.faceCaptureQuality { return q }
        return f.confidence
    }

    private func normalizedQuality(_ q: Float) -> Float {
        clamped((q - 0.2) / 0.5)
    }

    private func expressionMetrics(_ f: VNFaceObservation) -> (smile: Float, surprise: Float, squintJoy: Float, mouthOpenness: Float, eyebrowLift: Float, eyeOpen: Float, wideEyes: Float) {
        let outer = f.landmarks?.outerLips?.normalizedPoints ?? []
        let leftEye = f.landmarks?.leftEye?.normalizedPoints ?? []
        let rightEye = f.landmarks?.rightEye?.normalizedPoints ?? []
        let leftBrow = f.landmarks?.leftEyebrow?.normalizedPoints ?? []
        let rightBrow = f.landmarks?.rightEyebrow?.normalizedPoints ?? []
        let mouth = rectMetrics(points: outer)
        let smileWidth = clamped((mouth.width / max(mouth.height, 0.001) - 1.5) / 2.0)
        let smile = clamped(smileWidth * 0.50 + lipCornerLift(points: outer) * 0.50)
        let eyeOpen = (eyeOpenScore(leftEye) + eyeOpenScore(rightEye)) * 0.5
        let eyebrowLift = eyebrowLiftScore(leftEye: leftEye, rightEye: rightEye, leftBrow: leftBrow, rightBrow: rightBrow)
        let wideEyes = clamped((eyeOpen - 0.40) / 0.42)
        let surprise = clamped(mouth.height * 3.0 + eyeOpen * 0.45 + eyebrowLift * 0.35 - 0.18 + wideEyes * 0.12)
        let squintJoy = clamped(smile * 0.72 + clamped(1.0 - eyeOpen * 1.6) * 0.28)
        return (smile, surprise, squintJoy, mouth.height, eyebrowLift, eyeOpen, wideEyes)
    }

    private func expressionChangeScore(mouthOpenness: Float, eyebrowLift: Float, eyeOpenness: Float, wideEyes: Float) -> Float {
        defer {
            previousMouthOpenness = mouthOpenness
            previousEyebrowLift = eyebrowLift
            previousEyeOpenness = eyeOpenness
            previousWideEyes = wideEyes
        }
        guard let previousMouthOpenness, let previousEyebrowLift, let previousEyeOpenness, let previousWideEyes else { return 0 }
        return clamped(abs(mouthOpenness - previousMouthOpenness) * 3.5 + abs(eyebrowLift - previousEyebrowLift) * 2.0 + abs(eyeOpenness - previousEyeOpenness) * 2.5 + abs(wideEyes - previousWideEyes) * 2.0)
    }

    private func motionScore(faceBox: CGRect, bodyPoseObservations: [VNHumanBodyPoseObservation]) -> Float {
        var faceMotion: Float = 0
        if let last = recentFaceBoxes.last {
            let centerDelta = hypot(faceBox.midX - last.midX, faceBox.midY - last.midY)
            let sizeDelta = abs(faceBox.width * faceBox.height - last.width * last.height)
            faceMotion = clamped(Float(centerDelta * 5.0 + sizeDelta * 3.0))
        }

        var poseMotion: Float = 0
        if let current = poseCenter(bodyPoseObservations.first) {
            if let previousPoseCenter {
                poseMotion = clamped(Float(hypot(current.x - previousPoseCenter.x, current.y - previousPoseCenter.y) * 4.0))
            }
            previousPoseCenter = current
        }

        return clamped(max(faceMotion, poseMotion) * 0.55 + dynamicGestureScore(bodyPoseObservations.first) * 0.45)
    }

    private func dynamicGestureScore(_ observation: VNHumanBodyPoseObservation?) -> Float {
        guard let observation,
              let nose = try? observation.recognizedPoint(.nose),
              let leftWrist = try? observation.recognizedPoint(.leftWrist),
              let rightWrist = try? observation.recognizedPoint(.rightWrist),
              let leftAnkle = try? observation.recognizedPoint(.leftAnkle),
              let rightAnkle = try? observation.recognizedPoint(.rightAnkle) else { return 0 }
        var score: Float = 0
        if leftWrist.confidence > 0.25, leftWrist.location.y > nose.location.y + 0.12 { score += 0.35 }
        if rightWrist.confidence > 0.25, rightWrist.location.y > nose.location.y + 0.12 { score += 0.35 }
        if leftAnkle.confidence > 0.2, rightAnkle.confidence > 0.2, abs(leftAnkle.location.x - rightAnkle.location.x) > 0.35 {
            score += 0.25
        }
        return clamped(score)
    }

    private func poseCenter(_ observation: VNHumanBodyPoseObservation?) -> CGPoint? {
        guard let observation else { return nil }
        let joints: [VNHumanBodyPoseObservation.JointName] = [.nose, .neck, .leftShoulder, .rightShoulder, .leftHip, .rightHip]
        let points = joints.compactMap { joint -> CGPoint? in
            guard let p = try? observation.recognizedPoint(joint), p.confidence > 0.2 else { return nil }
            return p.location
        }
        guard !points.isEmpty else { return nil }
        let x = points.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(points.count)
        let y = points.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(points.count)
        return CGPoint(x: x, y: y)
    }

    private func rectMetrics(points: [CGPoint]) -> (width: Float, height: Float, midY: Float) {
        guard !points.isEmpty else { return (0, 0, 0) }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return (Float(maxX - minX), Float(maxY - minY), Float((minY + maxY) * 0.5))
    }

    private func lipCornerLift(points: [CGPoint]) -> Float {
        guard points.count >= 6 else { return 0 }
        let metrics = rectMetrics(points: points)
        guard metrics.height > 0 else { return 0 }
        let left = points.min(by: { $0.x < $1.x })?.y ?? 0
        let right = points.max(by: { $0.x < $1.x })?.y ?? 0
        let lift = Float(((left + right) * 0.5) - CGFloat(metrics.midY)) / metrics.height
        return clamped((lift + 0.08) / 0.28)
    }

    private func eyeOpenScore(_ points: [CGPoint]) -> Float {
        let metrics = rectMetrics(points: points)
        guard metrics.width > 0 else { return 0.35 }
        return clamped((metrics.height / metrics.width - 0.08) / 0.18)
    }

    private func eyebrowLiftScore(leftEye: [CGPoint], rightEye: [CGPoint], leftBrow: [CGPoint], rightBrow: [CGPoint]) -> Float {
        let le = rectMetrics(points: leftEye)
        let re = rectMetrics(points: rightEye)
        let lb = rectMetrics(points: leftBrow)
        let rb = rectMetrics(points: rightBrow)
        return clamped(((lb.midY + rb.midY) * 0.5 - (le.midY + re.midY) * 0.5 + 0.03) / 0.20)
    }

    private func compositionScore(for f: VNFaceObservation) -> Float {
        let box = f.boundingBox
        let distance = hypot(box.midX - 0.5, box.midY - 0.55)
        let centerScore = clamped(Float(1 - distance / 0.55))
        let area = Float(box.width * box.height)
        let sizeScore: Float
        if area < 0.012 { sizeScore = area / 0.012 * 0.45 }
        else if area < 0.12 { sizeScore = 0.45 + (area - 0.012) / (0.12 - 0.012) * 0.55 }
        else if area <= 0.55 { sizeScore = 1 }
        else { sizeScore = max(0.25, 1 - (area - 0.55) / 0.35) }
        return clamped(centerScore * 0.45 + sizeScore * 0.55)
    }

    private func matched(for obs: VNFaceObservation, in list: [VNFaceObservation]) -> VNFaceObservation? {
        list.min { a, b in distance(a.boundingBox, obs.boundingBox) < distance(b.boundingBox, obs.boundingBox) }
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.midX - b.midX) + abs(a.midY - b.midY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private func clamped(_ v: Float) -> Float { max(0, min(1, v)) }
}
