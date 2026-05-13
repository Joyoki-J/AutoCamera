import AVFoundation
import CoreMedia
import CoreVideo
import Photos
import UIKit
import Vision

protocol CameraControllerDelegate: AnyObject {
    func cameraController(_ controller: CameraController, didUpdateStatus text: String)
    func cameraController(_ controller: CameraController, didUpdateDirectorPlan plan: DirectorPlan?)
    func cameraController(_ controller: CameraController, didUpdatePoseGuide result: PoseGuideResult)
    func cameraController(_ controller: CameraController, didUpdateCaptureScore score: SmartCaptureScore?)
    func cameraControllerDidCapturePhoto(_ controller: CameraController)
    func cameraController(_ controller: CameraController, didFail error: Error)
}

enum CameraMode { case coach, smartCapture }
enum CameraFacing { case back, front }

final class CameraController: NSObject {
    weak var delegate: CameraControllerDelegate?
    let session = AVCaptureSession()

    // 串行队列：会话配置 / Vision 调度 / 视觉计算分别独立，互不阻塞。
    private let sessionQueue = DispatchQueue(label: "com.autocamera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.autocamera.video")
    private let visionQueue = DispatchQueue(label: "com.autocamera.vision", qos: .userInitiated)

    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()

    // 两个模式各自一套引擎，运行期不交叉调用。
    private let poseGuideEngine = PoseGuideEngine()
    private let smartCaptureScorer = SmartCaptureScorer()
    private let mlxFrameProcessor = MLXFrameProcessor.shared
    private let notificationGenerator = UINotificationFeedbackGenerator()

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentInput: AVCaptureDeviceInput?
    private(set) var facing: CameraFacing = .back

    // 以下字段只在 `videoOutputQueue` 上读写。
    private var mode: CameraMode = .coach
    private var lastVisionTime: CFAbsoluteTime = 0
    private var lastLowFrequencyTime: CFAbsoluteTime = 0
    private var isVisionBusy = false
    private var isMLXBusy = false
    private var hasPersonRecently = false
    private var currentMLXTask: Task<Void, Never>?
    private var isCapturingPhoto = false

    // MARK: - Mode & Facing

    func setMode(_ newMode: CameraMode) {
        videoOutputQueue.async { [weak self] in
            guard let self else { return }
            self.mode = newMode
            self.resetPipelineState()
            DispatchQueue.main.async {
                self.delegate?.cameraController(self, didUpdateDirectorPlan: nil)
                self.delegate?.cameraController(self, didUpdateCaptureScore: nil)
                self.delegate?.cameraController(self, didUpdatePoseGuide: PoseGuideResult(isSatisfied: true, message: nil, direction: nil))
                self.delegate?.cameraController(self, didUpdateStatus: newMode == .coach
                                                ? "智拍：AI 导演正在思考构图"
                                                : "抓拍：正在寻找高分瞬间")
            }
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.facing = (self.facing == .back) ? .front : .back
            self.reconfigureInput()
            self.videoOutputQueue.async { self.resetPipelineState() }
            DispatchQueue.main.async {
                self.delegate?.cameraController(self, didUpdateStatus: self.facing == .front ? "已切换至前置摄像头" : "已切换至后置摄像头")
            }
        }
    }

    /// 手动快门（智拍模式必备，抓拍模式也可用作兜底）。
    func capturePhotoManually() {
        sessionQueue.async { [weak self] in
            self?.performPhotoCapture(auto: false)
        }
    }

    /// 智拍"重新开始"：清空导演计划与姿态历史，立即触发下一轮 MLX 推理。
    func restartCoachSession() {
        videoOutputQueue.async { [weak self] in
            guard let self else { return }
            self.resetPipelineState()
            DispatchQueue.main.async {
                self.delegate?.cameraController(self, didUpdateDirectorPlan: nil)
                self.delegate?.cameraController(self, didUpdatePoseGuide: PoseGuideResult(isSatisfied: true, message: nil, direction: nil))
                self.delegate?.cameraController(self, didUpdateStatus: "智拍：已重新开始，AI 正在重新构图")
            }
        }
    }

    func attachPreview(to view: UIView) {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    func updatePreviewFrame(_ frame: CGRect) {
        previewLayer?.frame = frame
    }

    func requestAccessAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if granted {
                self.configureAndStart()
            } else {
                DispatchQueue.main.async {
                    self.delegate?.cameraController(self, didUpdateStatus: "请在系统设置中允许相机权限")
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - Session configuration

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1920x1080
            do {
                try self.reconfigureInputLocked()
                self.configureVideoOutput()
                self.configurePhotoOutput()
                self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.delegate?.cameraController(self, didUpdateStatus: "相机已启动")
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.delegate?.cameraController(self, didFail: error) }
            }
        }
    }

    private func reconfigureInput() {
        session.beginConfiguration()
        do { try reconfigureInputLocked() } catch {
            DispatchQueue.main.async { self.delegate?.cameraController(self, didFail: error) }
        }
        session.commitConfiguration()
    }

    private func reconfigureInputLocked() throws {
        if let existing = currentInput { session.removeInput(existing) }
        let position: AVCaptureDevice.Position = (facing == .back) ? .back : .front
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CameraControllerError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CameraControllerError.cannotAddInput }
        session.addInput(input)
        currentInput = input
        configureVideoConnection()
    }

    private func configureVideoOutput() {
        guard !session.outputs.contains(videoOutput) else { return }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        configureVideoConnection()
    }

    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if #available(iOS 17.0, *) {
            connection.videoRotationAngle = 90
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = (facing == .front)
        }
    }

    private func configurePhotoOutput() {
        guard !session.outputs.contains(photoOutput) else { return }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
    }

    private func resetPipelineState() {
        lastVisionTime = 0
        lastLowFrequencyTime = 0
        isVisionBusy = false
        isMLXBusy = false
        hasPersonRecently = false
        currentMLXTask?.cancel()
        currentMLXTask = nil
        poseGuideEngine.reset()
        smartCaptureScorer.reset()
        smartCaptureScorer.clearCapturedSignature()
    }

    /// 文档热降频要求：`.serious / .critical` 时 Vision 强制 5fps。
    private func visionInterval() -> CFTimeInterval {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return 1.0 / 5.0
        default: return 1.0 / 20.0
        }
    }

    // MARK: - Coach pipeline (智拍：人体姿态 + MLX 导演 + 风景显著性对焦)

    private func processCoachFrame(pixelBuffer: CVPixelBuffer) {
        guard !isVisionBusy else { return }
        isVisionBusy = true
        let frontCam = (facing == .front)
        visionQueue.async { [weak self] in
            guard let self else { return }
            defer { self.videoOutputQueue.async { self.isVisionBusy = false } }
            let bodyPose = VNDetectHumanBodyPoseRequest()
            let faceLandmarks = VNDetectFaceLandmarksRequest()
            let faceQuality = VNDetectFaceCaptureQualityRequest()
            let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
            let orientation: CGImagePropertyOrientation = frontCam ? .leftMirrored : .right
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([bodyPose, faceLandmarks, faceQuality, saliency])
                let personObs = bodyPose.results?.first
                let faceObs = faceLandmarks.results?.first
                let hasPerson = (personObs?.confidence ?? 0) > 0.3 || (faceObs?.confidence ?? 0) > 0.3
                self.videoOutputQueue.async { self.hasPersonRecently = hasPerson }

                // 人物模式：人脸检测 + 姿态引导 + 自动对焦人脸
                if hasPerson {
                    // 自动对焦到人脸中心
                    if let face = faceObs {
                        let faceBox = face.boundingBox
                        let faceCenter = CGPoint(x: faceBox.midX, y: faceBox.midY)
                        self.applyFocus(normalizedPoint: faceCenter)
                        // 人脸质量反馈
                        let quality = face.faceCaptureQuality ?? face.confidence
                        let area = Float(faceBox.width * faceBox.height)
                        var qualityMsg = ""
                        if quality < 0.25 {
                            qualityMsg = "人脸有些模糊，请保持稳定"
                        } else if area < 0.025 {
                            qualityMsg = "人脸太小，请靠近一点"
                        } else if area > 0.45 {
                            qualityMsg = "人脸太近，请稍微后退"
                        }
                        if !qualityMsg.isEmpty {
                            DispatchQueue.main.async {
                                self.delegate?.cameraController(self, didUpdateStatus: qualityMsg)
                            }
                        }
                    }
                    // 姿态引导
                    if let obs = personObs {
                        let result = self.poseGuideEngine.evaluate(obs)
                        DispatchQueue.main.async {
                            self.delegate?.cameraController(self, didUpdatePoseGuide: result)
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.delegate?.cameraController(self, didUpdatePoseGuide: PoseGuideResult(isSatisfied: true, message: nil, direction: nil))
                        }
                    }
                } else {
                    // 风景模式：使用注意力显著性自动对焦兴趣主体
                    if let salient = saliency.results?.first?.salientObjects?.first {
                        let box = salient.boundingBox
                        self.applyFocus(normalizedPoint: CGPoint(x: box.midX, y: box.midY))
                    }
                    DispatchQueue.main.async {
                        self.delegate?.cameraController(self, didUpdatePoseGuide: PoseGuideResult(isSatisfied: true, message: nil, direction: nil))
                    }
                }
            } catch {
                DispatchQueue.main.async { self.delegate?.cameraController(self, didFail: error) }
            }
        }
    }

    private func processCoachLowFrequency(pixelBuffer: CVPixelBuffer) {
        guard !isMLXBusy else { return }
        guard let copy = CameraController.copyPixelBuffer(pixelBuffer) else { return }
        isMLXBusy = true
        let hasPerson = hasPersonRecently
        currentMLXTask = Task { [weak self] in
            guard let self else { return }
            defer { self.videoOutputQueue.async { self.isMLXBusy = false } }
            let plan = await self.mlxFrameProcessor.process(pixelBuffer: copy, hasPerson: hasPerson)
            guard !Task.isCancelled, let plan else { return }
            // 异步执行期间用户可能已切换到抓拍模式，必须再校验一次，否则会污染抓拍 UI。
            var stillCoach = false
            self.videoOutputQueue.sync { stillCoach = (self.mode == .coach) }
            guard stillCoach else { return }
            // 把导演计划落地：动态姿态约束 / 变焦与对焦 / 构图模式
            self.poseGuideEngine.setConstraints(plan.poseConstraints)
            if let zoom = plan.suggestedZoom { self.applyZoom(factor: zoom) }
            if let focus = plan.suggestedFocusPoint { self.applyFocus(normalizedPoint: focus) }
            await MainActor.run {
                self.delegate?.cameraController(self, didUpdateDirectorPlan: plan)
                self.delegate?.cameraController(self, didUpdateStatus: plan.summary)
            }
        }
    }

    // MARK: - Smart-capture pipeline (抓拍：表情情绪 + 动作瞬间评分)

    private func processSmartCaptureFrame(pixelBuffer: CVPixelBuffer) {
        guard !isVisionBusy else { return }
        guard !isCapturingPhoto else { return }
        isVisionBusy = true
        let frontCam = (facing == .front)
        visionQueue.async { [weak self] in
            guard let self else { return }
            defer { self.videoOutputQueue.async { self.isVisionBusy = false } }
            let quality = VNDetectFaceCaptureQualityRequest()
            let landmarks = VNDetectFaceLandmarksRequest()
            let bodyPose = VNDetectHumanBodyPoseRequest()
            let handPose = VNDetectHumanHandPoseRequest()
            handPose.maximumHandCount = 2
            let orientation: CGImagePropertyOrientation = frontCam ? .leftMirrored : .right
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([quality, landmarks, bodyPose, handPose])
                let score = self.smartCaptureScorer.evaluate(
                    qualityObservations: quality.results ?? [],
                    landmarkObservations: landmarks.results ?? [],
                    bodyPoseObservations: bodyPose.results ?? [],
                    handPoseObservations: handPose.results ?? []
                )
                DispatchQueue.main.async {
                    self.delegate?.cameraController(self, didUpdateCaptureScore: score)
                }
                if self.smartCaptureScorer.shouldCapture(score: score) {
                    self.sessionQueue.async { self.performPhotoCapture(auto: true) }
                }
            } catch {
                DispatchQueue.main.async { self.delegate?.cameraController(self, didFail: error) }
            }
        }
    }

    // MARK: - Camera adjustments (智拍风景模式自动调参)

    private func applyZoom(factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let device = self?.currentInput?.device else { return }
            let clamped = max(1.0, min(device.activeFormat.videoMaxZoomFactor, factor))
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: clamped, withRate: 2.0)
                device.unlockForConfiguration()
            } catch { /* ignore */ }
        }
    }

    private func applyFocus(normalizedPoint: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let device = self?.currentInput?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = normalizedPoint
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = normalizedPoint
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch { /* ignore */ }
        }
    }

    // MARK: - Photo capture

    private func performPhotoCapture(auto: Bool) {
        videoOutputQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isCapturingPhoto else { return }
            self.isCapturingPhoto = true
            self.smartCaptureScorer.reset()
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            // 安全兜底：5 秒后若 delegate 仍未回调，强制解锁，避免出现"评分不再更新"的死锁。
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.videoOutputQueue.async {
                    guard let self else { return }
                    if self.isCapturingPhoto { self.isCapturingPhoto = false }
                }
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
            DispatchQueue.main.async {
                self.delegate?.cameraController(self, didUpdateStatus: auto ? "捕捉到高分瞬间，正在保存..." : "正在拍照...")
            }
        }
    }

    /// CMSampleBuffer 在 delegate 返回后会被回收，跨线程使用前必须拷贝 PixelBuffer。
    private static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var dest: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &dest)
        guard status == kCVReturnSuccess, let dest else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        if let srcBase = CVPixelBufferGetBaseAddress(source),
           let dstBase = CVPixelBufferGetBaseAddress(dest) {
            let srcStride = CVPixelBufferGetBytesPerRow(source)
            let dstStride = CVPixelBufferGetBytesPerRow(dest)
            let rowBytes = min(srcStride, dstStride)
            for y in 0..<height {
                memcpy(dstBase.advanced(by: y * dstStride),
                       srcBase.advanced(by: y * srcStride),
                       rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(dest, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
        return dest
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastVisionTime >= visionInterval() else { return }
        lastVisionTime = now
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 两个模式的处理流水线完全独立，不共享任何 Vision 请求或状态。
        switch mode {
        case .coach:
            processCoachFrame(pixelBuffer: pixelBuffer)
            if now - lastLowFrequencyTime >= 1.0 {
                lastLowFrequencyTime = now
                processCoachLowFrequency(pixelBuffer: pixelBuffer)
            }
        case .smartCapture:
            processSmartCaptureFrame(pixelBuffer: pixelBuffer)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        // 无论成功失败，先释放拍照标志位，避免后续帧因此停摆。
        videoOutputQueue.async { [weak self] in self?.isCapturingPhoto = false }

        if let error {
            DispatchQueue.main.async { self.delegate?.cameraController(self, didFail: error) }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async { self.delegate?.cameraController(self, didUpdateStatus: "照片数据生成失败") }
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.delegate?.cameraController(self, didUpdateStatus: "请允许添加照片到相册")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if let error {
                        self.delegate?.cameraController(self, didFail: error)
                    } else if success {
                        self.notificationGenerator.notificationOccurred(.success)
                        self.delegate?.cameraControllerDidCapturePhoto(self)
                        self.delegate?.cameraController(self, didUpdateStatus: "已保存到相册")
                    }
                }
            }
        }
    }
}

enum CameraControllerError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "无法访问所选摄像头"
        case .cannotAddInput:
            return "无法添加相机输入"
        }
    }
}
