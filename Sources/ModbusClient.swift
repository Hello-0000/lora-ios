import Foundation
import Darwin

/// 极简 Modbus TCP 客户端（功能码 0x03 读保持寄存器、0x10 写多个寄存器）
final class ModbusClient {

    private let host: String
    private let port: UInt16
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.alexdtu.lora.modbus")
    private var fd: Int32 = -1
    private var transactionId: UInt16 = 0

    init(host: String, port: UInt16, timeout: TimeInterval) {
        self.host = host
        self.port = port
        self.timeout = timeout
    }

    deinit {
        close()
    }

    var isConnected: Bool { fd >= 0 }

    func connect() -> String? {
        close()

        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return "socket 创建失败" }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)

        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result != 0 {
            guard errno == EINPROGRESS else {
                let code = errno
                Darwin.close(socketFD)
                return "连接失败 errno=\(code)"
            }
            var descriptor = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, Int32(timeout * 1000))
            guard ready > 0 else {
                Darwin.close(socketFD)
                return "连接超时"
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &length)
            guard socketError == 0 else {
                Darwin.close(socketFD)
                return "连接失败 errno=\(socketError)"
            }
        }

        _ = fcntl(socketFD, F_SETFL, flags)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        fd = socketFD
        return nil
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    func readHoldingRegisters(slaveId: Int, start: Int, length: Int) -> Result<[Int], String> {
        queue.sync {
            guard fd >= 0 else { return .failure("this modbus connection is broken now") }
            guard length > 0, length <= 125 else { return .failure("寄存器数量不合法") }

            transactionId &+= 1
            let pdu: [UInt8] = [
                0x03,
                UInt8((start >> 8) & 0xFF), UInt8(start & 0xFF),
                UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
            ]
            guard sendAll(mbap(transactionId: transactionId, pduLength: pdu.count, unitId: slaveId) + pdu) else {
                close()
                return .failure("发送失败")
            }
            guard let header = receive(7) else {
                close()
                return .failure("响应超时")
            }
            let responseLength = Int(header[4]) << 8 | Int(header[5])
            guard responseLength >= 2, let rest = receive(responseLength - 1) else {
                return .failure("响应不完整")
            }
            if rest[0] & 0x80 != 0 {
                return .failure("设备返回异常码 \(rest[1])")
            }
            let byteCount = Int(rest[1])
            guard rest.count >= 2 + byteCount, byteCount >= length * 2 else {
                return .failure("数据长度不足")
            }
            var values: [Int] = []
            for index in 0..<length {
                values.append(Int(rest[2 + index * 2]) << 8 | Int(rest[3 + index * 2]))
            }
            return .success(values)
        }
    }

    func writeRegisters(slaveId: Int, start: Int, values: [Int]) -> String? {
        queue.sync {
            guard fd >= 0 else { return "this modbus connection is broken now" }
            guard !values.isEmpty, values.count <= 123 else { return "寄存器数量不合法" }

            var pdu: [UInt8] = [
                0x10,
                UInt8((start >> 8) & 0xFF), UInt8(start & 0xFF),
                UInt8((values.count >> 8) & 0xFF), UInt8(values.count & 0xFF),
                UInt8((values.count * 2) & 0xFF),
            ]
            for value in values {
                pdu.append(UInt8((value >> 8) & 0xFF))
                pdu.append(UInt8(value & 0xFF))
            }

            transactionId &+= 1
            guard sendAll(mbap(transactionId: transactionId, pduLength: pdu.count, unitId: slaveId) + pdu) else {
                close()
                return "发送失败"
            }
            guard let header = receive(7) else {
                close()
                return "响应超时"
            }
            let responseLength = Int(header[4]) << 8 | Int(header[5])
            guard responseLength >= 2, let rest = receive(responseLength - 1) else {
                return "响应不完整"
            }
            if rest[0] & 0x80 != 0 {
                return "设备返回异常码 \(rest[1])"
            }
            return nil
        }
    }

    // MARK: - 底层收发

    private func mbap(transactionId: UInt16, pduLength: Int, unitId: Int) -> [UInt8] {
        [
            UInt8((transactionId >> 8) & 0xFF), UInt8(transactionId & 0xFF),
            0x00, 0x00,
            UInt8(((pduLength + 1) >> 8) & 0xFF), UInt8((pduLength + 1) & 0xFF),
            UInt8(unitId & 0xFF),
        ]
    }

    private func sendAll(_ bytes: [UInt8]) -> Bool {
        guard fd >= 0 else { return false }
        var sent = 0
        while sent < bytes.count {
            let chunk = Array(bytes[sent...])
            let written = chunk.withUnsafeBytes { buffer -> Int in
                Darwin.write(fd, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else { return false }
            sent += written
        }
        return true
    }

    private func receive(_ count: Int) -> [UInt8]? {
        guard fd >= 0, count > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            var chunk = Array(buffer[received...])
            let readBytes = chunk.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress, raw.count)
            }
            guard readBytes > 0 else { return nil }
            for index in 0..<readBytes {
                buffer[received + index] = chunk[index]
            }
            received += readBytes
        }
        return buffer
    }
}
