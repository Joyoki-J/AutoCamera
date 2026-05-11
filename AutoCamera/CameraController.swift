import AVFoundation
import Photos
import UIKit
import Vision

protocol CameraControllerDelegate: AnyObject {
    func cameraController(_ controller: CameraController, didUpdateStatus text: String)
    func cameraController(_ controller: CameraController, didUpdatePoseGuide result: PoseGuideResult)
    func cameraController(_ controller: CameraController, didUpdateCaptureScore score: SmartCaptureScore?)
    func cameraControllerDidCapturePhoto(_ controller: CameraController)
    func cameraController(_ controller: CameraController, didFail error: Error)
}

enum CameraMode {
    case coach
    case smartCapture
}

private final class CameraControllerState: @unchecked Sendable {
    var mode: CameraMode = .coach
    var lastVisionTime = CFAbsoluteTimeGetCurrent()
    var lastLowFrequencyTime = CFAbsoluteTimeGetCurrent()
    var isCapturingPhoto = false
}

final class CameraController: NSObject {
    weak var delegate: CameraControllerDelegate?
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.autocamera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.autocamera.videoOutput")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let poseGuideEngine = PoseGuideEngine()
    private let smartCaptureScorer = SmartCaptureScorer()
    private let mlxFrameProcessor = MLXFrameProcessor()
    private let notificationGenerator = UINotificationFeedbackGenerator()
    private let state = CameraControllerState()

    private var previewLayer: AVCaptureVideoPreviewLayer?

    func setMode(_ mode: CameraMode) {
        videoOutputQueue.async { [weak self] in
            guard let self else { return }
            self.state.mode = mode
            self.smartCaptureScorer.reset()
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

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1920x1080

            do {
                try self.configureInput()
                self.configureVideoOutput()
                self.configurePhotoOutput()
                self.session.commitConfiguration()
                self.session.startRunning()

                DispatchQueue.main.async {
                    self.delegate?.cameraController(self, didUpdateStatus: "相机已启动，等待导演建议")
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.delegate?.cameraController(self, didFail: error)
                }
            }
        }
    }

    private func configureInput() throws {
        guard session.inputs.isEmpty else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraControllerError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CameraControllerError.cannotAddInput }
        session.addInput(input)
    }

    private func configureVideoOutput() {
        guard !session.outputs.contains(videoOutput) else { return }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        if let connection = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                connection.videoRotationAngle = 90
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }

    private func configurePhotoOutput() {
        guard !session.outputs.contains(photoOutput) else { return }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
    }

    private func processHighFrequencyVision(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let bodyPoseRequest = VNDetectHumanBodyPoseRequest()
        let faceQualityRequest = VNDetectFaceCaptureQualityRequest()
        let faceLandmarksRequest = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])

        do {
            try handler.perform([bodyPoseRequest, faceQualityRequest, faceLandmarksRequest])

            if state.mode == .coach, let observation = bodyPoseRequest.results?.first {
                let result = poseGuideEngine.evaluate(observation)
                DispatchQueue.main.async {
                    self.delegate?.cameraController(self, didUpdatePoseGuide: result)
                    if let message = result.message {
                        self.delegate?.cameraController(self, didUpdateStatus: message)
                    }
                }
            }

            if state.mode == .smartCapture {
                let score = smartCaptureScorer.evaluate(
                    qualityObservations: faceQualityRequest.results ?? [],
                    landmarkObservations: faceLandmarksRequest.results ?? []
                )
                DispatchQueue.main.async {
                    self.delegate?.cameraController(self, didUpdateCaptureScore: score)
                    if let score {
                        self.delegate?.cameraController(self, didUpdateStatus: "抓拍评分 \(Int(score.value * 100))")
                    }
                }

                if smartCaptureScorer.shouldCapture(score: score) {
                    capturePhotoIfNeeded()
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.delegate?.cameraController(self, didFail: error)
            }
        }
    }

    private func processLowFrequencyFrame(sampleBuffer: CMSampleBuffer) {
        Task { [weak self] in
            guard let self else { return }
            if let suggestion = await self.mlxFrameProcessor.process(sampleBuffer: sampleBuffer) {
                await MainActor.run {
                    self.delegate?.cameraController(self, didUpdateStatus: suggestion)
                }
            }
        }
    }

    private func capturePhotoIfNeeded() {
        guard !state.isCapturingPhoto else { return }
        state.isCapturingPhoto = true
        smartCaptureScorer.reset()

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    private func visionInterval() -> CFTimeInterval {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            return 1.0 / 5.0
        default:
            return 1.0 / 20.0
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()

        if now - state.lastVisionTime >= visionInterval() {
            state.lastVisionTime = now
            processHighFrequencyVision(sampleBuffer: sampleBuffer)
        }

        if now - state.lastLowFrequencyTime >= 1.0 {
            state.lastLowFrequencyTime = now
            processLowFrequencyFrame(sampleBuffer: sampleBuffer)
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            state.isCapturingPhoto = false
            delegate?.cameraController(self, didFail: error)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            state.isCapturingPhoto = false
            delegate?.cameraController(self, didUpdateStatus: "照片数据生成失败")
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self else { return }
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.state.isCapturingPhoto = false
                    self.delegate?.cameraController(self, didUpdateStatus: "请允许添加照片到相册")
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    self.state.isCapturingPhoto = false
                    if let error {
                        self.delegate?.cameraController(self, didFail: error)
                    } else if success {
                        self.notificationGenerator.notificationOccurred(.success)
                        self.delegate?.cameraControllerDidCapturePhoto(self)
                        self.delegate?.cameraController(self, didUpdateStatus: "已自动抓拍并保存")
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
            return "无法访问后置摄像头"
        case .cannotAddInput:
            return "无法添加相机输入"
        }
    }
}
