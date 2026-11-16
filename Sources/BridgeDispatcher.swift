import UIKit
import WebKit

/// 接收 H5 通过 window.webkit.messageHandlers.iOS 发来的命令并分发
final class BridgeDispatcher: NSObject, WKScriptMessageHandler {

    weak var host: WebViewController?

    init(host: WebViewController) {
        self.host = host
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "iOS" else { return }
        guard let body = Self.text(from: message.body) else {
            DebugLog.shared.append("收到无法识别的消息: \(String(describing: message.body))")
            return
        }
        guard
            let data = body.data(using: .utf8),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let method = json["method"] as? String
        else {
            NSLog("[bridge] 无法解析消息: %@", body)
            DebugLog.shared.append("无法解析消息: \(body.prefix(160))")
            return
        }
        let params = json["params"] as? [String: Any] ?? [:]
        NSLog("[bridge] method=%@ params=%@", method, String(describing: params))
        DebugLog.shared.append("JS → \(method) \(String(describing: params).prefix(160))")
        handle(method: method, params: params)
    }

    /// H5 调用 postMessage({body: "..."})，WKWebView 收到的是字典而不是字符串
    private static func text(from body: Any) -> String? {
        if let text = body as? String { return text }
        guard let dictionary = body as? [String: Any] else { return nil }
        if let text = dictionary["body"] as? String { return text }
        if let data = try? JSONSerialization.data(withJSONObject: dictionary),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return nil
    }

    private func handle(method: String, params: [String: Any]) {
        switch method {
        case "openSetting":
            host?.showSettings()

        case "setAppBarColor":
            host?.applyBarColor(
                hex: params["color"] as? String,
                bottomHex: params["colorBottom"] as? String
            )

        case "vibrate":
            host?.vibrate(milliseconds: params["time"] as? Int ?? 100)

        case "checkNetwork":
            host?.sendCallback(.network, payload: ["code": 0, "msg": "OK", "data": NSNull()])

        case "clearCache":
            host?.clearCache()

        case "exitApp":
            exit(0)

        case "changeLanguage":
            if let language = params["language"] as? String {
                AppSettings.shared.language = language
            }

        case "openCamera":
            host?.showNotice("扫码功能将在 M4 阶段接入")

        case "udp":
            host?.udpBridge.handle(params)

        case "__jsError":
            DebugLog.shared.append("JS 错误: \(params["message"] ?? "") @ \(params["source"] ?? ""):\(params["line"] ?? "")")

        case "modbusTcp", "nfc":
            // M3 / M5 接入；H5 侧自带超时处理，此处保持静默
            NSLog("[bridge] %@ 尚未实现", method)
            DebugLog.shared.append("未实现: \(method)")

        default:
            NSLog("[bridge] 未处理的方法: %@", method)
        }
    }
}
