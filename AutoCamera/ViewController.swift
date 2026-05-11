//
//  ViewController.swift
//  AutoCamera
//
//  Created by shiqi.jiang on 2026/5/11.
//

import UIKit

class ViewController: UIViewController {
    private let cameraController = CameraController()
    private let previewView = UIView()
    private let guidanceContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let guidanceLabel = UILabel()
    private let arrowLabel = UILabel()
    private let statusBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let statusLabel = UILabel()
    private let modeControl = UISegmentedControl(items: ["智拍", "抓拍"])

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        configureUI()
        cameraController.delegate = self
        cameraController.attachPreview(to: previewView)
        cameraController.requestAccessAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        cameraController.updatePreviewFrame(previewView.bounds)
    }

    private func configureUI() {
        view.backgroundColor = .black

        previewView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(previewView)

        guidanceContainer.translatesAutoresizingMaskIntoConstraints = false
        guidanceContainer.layer.cornerRadius = 18
        guidanceContainer.clipsToBounds = true
        guidanceContainer.alpha = 0
        view.addSubview(guidanceContainer)

        arrowLabel.translatesAutoresizingMaskIntoConstraints = false
        arrowLabel.text = "↑"
        arrowLabel.font = .systemFont(ofSize: 52, weight: .bold)
        arrowLabel.textColor = .white
        arrowLabel.textAlignment = .center
        guidanceContainer.contentView.addSubview(arrowLabel)

        guidanceLabel.translatesAutoresizingMaskIntoConstraints = false
        guidanceLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        guidanceLabel.textColor = .white
        guidanceLabel.textAlignment = .center
        guidanceLabel.numberOfLines = 0
        guidanceContainer.contentView.addSubview(guidanceLabel)

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.layer.cornerRadius = 22
        statusBar.clipsToBounds = true
        view.addSubview(statusBar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "正在准备相机..."
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusBar.contentView.addSubview(statusLabel)

        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegmentIndex = 0
        modeControl.selectedSegmentTintColor = .white
        modeControl.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        modeControl.setTitleTextAttributes([.foregroundColor: UIColor.white], for: .normal)
        modeControl.addTarget(self, action: #selector(modeDidChange), for: .valueChanged)
        view.addSubview(modeControl)

        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: view.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            modeControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            modeControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            modeControl.widthAnchor.constraint(equalToConstant: 180),

            guidanceContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            guidanceContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            guidanceContainer.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.72),
            guidanceContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),

            arrowLabel.topAnchor.constraint(equalTo: guidanceContainer.contentView.topAnchor, constant: 14),
            arrowLabel.centerXAnchor.constraint(equalTo: guidanceContainer.contentView.centerXAnchor),

            guidanceLabel.topAnchor.constraint(equalTo: arrowLabel.bottomAnchor, constant: 4),
            guidanceLabel.leadingAnchor.constraint(equalTo: guidanceContainer.contentView.leadingAnchor, constant: 18),
            guidanceLabel.trailingAnchor.constraint(equalTo: guidanceContainer.contentView.trailingAnchor, constant: -18),
            guidanceLabel.bottomAnchor.constraint(equalTo: guidanceContainer.contentView.bottomAnchor, constant: -16),

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            statusBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            statusBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),

            statusLabel.topAnchor.constraint(equalTo: statusBar.contentView.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.contentView.leadingAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(equalTo: statusBar.contentView.trailingAnchor, constant: -18),
            statusLabel.bottomAnchor.constraint(equalTo: statusBar.contentView.bottomAnchor, constant: -12)
        ])
    }

    @objc private func modeDidChange() {
        if modeControl.selectedSegmentIndex == 0 {
            cameraController.setMode(.coach)
            statusLabel.text = "智拍模式：等待导演建议"
        } else {
            cameraController.setMode(.smartCapture)
            hideGuidance()
            statusLabel.text = "抓拍模式：AI 将自动捕捉高分瞬间"
        }
    }

    private func showGuidance(_ result: PoseGuideResult) {
        guard let message = result.message else {
            hideGuidance()
            return
        }

        guidanceLabel.text = message
        switch result.direction {
        case .higherThan:
            arrowLabel.text = "↑"
        case .lowerThan:
            arrowLabel.text = "↓"
        case .leftOf:
            arrowLabel.text = "←"
        case .rightOf:
            arrowLabel.text = "→"
        case .none:
            arrowLabel.text = "•"
        }

        UIView.animate(withDuration: 0.22) {
            self.guidanceContainer.alpha = 1
        }
    }

    private func hideGuidance() {
        UIView.animate(withDuration: 0.22) {
            self.guidanceContainer.alpha = 0
        }
    }
}

extension ViewController: CameraControllerDelegate {
    func cameraController(_ controller: CameraController, didUpdateStatus text: String) {
        statusLabel.text = text
    }

    func cameraController(_ controller: CameraController, didUpdatePoseGuide result: PoseGuideResult) {
        showGuidance(result)
    }

    func cameraController(_ controller: CameraController, didUpdateCaptureScore score: SmartCaptureScore?) {
        guard modeControl.selectedSegmentIndex == 1, let score else { return }
        statusLabel.text = "抓拍评分 \(Int(score.value * 100)) · 质量 \(Int(score.captureQuality * 100)) · 微笑 \(Int(score.smileProbability * 100))"
    }

    func cameraControllerDidCapturePhoto(_ controller: CameraController) {
        let flashView = UIView(frame: view.bounds)
        flashView.backgroundColor = .white
        flashView.alpha = 0
        view.addSubview(flashView)

        UIView.animate(withDuration: 0.08, animations: {
            flashView.alpha = 0.85
        }, completion: { _ in
            UIView.animate(withDuration: 0.28, animations: {
                flashView.alpha = 0
            }, completion: { _ in
                flashView.removeFromSuperview()
            })
        })
    }

    func cameraController(_ controller: CameraController, didFail error: Error) {
        statusLabel.text = error.localizedDescription
    }
}

