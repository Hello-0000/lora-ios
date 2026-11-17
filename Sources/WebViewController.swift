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
    private let statusBarBackground = UIView()
    private let bottomFiller = UIView()
    private var appBarColor: UIColor?
    private var statusBarLight = false
    private var navBarTimer: Timer?

    private var progressObservation: NSKeyValueObservation?
    private let localServer = LocalHTTPServer()

    private lazy var webView: WKWebView = {
        let controller = WKUserContentController()
        controller.add(dispatcher, name: "iOS")

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

        // 状态栏区域跟随 H5 顶栏配色，避免白条与蓝色标题栏割裂
        statusBarBackground.translatesAutoresizingMaskIntoConstraints = false
        statusBarBackground.backgroundColor = .systemBackground
        view.insertSubview(statusBarBackground, at: 0)

        // 工具栏下方的安全区填充，避免出现一条白边
        bottomFiller.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(bottomFiller, belowSubview: toolbar)

        NSLayoutConstraint.activate([
            statusBarBackground.topAnchor.constraint(equalTo: view.topAnchor),
            statusBarBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBarBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBarBackground.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),

            bottomFiller.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            bottomFiller.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomFiller.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomFiller.bottomAnchor.constraint(equalTo: view.bottomAnchor),

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
        applyUserScripts()
        DebugLog.shared.append(bundled ? "加载内置页面 \(url.absoluteString)" : "加载外部页面 \(url.absoluteString)")
        webView.load(URLRequest(url: url))
    }

    /// 每次加载前刷新注入脚本（eruda 开关需要跟随设置变化）
    private func applyUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: Self.errorCaptureScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: Self.devToolsScript(show: AppSettings.shared.showDevTools),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: Self.layoutFixScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
    }

    /// 顶栏标题过长会压住右侧徽章，这里做省略号截断（前端无源码，用注入 CSS 兜底）
    private static let layoutFixScript = """
    (function () {
        var css = [
            // 左侧网关名过长时截断，避免压住中间的徽章
            '.van-nav-bar__left { max-width: 52% !important; overflow: hidden !important; }',
            '.van-nav-bar__left .flex-div { overflow: hidden !important; ',
            'white-space: nowrap !important; text-overflow: ellipsis !important; }',
            '.van-nav-bar__content { min-width: 0 !important; overflow: hidden !important; }'
        ].join('');
        function apply() {
            if (document.getElementById('lora-layout-fix')) { return; }
            var style = document.createElement('style');
            style.id = 'lora-layout-fix';
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
        }
        apply();
        document.addEventListener('DOMContentLoaded', apply);
    })();
    """

    /// 前端自带 eruda.init()，这里按设置隐藏它的悬浮入口
    private static func devToolsScript(show: Bool) -> String {
        if show { return "window.__loraShowDevTools = true;" }
        return """
        (function () {
            window.__loraShowDevTools = false;
            function hide() {
                var nodes = document.querySelectorAll('#eruda, .eruda-container');
                for (var i = 0; i < nodes.length; i++) {
                    nodes[i].style.display = 'none';
                }
            }
            document.addEventListener('DOMContentLoaded', hide);
            try {
                new MutationObserver(hide).observe(document.documentElement, { childList: true, subtree: true });
            } catch (e) {}
            setInterval(hide, 800);
        })();
        """
    }

    private func showHint(_ text: String) {
        hintLabel.text = text + "\n\n（点此重试）"
        hintLabel.isHidden = false
        // 自动消失，避免盖在正常页面上
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.hintLabel.isHidden = true
        }
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navBarTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshChrome()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navBarTimer?.invalidate()
        navBarTimer = nil
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        statusBarLight ? .lightContent : .darkContent
    }

    /// 按当前页面是否有顶栏，统一决定状态栏 / 底部工具栏配色
    private func refreshChrome() {
        webView.evaluateJavaScript("!!document.querySelector('.van-nav-bar')") { [weak self] result, _ in
            guard let self else { return }
            let hasNavBar = (result as? Bool) ?? false
            DispatchQueue.main.async { self.applyChrome(hasNavBar: hasNavBar) }
        }
    }

    private func applyChrome(hasNavBar: Bool) {
        let color: UIColor
        if hasNavBar, let bar = appBarColor {
            color = bar
        } else {
            color = .systemBackground
        }

        statusBarBackground.backgroundColor = color
        bottomFiller.backgroundColor = color

        let foreground: UIColor = Self.isLight(color) ? .black : .white
        let appearance = UIToolbarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = color
        toolbar.standardAppearance = appearance
        toolbar.compactAppearance = appearance
        toolbar.scrollEdgeAppearance = appearance
        toolbar.tintColor = foreground
        progressView.progressTintColor = foreground
        progressView.trackTintColor = color.withAlphaComponent(0.35)

        statusBarLight = !Self.isLight(color)
        setNeedsStatusBarAppearanceUpdate()
    }

    func applyBarColor(hex: String?, bottomHex: String?) {
        if let color = Self.color(fromHex: hex) {
            appBarColor = color
        }
        if let color = Self.color(fromHex: bottomHex) {
            view.backgroundColor = color
        }
        refreshChrome()
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
        let script = "window.\(name) ? (window.\(name)(\(literal)), 'ok') : 'missing'"
        DebugLog.shared.append("回调 \(name) \(literal.prefix(160))")
        DispatchQueue.main.async { [weak self] in
            self?.webView.evaluateJavaScript(script) { result, error in
                if let error {
                    DebugLog.shared.append("回调注入失败 \(name): \(error.localizedDescription)")
                } else if let text = result as? String, text == "missing" {
                    DebugLog.shared.append("回调未注册 \(name)：H5 当前页面没有监听")
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
        refreshChrome()
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
        hintLabel.isHidden = true
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
