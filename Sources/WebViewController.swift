import UIKit
import WebKit
import AudioToolbox

/// M1：WKWebView 外壳 + JS 桥 + 底部工具条
final class WebViewController: UIViewController {

    private lazy var dispatcher = BridgeDispatcher(host: self)
    private(set) lazy var udpBridge = UDPBridge(host: self)
    private(set) lazy var modbusBridge = ModbusBridge(host: self)
    private(set) lazy var nfcBridge = NFCBridge(host: self)

    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let toolbar = UIToolbar()
    private let hintLabel = UILabel()

    private var progressObservation: NSKeyValueObservation?

    /// 内置页面是否已跑起来（收到任意桥接消息即视为 JS 正常）
    private var bridgeAlive = false
    private var usedFallback = false
    private let localServer = LocalHTTPServer()

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
        let bundled = raw.isEmpty

        let target: URL?
        if bundled {
            if let port = localServer.start() {
                // 必须用根路径：前端是 createWebHistory，/index.html 匹配不到任何路由
                target = URL(string: "http://127.0.0.1:\(port)/")
            } else {
                target = nil
            }
        } else {
            target = URL(string: raw)
        }

        guard let url = target else {
            showHint("地址无效或内置页面启动失败")
            return
        }

        hintLabel.isHidden = true
        bridgeAlive = false
        DebugLog.shared.append(bundled ? "加载内置页面 \(url.absoluteString)" : "加载外部页面 \(url.absoluteString)")
        webView.load(URLRequest(url: url))

        // 内置页面优先：6 秒内没有任何桥接调用，判定为白屏并自动回落到厂商地址
        if bundled, !usedFallback {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, !self.bridgeAlive, !self.usedFallback else { return }
                self.usedFallback = true
                DebugLog.shared.append("内置页面 6 秒无响应，自动回落到厂商地址")
                if let fallback = URL(string: AppSettings.vendorBaseURL) {
                    self.webView.load(URLRequest(url: fallback))
                }
            }
        }
    }

    /// 收到任意有效桥接调用即说明内置页面 JS 正常
    func markBridgeActivity() {
        bridgeAlive = true
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
        DebugLog.shared.append("回调 \(name) \(json.prefix(220))")
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(script) { _, error in
                if let error {
                    DebugLog.shared.append("回调注入失败 \(name): \(error.localizedDescription)")
                }
            }
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
            let appearance = UIToolbarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = color
            toolbar.standardAppearance = appearance
            toolbar.compactAppearance = appearance
            toolbar.scrollEdgeAppearance = appearance
            let foreground: UIColor = Self.isLight(color) ? .black : .white
            toolbar.tintColor = foreground
            progressView.progressTintColor = foreground
            progressView.trackTintColor = color.withAlphaComponent(0.35)
        }
        if let color = Self.color(fromHex: bottomHex) {
            view.backgroundColor = color
        }
    }

    func vibrate(milliseconds: Int) {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        if milliseconds < 300 {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    func clearCache() {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            DispatchQueue.main.async { self?.loadBaseURL() }
        }
    }

    /// 扫码：结果以字符串形式回调（H5 内部会 JSON.parse）
    func presentScanner() {
        let scanner = QRScannerViewController { [weak self] value in
            self?.sendStringCallback(.qr, value: value ?? "")
        }
        scanner.modalPresentationStyle = .fullScreen
        present(scanner, animated: true)
    }

    /// 用 JSON 字符串字面量作为参数回调：window.onQRCallback("...")
    func sendStringCallback(_ callback: JSCallback, value: String) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let array = String(data: data, encoding: .utf8)
        else { return }
        let literal = String(array.dropFirst().dropLast())
        let name = callback.rawValue
        DebugLog.shared.append("回调 \(name) \(literal.prefix(160))")
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript("window.\(name) && window.\(name)(\(literal))") { _, error in
                if let error {
                    DebugLog.shared.append("回调注入失败 \(name): \(error.localizedDescription)")
                }
            }
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
        window.__loraErrors = [];
        function report(payload) {
            try {
                window.__loraErrors.push(String(payload.message || payload));
                if (window.__loraErrors.length > 20) { window.__loraErrors.shift(); }
            } catch (e) {}
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
        document.addEventListener('error', function (e) {
            var t = e.target;
            if (t && (t.tagName === 'SCRIPT' || t.tagName === 'LINK')) {
                report({ message: '资源加载失败: ' + String(t.src || t.href) });
            }
        }, true);
        (function () {
            var original = console.error;
            console.error = function () {
                try {
                    report({ message: 'console.error: ' + Array.prototype.join.call(arguments, ' ') });
                } catch (e) {}
                original.apply(console, arguments);
            };
        })();
        window.addEventListener('unhandledrejection', function (e) {
            report({ message: 'unhandledrejection: ' + String(e.reason) });
        });
    })();
    """

    static func isLight(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return 0.299 * red + 0.587 * green + 0.114 * blue > 0.6
    }

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
        probePageState()
    }

    /// 原生侧探针：不依赖页面自身 JS，直接读 DOM 状态
    private func probePageState() {
        let script = """
        (function () {
            var app = document.getElementById('app');
            var errors = (window.__loraErrors || []).slice(0, 5);
            var html = app ? app.innerHTML : '';
            var body = document.body ? (document.body.innerText || '') : '';
            return JSON.stringify({
                ready: document.readyState,
                title: document.title,
                appLength: app ? html.length : -1,
                appHtml: html.slice(0, 320),
                bodyText: body.slice(0, 160),
                errors: errors,
                href: location.href,
                ua: navigator.userAgent.slice(0, 140),
                bridge: !!window.webkit && !!window.webkit.messageHandlers && !!window.webkit.messageHandlers.iOS,
                storage: (function () { try { localStorage.setItem('__t', '1'); localStorage.removeItem('__t'); return true; } catch (e) { return String(e); } })()
            });
        })()
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.webView.evaluateJavaScript(script) { result, error in
                if let error {
                    DebugLog.shared.append("探针失败: \(error.localizedDescription)")
                } else if let text = result as? String {
                    DebugLog.shared.append("页面状态 \(text)")
                    if text.contains("\"appLength\":0") || text.contains("\"appLength\":-1") {
                        DebugLog.shared.append("警告：Vue 未挂载，页面为空")
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        DebugLog.shared.append("开始加载 \(webView.url?.absoluteString ?? AppSettings.shared.baseURL)")
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url {
            DebugLog.shared.append("导航 → \(url.absoluteString)")
        }
        decisionHandler(.allow)
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
