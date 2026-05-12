//
//  ViewController.swift
//  AutoCamera
//
//  Created by shiqi.jiang on 2026/5/11.
//

import UIKit

final class ViewController: UIViewController {
    private let cameraController = CameraController()
    private let previewView = UIView()

    // 智拍：顶部"导演计划"卡片 + 中部三分线网格 + 底部姿态引导小条 + 快门 + 翻转
    private let planCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let planTitleLabel = UILabel()
    private let planBodyLabel = UILabel()
    private let compositionOverlay = CompositionOverlayView(frame: .zero)
    private let guidancePill = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let guidanceArrow = UILabel()
    private let guidanceLabel = UILabel()

    // 抓拍：评分卡（仅在抓拍模式下显示）
    private let scoreCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let scoreLabel = UILabel()
    private let scoreDetailLabel = UILabel()

    // 通用：状态栏 / 模式切换 / 快门 / 翻转
    private let statusBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let statusLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["智拍", "抓拍"])
    private let shutterButton = UIButton(type: .custom)
    private let flipButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)   // 智拍专属：重新开始

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        cameraController.delegate = self
        cameraController.attachPreview(to: previewView)
        cameraController.requestAccessAndStart()
        cameraController.setMode(.coach)
        updateModeUI(coach: true)
        // 兜底：确保所有交互按钮在预览图层之上。
        [modeControl, flipButton, resetButton, shutterButton, planCard, guidancePill, scoreCard, statusBar]
            .forEach { view.bringSubviewToFront($0) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        cameraController.updatePreviewFrame(previewView.bounds)
        compositionOverlay.frame = previewView.bounds
    }

    private func configureUI() {
        view.backgroundColor = .black

        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)

        compositionOverlay.isUserInteractionEnabled = false
        compositionOverlay.alpha = 0
        previewView.addSubview(compositionOverlay)

        // 顶部"导演计划"卡片
        planCard.translatesAutoresizingMaskIntoConstraints = false
        planCard.layer.cornerRadius = 16
        planCard.clipsToBounds = true
        planCard.alpha = 0
        view.addSubview(planCard)

        planTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        planTitleLabel.text = "🎬 导演计划"
        planTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        planTitleLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        planCard.contentView.addSubview(planTitleLabel)

        planBodyLabel.translatesAutoresizingMaskIntoConstraints = false
        planBodyLabel.font = .systemFont(ofSize: 15, weight: .medium)
        planBodyLabel.textColor = .white
        planBodyLabel.numberOfLines = 0
        planCard.contentView.addSubview(planBodyLabel)

        // 底部小条姿态引导（不再遮挡预览中心）
        guidancePill.translatesAutoresizingMaskIntoConstraints = false
        guidancePill.layer.cornerRadius = 22
        guidancePill.clipsToBounds = true
        guidancePill.alpha = 0
        view.addSubview(guidancePill)

        guidanceArrow.translatesAutoresizingMaskIntoConstraints = false
        guidanceArrow.font = .systemFont(ofSize: 26, weight: .bold)
        guidanceArrow.textColor = .white
        guidanceArrow.textAlignment = .center
        guidancePill.contentView.addSubview(guidanceArrow)

        guidanceLabel.translatesAutoresizingMaskIntoConstraints = false
        guidanceLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        guidanceLabel.textColor = .white
        guidancePill.contentView.addSubview(guidanceLabel)

        // 抓拍：评分卡
        scoreCard.translatesAutoresizingMaskIntoConstraints = false
        scoreCard.layer.cornerRadius = 18
        scoreCard.clipsToBounds = true
        scoreCard.alpha = 0
        view.addSubview(scoreCard)

        scoreLabel.translatesAutoresizingMaskIntoConstraints = false
        scoreLabel.font = .systemFont(ofSize: 26, weight: .bold)
        scoreLabel.textColor = .white
        scoreLabel.textAlignment = .center
        scoreCard.contentView.addSubview(scoreLabel)

        scoreDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        scoreDetailLabel.font = .systemFont(ofSize: 12, weight: .medium)
        scoreDetailLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        scoreDetailLabel.textAlignment = .center
        scoreDetailLabel.numberOfLines = 2
        scoreCard.contentView.addSubview(scoreDetailLabel)

        // 状态栏
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.layer.cornerRadius = 20
        statusBar.clipsToBounds = true
        view.addSubview(statusBar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "正在准备相机..."
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusBar.contentView.addSubview(statusLabel)

        // 模式控件
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegmentIndex = 0
        modeControl.selectedSegmentTintColor = .white
        modeControl.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        modeControl.addTarget(self, action: #selector(modeDidChange), for: .valueChanged)
        view.addSubview(modeControl)

        // 翻转按钮（两个模式都可见）
        flipButton.translatesAutoresizingMaskIntoConstraints = false
        flipButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath.camera.fill"), for: .normal)
        flipButton.tintColor = .white
        flipButton.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        flipButton.layer.cornerRadius = 22
        flipButton.addTarget(self, action: #selector(flipCamera), for: .touchUpInside)
        view.addSubview(flipButton)

        // 重新开始按钮（只在智拍模式可见）
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        resetButton.setImage(UIImage(systemName: "arrow.counterclockwise.circle.fill"), for: .normal)
        resetButton.tintColor = .white
        resetButton.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        resetButton.layer.cornerRadius = 22
        resetButton.addTarget(self, action: #selector(restartCoach), for: .touchUpInside)
        view.addSubview(resetButton)

        // 快门
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.layer.cornerRadius = 36
        shutterButton.backgroundColor = .white
        shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        shutterButton.layer.borderWidth = 4
        shutterButton.addTarget(self, action: #selector(shutterPressed), for: .touchUpInside)
        view.addSubview(shutterButton)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            modeControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            modeControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 180),

            flipButton.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            flipButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            flipButton.widthAnchor.constraint(equalToConstant: 44),
            flipButton.heightAnchor.constraint(equalToConstant: 44),

            resetButton.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            resetButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            resetButton.widthAnchor.constraint(equalToConstant: 44),
            resetButton.heightAnchor.constraint(equalToConstant: 44),

            planCard.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 12),
            planCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            planCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            planTitleLabel.topAnchor.constraint(equalTo: planCard.contentView.topAnchor, constant: 8),
            planTitleLabel.leadingAnchor.constraint(equalTo: planCard.contentView.leadingAnchor, constant: 14),
            planTitleLabel.trailingAnchor.constraint(equalTo: planCard.contentView.trailingAnchor, constant: -14),

            planBodyLabel.topAnchor.constraint(equalTo: planTitleLabel.bottomAnchor, constant: 2),
            planBodyLabel.leadingAnchor.constraint(equalTo: planCard.contentView.leadingAnchor, constant: 14),
            planBodyLabel.trailingAnchor.constraint(equalTo: planCard.contentView.trailingAnchor, constant: -14),
            planBodyLabel.bottomAnchor.constraint(equalTo: planCard.contentView.bottomAnchor, constant: -10),

            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            shutterButton.widthAnchor.constraint(equalToConstant: 72),
            shutterButton.heightAnchor.constraint(equalToConstant: 72),

            guidancePill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guidancePill.bottomAnchor.constraint(equalTo: shutterButton.topAnchor, constant: -14),
            guidancePill.heightAnchor.constraint(equalToConstant: 44),
            guidancePill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85),

            guidanceArrow.leadingAnchor.constraint(equalTo: guidancePill.contentView.leadingAnchor, constant: 14),
            guidanceArrow.centerYAnchor.constraint(equalTo: guidancePill.contentView.centerYAnchor),
            guidanceArrow.widthAnchor.constraint(equalToConstant: 26),

            guidanceLabel.leadingAnchor.constraint(equalTo: guidanceArrow.trailingAnchor, constant: 10),
            guidanceLabel.trailingAnchor.constraint(equalTo: guidancePill.contentView.trailingAnchor, constant: -16),
            guidanceLabel.centerYAnchor.constraint(equalTo: guidancePill.contentView.centerYAnchor),

            scoreCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scoreCard.bottomAnchor.constraint(equalTo: shutterButton.topAnchor, constant: -14),
            scoreCard.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),

            scoreLabel.topAnchor.constraint(equalTo: scoreCard.contentView.topAnchor, constant: 10),
            scoreLabel.leadingAnchor.constraint(equalTo: scoreCard.contentView.leadingAnchor, constant: 18),
            scoreLabel.trailingAnchor.constraint(equalTo: scoreCard.contentView.trailingAnchor, constant: -18),

            scoreDetailLabel.topAnchor.constraint(equalTo: scoreLabel.bottomAnchor, constant: 2),
            scoreDetailLabel.leadingAnchor.constraint(equalTo: scoreCard.contentView.leadingAnchor, constant: 18),
            scoreDetailLabel.trailingAnchor.constraint(equalTo: scoreCard.contentView.trailingAnchor, constant: -18),
            scoreDetailLabel.bottomAnchor.constraint(equalTo: scoreCard.contentView.bottomAnchor, constant: -10),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            statusBar.bottomAnchor.constraint(equalTo: shutterButton.topAnchor, constant: -90),

            statusLabel.topAnchor.constraint(equalTo: statusBar.contentView.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.contentView.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: statusBar.contentView.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: statusBar.contentView.bottomAnchor, constant: -8)
        ])
    }

    @objc private func modeDidChange() {
        let coach = modeControl.selectedSegmentIndex == 0
        cameraController.setMode(coach ? .coach : .smartCapture)
        updateModeUI(coach: coach)
    }

    @objc private func flipCamera() {
        cameraController.switchCamera()
    }

    @objc private func restartCoach() {
        cameraController.restartCoachSession()
    }

    @objc private func shutterPressed() {
        cameraController.capturePhotoManually()
        let anim = CABasicAnimation(keyPath: "transform.scale")
        anim.fromValue = 0.85
        anim.toValue = 1.0
        anim.duration = 0.2
        shutterButton.layer.add(anim, forKey: "press")
    }

    /// 切换模式时彻底隐藏对方模式的 UI，防止视觉/逻辑串扰。
    private func updateModeUI(coach: Bool) {
        UIView.animate(withDuration: 0.2) {
            self.resetButton.alpha = coach ? 1 : 0
            if coach {
                self.scoreCard.alpha = 0
            } else {
                self.planCard.alpha = 0
                self.guidancePill.alpha = 0
                self.compositionOverlay.alpha = 0
            }
        }
    }

    private func showGuidance(_ result: PoseGuideResult) {
        guard let message = result.message else {
            UIView.animate(withDuration: 0.2) { self.guidancePill.alpha = 0 }
            return
        }
        guidanceLabel.text = message
        switch result.direction {
        case .higherThan: guidanceArrow.text = "↑"
        case .lowerThan:  guidanceArrow.text = "↓"
        case .leftOf:     guidanceArrow.text = "←"
        case .rightOf:    guidanceArrow.text = "→"
        case .none:       guidanceArrow.text = "•"
        }
        UIView.animate(withDuration: 0.2) { self.guidancePill.alpha = 1 }
    }
}

extension ViewController: CameraControllerDelegate {
    func cameraController(_ controller: CameraController, didUpdateStatus text: String) {
        // 文案必须在主线程匹配当前选中的模式，避免跨模式残留信息。
        let coach = modeControl.selectedSegmentIndex == 0
        // 明显是对方模式才会出现的文案直接丢弃。
        if !coach && (text.contains("导演") || text.contains("构图")) { return }
        if coach && text.contains("抓拍") { return }
        statusLabel.text = text
    }

    func cameraController(_ controller: CameraController, didUpdateDirectorPlan plan: DirectorPlan?) {
        // 智拍专属 UI；其他模式直接忽略
        guard modeControl.selectedSegmentIndex == 0 else { return }
        guard let plan else {
            UIView.animate(withDuration: 0.2) {
                self.planCard.alpha = 0
                self.compositionOverlay.alpha = 0
            }
            return
        }
        planTitleLabel.text = plan.subject == .portrait ? "🎬 人物导演" : "🏞 风景导演"
        planBodyLabel.text = plan.summary
        UIView.animate(withDuration: 0.2) {
            self.planCard.alpha = 1
            self.compositionOverlay.alpha = (plan.subject == .scene) ? 1 : 0
        }
    }

    func cameraController(_ controller: CameraController, didUpdatePoseGuide result: PoseGuideResult) {
        guard modeControl.selectedSegmentIndex == 0 else { return }
        showGuidance(result)
    }

    func cameraController(_ controller: CameraController, didUpdateCaptureScore score: SmartCaptureScore?) {
        // 抓拍专属 UI
        guard modeControl.selectedSegmentIndex == 1 else { return }
        guard let score else {
            scoreLabel.text = "未检测到人脸"
            scoreDetailLabel.text = "请让人脸进入画面，靠近一点"
            UIView.animate(withDuration: 0.2) { self.scoreCard.alpha = 1 }
            return
        }
        scoreLabel.text = "抓拍评分 \(Int(score.value * 100))"
        scoreDetailLabel.text = String(format: "情绪 %d · 手势 %d · 动作 %d · 构图 %d",
                                       Int(score.emotionScore * 100),
                                       Int(score.gestureScore * 100),
                                       Int(score.motionScore * 100),
                                       Int(score.compositionScore * 100))
        UIView.animate(withDuration: 0.2) { self.scoreCard.alpha = 1 }
    }

    func cameraControllerDidCapturePhoto(_ controller: CameraController) {
        let flashView = UIView(frame: view.bounds)
        flashView.backgroundColor = .white
        flashView.alpha = 0
        view.addSubview(flashView)
        UIView.animate(withDuration: 0.08, animations: { flashView.alpha = 0.85 }) { _ in
            UIView.animate(withDuration: 0.28, animations: { flashView.alpha = 0 }) { _ in
                flashView.removeFromSuperview()
            }
        }
    }

    func cameraController(_ controller: CameraController, didFail error: Error) {
        statusLabel.text = error.localizedDescription
    }
}

/// 智拍·风景模式下的"三分线"取景辅助。
final class CompositionOverlayView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        let w = rect.width / 3, h = rect.height / 3
        for i in 1...2 {
            ctx.move(to: CGPoint(x: w * CGFloat(i), y: 0))
            ctx.addLine(to: CGPoint(x: w * CGFloat(i), y: rect.height))
            ctx.move(to: CGPoint(x: 0, y: h * CGFloat(i)))
            ctx.addLine(to: CGPoint(x: rect.width, y: h * CGFloat(i)))
        }
        ctx.strokePath()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }
}

