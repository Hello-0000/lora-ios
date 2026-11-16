import UIKit
import WebKit
import AudioToolbox

/// M1：WKWebView 外壳 + JS 桥 + 底部工具条
final class WebViewController: UIViewController {

    private lazy var dispatcher = BridgeDispatcher(host: self)
    private(set) lazy var udpBridge = UDPBridge(host: self)

    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let toolbar = UIToolbar()
    private let hintLabel = UILabel()

    private var progressObservation: NSKeyValueObservation?

    private lazy var webView: WKWebView = {
        let controller = WKUserContentController()
        controller.add(dispatcher, name: "iOS")
        controller.addUserScript(WKUserScript(
            source: Self.errorCaptureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        return webView
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
        observeProgress()
        udpBridge.start()
        loadBaseURL()
    }

    // MARK: - UI

    private func setupUI() {
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = .systemBlue
        progressView.isHidden = true

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.font = .systemFont(ofSize: 14)
        hintLabel.textColor = .secondaryLabel
        hintLabel.isHidden = true
        let tap = UITapGestureRecognizer(target: self, action: #selector(loadBaseURL))
        hintLabel.isUserInteractionEnabled = true
        hintLabel.addGestureRecognizer(tap)

        let backItem = UIBarButtonItem(title: "返回", style: .plain, target: self, action: #selector(handleBack))
        let settingsItem = UIBarButtonItem(title: "设置", style: .plain, target: self, action: #selector(showSettings))
        let reloadItem = UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(loadBaseURL))
        toolbar.items = [backItem, .flexibleSpace(), settingsItem, .flexibleSpace(), reloadItem]
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(webView)
        view.addSubview(progressView)
        view.addSubview(toolbar)
        view.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            progressView.topAnchor.constraint(equalTo: webView.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            hintLabel.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }

    private func observeProgress() {
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            let progress = Float(webView.estimatedProgress)
            self?.progressView.progress = progress
            self?.progressView.isHidden = progress >= 1.0
        }
    }

    // MARK: - 加载

    @objc func loadBaseURL() {
        let raw = AppSettings.shared.baseURL
        guard let url = URL(string: raw) else {
            showHint("地址无效：\(raw)")
            return
        }
        hintLabel.isHidden = true
        webView.load(URLRequest(url: url))
    }

    private func showHint(_ text: String) {
        hintLabel.text = text + "\n\n（点此重试）"
        hintLabel.isHidden = false
    }

    // MARK: - 桥接对外能力

    func sendCallback(_ callback: JSCallback, payload: [String: Any]) {
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else { return }

        let name = callback.rawValue
        let script = "window.\(name) && window.\(name)(\(json))"
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    @objc func showSettings() {
        let controller = SettingsViewController(
            onSave: { [weak self] in self?.loadBaseURL() },
            onSelfCheck: { [weak self] in self?.udpBridge.selfCheck() }
        )
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    func applyBarColor(hex: String?, bottomHex: String?) {
        if let color = Self.color(fromHex: hex) {
            toolbar.barTintColor = color
            toolbar.backgroundColor = color
            progressView.progressTintColor = color
        }
        if let color = Self.color(fromHex: bottomHex) {
            view.backgroundColor = color
        }
    }

    func vibrate(milliseconds: Int) {
        if milliseconds >= 300 {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    func clearCache() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            DispatchQueue.main.async { self?.loadBaseURL() }
        }
    }

    func showNotice(_ text: String) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    @objc private func handleBack() {
        webView.evaluateJavaScript("typeof window.onAndroidBackBtn === 'function'") { [weak self] result, _ in
            guard let self else { return }
            if (result as? Bool) == true {
                self.webView.evaluateJavaScript("window.onAndroidBackBtn()", completionHandler: nil)
            } else if self.webView.canGoBack {
                self.webView.goBack()
            }
        }
    }

    // MARK: - 工具

    /// 捕获 H5 的 JS 运行时错误：iOS 15 的 JavaScriptCore 较老，语法不兼容时页面会静默失败
    private static let errorCaptureScript = """
    (function () {
        function report(payload) {
            try {
                window.webkit.messageHandlers.iOS.postMessage({
                    body: JSON.stringify({ method: '__jsError', params: payload })
                });
            } catch (e) {}
        }
        window.addEventListener('error', function (e) {
            report({
                message: String(e.message),
                source: String(e.filename || ''),
                line: e.lineno || 0
            });
        });
        window.addEventListener('unhandledrejection', function (e) {
            report({ message: 'unhandledrejection: ' + String(e.reason) });
        });
    })();
    """

    static func color(fromHex hex: String?) -> UIColor? {
        guard let raw = hex?.trimmingCharacters(in: .whitespaces), raw.hasPrefix("#") else { return nil }
        var digits = String(raw.dropFirst())
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        var value: UInt64 = 0
        guard Scanner(string: digits).scanHexInt64(&value) else { return nil }

        switch digits.count {
        case 6:
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255.0,
                green: CGFloat((value >> 8) & 0xFF) / 255.0,
                blue: CGFloat(value & 0xFF) / 255.0,
                alpha: 1
            )
        case 8:
            // Android 端为 AARRGGBB
            return UIColor(
                red: CGFloat((value >> 16) & 0xFF) / 255.0,
                green: CGFloat((value >> 8) & 0xFF) / 255.0,
                blue: CGFloat(value & 0xFF) / 255.0,
                alpha: CGFloat((value >> 24) & 0xFF) / 255.0
            )
        default:
            return nil
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressView.isHidden = true
        hintLabel.isHidden = true
        DebugLog.shared.append("页面加载完成 \(webView.url?.absoluteString ?? "")")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DebugLog.shared.append("开始加载 \(webView.url?.absoluteString ?? AppSettings.shared.baseURL)")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else { return }
        showHint("无法打开 \(AppSettings.shared.baseURL)\n\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else { return }
        NSLog("[webview] 加载失败: %@", error.localizedDescription)
    }
}
