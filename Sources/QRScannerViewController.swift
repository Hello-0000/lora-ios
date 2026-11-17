import UIKit
import AVFoundation

/// 扫码页（对应 Android 的 QrActivity）
final class QRScannerViewController: UIViewController {

    private let onFinish: (String?) -> Void
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var finished = false
    private var configured = false

    init(onFinish: @escaping (String?) -> Void) {
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupOverlay()
        attachPreviewIfNeeded()
        requestAccess()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard configured else { return }
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    // MARK: - 权限与相机

    private func requestAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureCamera()
                    } else {
                        self?.showCameraDenied()
                    }
                }
            }
        default:
            showCameraDenied()
        }
    }

    private func showCameraDenied() {
        let alert = UIAlertController(
            title: "无法使用相机",
            message: "请在系统设置中允许 LoRa 访问相机",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            self?.finish(nil)
        })
        alert.addAction(UIAlertAction(title: "去设置", style: .default) { [weak self] _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            self?.finish(nil)
        })
        present(alert, animated: true)
    }

    /// 提前配置并启动相机，减少 H5 弹窗的等待时间
    func prepareCamera() {
        requestAccess()
    }

    private func configureCamera() {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            finish(nil)
            return
        }

        session.beginConfiguration()
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            finish(nil)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        configured = true
        attachPreviewIfNeeded()
        startSession()
    }

    private func attachPreviewIfNeeded() {
        guard configured, isViewLoaded, previewLayer == nil else { return }
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
    }

    private func startSession() {
        guard configured, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    private func stopSession() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    // MARK: - 界面

    private func setupOverlay() {
        let hint = UILabel()
        hint.text = "将二维码放入取景框内"
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 15)
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let cancel = UIButton(type: .system)
        cancel.setTitle("取消", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 16)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
            cancel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
        ])
    }

    @objc private func cancelTapped() {
        finish(nil)
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        stopSession()
        // 先回传结果，再关闭相机页，避免 H5 还在等回调时看到自己的超时
        onFinish(value)
        dismiss(animated: true)
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue, !value.isEmpty else { return }
        DebugLog.shared.append("扫码结果 \(value.prefix(120))")
        finish(value)
    }
}
