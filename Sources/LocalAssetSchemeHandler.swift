import Foundation
import WebKit

/// 把打包进 App 的 H5 通过自定义 scheme 提供出来：
/// lora://app/index.html，资源缺失时回退到 index.html（兼容前端路由）
final class LocalAssetSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "lora"
    static let bundledURL = "lora://app/index.html"

    private let root = Bundle.main.url(forResource: "WebAssets", withExtension: nil)

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, code: 400)
            return
        }

        let path = (url.path.isEmpty || url.path == "/") ? "/index.html" : url.path
        if let root {
            let candidate = root.appendingPathComponent(String(path.dropFirst()))
            if FileManager.default.fileExists(atPath: candidate.path) {
                respond(candidate, task: urlSchemeTask)
                return
            }
            respond(root.appendingPathComponent("index.html"), task: urlSchemeTask)
            return
        }
        fail(urlSchemeTask, code: 404)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    // MARK: - 响应

    private func respond(_ fileURL: URL, task: WKURLSchemeTask) {
        guard let data = try? Data(contentsOf: fileURL),
              let url = task.request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Type": Self.mimeType(fileURL.pathExtension),
                      "Access-Control-Allow-Origin": "*",
                      "Cache-Control": "no-cache",
                  ]
              ) else {
            DebugLog.shared.append("asset 404 \(task.request.url?.path ?? "-")")
            fail(task, code: 404)
            return
        }
        DebugLog.shared.append("asset 200 \(url.path) \(data.count)B")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        task.didFailWithError(NSError(domain: "lora.assets", code: code))
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}
