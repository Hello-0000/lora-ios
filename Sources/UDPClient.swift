import Foundation
import Darwin

protocol UDPClientDelegate: AnyObject {
    func udpClient(_ client: UDPClient, didReceive bytes: [UInt8], from ip: String)
}

/// BSD socket 实现的 UDP 收发（iOS 上没有 Android 的 MulticastLock，广播本身可用）
final class UDPClient {

    weak var delegate: UDPClientDelegate?

    private var socketFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.alexdtu.lora.udp.receive")
    private var running = false

    var isRunning: Bool { socketFD >= 0 }

    @discardableResult
    func start(port: UInt16) -> Bool {
        if socketFD >= 0 { return true }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            DebugLog.shared.append("UDP socket 创建失败 errno=\(errno)")
            return false
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = 0

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            DebugLog.shared.append("UDP 绑定 \(port) 失败 errno=\(errno)")
            close(fd)
            return false
        }

        socketFD = fd
        running = true
        queue.async { [weak self] in self?.receiveLoop() }
        DebugLog.shared.append("UDP 已监听 0.0.0.0:\(port)")
        return true
    }

    func stop() {
        running = false
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    func send(_ bytes: [UInt8], to host: String, port: UInt16) {
        guard socketFD >= 0 else {
            DebugLog.shared.append("UDP 未启动，丢弃发送")
            return
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)

        let sent = bytes.withUnsafeBytes { buffer -> Int in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    sendto(
                        socketFD,
                        buffer.baseAddress,
                        buffer.count,
                        0,
                        sockaddrPointer,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        if sent < 0 {
            DebugLog.shared.append("UDP 发送失败 errno=\(errno) → \(host):\(port)")
        }
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        while running {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        recvfrom(socketFD, raw.baseAddress, raw.count, 0, sockaddrPointer, &length)
                    }
                }
            }
            if !running { break }
            if count > 0 {
                delegate?.udpClient(self, didReceive: Array(buffer[0..<count]), from: Self.ipString(address.sin_addr))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private static func ipString(_ address: in_addr) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}
