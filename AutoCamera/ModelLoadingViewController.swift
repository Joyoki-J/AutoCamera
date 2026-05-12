import UIKit

final class ModelLoadingViewController: UIViewController {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let percentLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var didStartLoading = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStartLoading else { return }
        didStartLoading = true
        startLoading()
    }

    private func configureUI() {
        view.backgroundColor = .black

        let gradient = CAGradientLayer()
        gradient.colors = [UIColor.black.cgColor,
                           UIColor(red: 0.08, green: 0.10, blue: 0.18, alpha: 1).cgColor,
                           UIColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.frame = view.bounds
        view.layer.addSublayer(gradient)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "正在启动 AI 摄影导演"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "加载本地 MLX 模型，完成后自动进入相机"
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        subtitleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        view.addSubview(subtitleLabel)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = .white
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.22)
        progressView.progress = 0
        view.addSubview(progressView)

        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.text = "0%"
        percentLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        percentLabel.textAlignment = .center
        view.addSubview(percentLabel)

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重新加载", for: .normal)
        retryButton.setTitleColor(.black, for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        retryButton.backgroundColor = .white
        retryButton.layer.cornerRadius = 22
        retryButton.alpha = 0
        retryButton.addTarget(self, action: #selector(retryLoading), for: .touchUpInside)
        view.addSubview(retryButton)

        NSLayoutConstraint.activate([
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -80),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            progressView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 34),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 42),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -42),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            percentLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 14),
            percentLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            retryButton.topAnchor.constraint(equalTo: percentLabel.bottomAnchor, constant: 26),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 132),
            retryButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @objc private func retryLoading() {
        retryButton.alpha = 0
        progressView.progress = 0
        percentLabel.text = "0%"
        subtitleLabel.text = "重新加载本地 MLX 模型..."
        startLoading()
    }

    private func startLoading() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await MLXFrameProcessor.shared.preload { [weak self] fraction in
                    Task { @MainActor in
                        self?.updateProgress(fraction)
                    }
                }
                await MainActor.run {
                    self.updateProgress(1)
                    self.enterCamera()
                }
            } catch {
                await MainActor.run {
                    self.subtitleLabel.text = "模型加载失败：\(error.localizedDescription)"
                    self.retryButton.alpha = 1
                }
            }
        }
    }

    @MainActor
    private func updateProgress(_ fraction: Double) {
        let clamped = max(0, min(1, fraction))
        progressView.setProgress(Float(clamped), animated: true)
        percentLabel.text = "\(Int(clamped * 100))%"
    }

    private func enterCamera() {
        let camera = ViewController()
        camera.modalPresentationStyle = .fullScreen
        UIView.transition(with: view.window ?? view,
                          duration: 0.35,
                          options: [.transitionCrossDissolve]) {
            self.view.window?.rootViewController = camera
        }
    }
}
