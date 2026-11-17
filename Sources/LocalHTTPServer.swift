import Foundation
import Darwin

/// 内置 H5 的本地静态服务器：绑定 127.0.0.1 随机端口，只服务打包进 App 的 WebAssets。
/// 走真实 http 源，避免自定义 scheme 下 ES module / localStorage 被浏览器策略拦截。
final class LocalHTTPServer {

    private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.alexdtu.lora.http", attributes: .concurrent)
    private let root = Bundle.main.url(forResource: "WebAssets", withExtension: nil)

    deinit {
        stop()
    }

    @discardableResult
    func start() -> UInt16? {
        if listenFD >= 0 { return port }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            DebugLog.shared.append("本地服务 socket 创建失败 errno=\(errno)")
            return nil
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            DebugLog.shared.append("本地服务绑定失败 errno=\(errno)")
            close(fd)
            return nil
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                _ = getsockname(fd, sockaddrPointer, &length)
            }
        }
        port = UInt16(bigEndian: actual.sin_port)
        listenFD = fd

        queue.async { [weak self] in self?.acceptLoop() }
        DebugLog.shared.append("本地页面服务已启动 127.0.0.1:\(port)")
        return port
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    // MARK: - 连接处理

    private func acceptLoop() {
        while listenFD >= 0 {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.accept(listenFD, sockaddrPointer, &length)
                }
            }
            if client < 0 {
                if listenFD < 0 { return }
                continue
            }
            queue.async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }

        var request: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 16384 {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            guard count > 0 else { break }
            request += buffer[0..<count]
            if Array(request.suffix(4)) == [13, 10, 13, 10] { break }
        }

        guard let text = String(bytes: request, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n").first else {
            respond(fd, status: 400, mime: "text/plain; charset=utf-8", body: Array("bad request".utf8))
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            respond(fd, status: 400, mime: "text/plain; charset=utf-8", body: Array("bad request".utf8))
            return
        }

        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        if path == "/" || path.isEmpty { path = "/index.html" }

        DebugLog.shared.append("HTTP \(parts[0]) \(path)")

        guard let root else {
            respond(fd, status: 404, mime: "text/plain; charset=utf-8", body: Array("not found".utf8))
            return
        }

        var fileURL = root.appendingPathComponent(String(path.dropFirst()))
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            // SPA 路由回退
            fileURL = root.appendingPathComponent("index.html")
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            DebugLog.shared.append("HTTP 404 \(path)")
            respond(fd, status: 404, mime: "text/plain; charset=utf-8", body: Array("not found".utf8))
            return
        }
        DebugLog.shared.append("HTTP 200 \(path) \(data.count)B")
        respond(fd, status: 200, mime: Self.mimeType(fileURL.pathExtension), body: [UInt8](data))
    }

    private func respond(_ fd: Int32, status: Int, mime: String, body: [UInt8]) {
        var header = "HTTP/1.1 \(status == 200 ? "200 OK" : "\(status) Error")\r\n"
        header += "Content-Type: \(mime)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cache-Control: no-cache\r\n"
        header += "Connection: close\r\n\r\n"

        var payload = Array(header.utf8)
        payload += body

        var sent = 0
        while sent < payload.count {
            var chunk = Array(payload[sent...])
            let written = chunk.withUnsafeBytes { raw -> Int in
                Darwin.send(fd, raw.baseAddress, raw.count, 0)
            }
            guard written > 0 else { break }
            sent += written
        }
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
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
