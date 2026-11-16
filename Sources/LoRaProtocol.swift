import Foundation

/// LoRa 网关私有 UDP 协议（从 APK 反编译还原）
///
/// 请求报文：head(16) + cmd(4) + mac(6) + len(2,LE) + payload + crc16(2,LE)
/// 响应报文：结构相同，第 16 字节为响应码（= 请求码 + 1），负载长度位于 26..28
enum LoRaProtocol {

    // MARK: - 常量

    static let head: [UInt8] = [
        0xFA, 0x01, 0x34, 0x33, 0x21, 0x56, 0x23, 0xA5,
        0x7B, 0x29, 0xC5, 0x5D, 0x3C, 0x32, 0x12, 0xFE,
    ]

    static let listenPort: UInt16 = 21677
    static let sendPort: UInt16 = 21678
    static let broadcast = "255.255.255.255"

    enum Opcode: UInt8 {
        case search = 0x01
        case getDetail = 0x03
        case setData = 0x05
        case reset = 0x0B
        case modifyPwd = 0x1B
        case clearPwd = 0x1D

        var response: UInt8 { rawValue + 1 }
    }

    struct Response {
        let opcode: UInt8
        let payload: [UInt8]
    }

    // MARK: - 组包

    static func build(opcode: Opcode, mac: [UInt8] = [0, 0, 0, 0, 0, 0], payload: [UInt8] = []) -> [UInt8] {
        var packet = head
        packet += [opcode.rawValue, 0xFF, 0x00, 0x00]
        packet += mac
        packet += [UInt8(payload.count & 0xFF), UInt8((payload.count >> 8) & 0xFF)]
        packet += payload
        let crc = crc16Xmodem(packet)
        packet += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF)]
        return packet
    }

    /// CRC16/XMODEM：poly 0x1021，init 0x0000，不反转
    static func crc16Xmodem(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    // MARK: - 解包

    static func parse(_ data: [UInt8]) -> Response? {
        guard data.count >= 30 else { return nil }
        let length = Int(data[26]) | (Int(data[27]) << 8)
        guard length >= 0, data.count >= 28 + length + 2 else { return nil }

        let payload = Array(data[28..<(28 + length)])
        let crcField = Array(data[(28 + length)..<(30 + length)])
        let calculated = crc16Xmodem(Array(data[0..<(28 + length)]))
        guard crcField == [UInt8(calculated & 0xFF), UInt8(calculated >> 8)] else {
            DebugLog.shared.append("UDP CRC 校验失败: \(Hex.string(data))")
            return nil
        }
        return Response(opcode: data[16], payload: payload)
    }

    // MARK: - 设备搜索

    static func parseSearch(_ payload: [UInt8], udpIp: String) -> [String: Any]? {
        guard payload.count >= 36 else { return nil }
        let macBytes = Array(payload[0..<6])
        let ipBytes = Array(payload[6..<10])
        let model = Hex.string(Array(payload[10..<12]).reversed())
        let master = Array(payload[12..<14]).reversed().map { String($0) }.joined(separator: ".")
        let slave = Array(payload[14..<16]).reversed().map { String($0) }.joined(separator: ".")
        let nameBytes = trimZero(Array(payload[16..<36]))

        return [
            "mac": macBytes.map { Hex.byte($0) }.joined(separator: ":"),
            "ip": ipBytes.map { String($0) }.joined(separator: "."),
            "udpIp": udpIp,
            "model": model,
            "masterVersion": master,
            "slaveVersion": slave,
            "name": GBK.decode(nameBytes),
        ]
    }

    // MARK: - 设备详情（250 字节负载）

    static func parseDetail(_ payload: [UInt8]) -> [String: Any]? {
        guard payload.count >= 250 else { return nil }

        func int32(_ offset: Int) -> Int {
            Int(Int32(bitPattern: UInt32(payload[offset])
                | (UInt32(payload[offset + 1]) << 8)
                | (UInt32(payload[offset + 2]) << 16)
                | (UInt32(payload[offset + 3]) << 24)))
        }

        func int16(_ offset: Int) -> Int {
            Int(Int16(bitPattern: UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8)))
        }

        func ip(_ offset: Int) -> String {
            Array(payload[offset..<(offset + 4)]).map { String($0) }.joined(separator: ".")
        }

        func text(_ offset: Int, _ length: Int) -> String {
            GBK.decode(trimZero(Array(payload[offset..<(offset + length)])))
        }

        return [
            "password": int32(0),
            "ipAddress": ip(4),
            "localPort": int32(8),
            "subNetMask": ip(12),
            "gateWay": ip(16),
            "isDHCP": int32(20),
            "serverAddress": text(24, 64),
            "serverPort": int32(88),
            "dnsServerIp": ip(92),
            "ioWorkMode": int32(96),
            "isUpload": int16(100),
            "deviceId": int16(102),
            "deviceName": text(104, 20),
            "baudRate": int32(204),
            "dataBit": int32(208),
            "parity": int32(212),
            "stopBit": int32(216),
            "flowCtrl": int32(220),
            "tailTime": int32(224),
            "maxFlameLength": int32(228),
            "serialMode": int16(248),
            "originalDataStr": Hex.string(payload),
        ]
    }

    /// 写参数：以 originalDataStr 为底（无则 472 字节 0），按偏移覆盖
    static func buildDetailPayload(from info: [String: Any]) -> [UInt8] {
        let original = (info["originalDataStr"] as? String) ?? ""
        var buffer = original.isEmpty ? [UInt8](repeating: 0, count: 472) : Hex.bytes(original)
        if buffer.count < 250 {
            buffer += [UInt8](repeating: 0, count: 250 - buffer.count)
        }

        func putInt32(_ value: Int, _ offset: Int) {
            let v = UInt32(bitPattern: Int32(value))
            write(Array([
                UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF),
            ]), at: offset, into: &buffer)
        }

        func putInt16(_ value: Int, _ offset: Int) {
            let v = UInt16(bitPattern: Int16(value))
            write([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)], at: offset, into: &buffer)
        }

        func putIP(_ value: String, _ offset: Int) {
            var bytes = [UInt8](repeating: 0, count: 4)
            let parts = value.split(separator: ".")
            for (index, part) in parts.enumerated() where index < 4 {
                bytes[index] = UInt8(part) ?? 0
            }
            write(bytes, at: offset, into: &buffer)
        }

        func putText(_ value: String, _ offset: Int, _ length: Int) {
            var encoded = GBK.encode(value)
            if encoded.count > length { encoded = Array(encoded[0..<length]) }
            write(encoded, at: offset, into: &buffer)
        }

        putInt32(intValue(info["password"]), 0)
        putIP(info["ipAddress"] as? String ?? "", 4)
        putInt32(intValue(info["localPort"]), 8)
        putIP(info["subNetMask"] as? String ?? "", 12)
        putIP(info["gateWay"] as? String ?? "", 16)
        putInt32(intValue(info["isDHCP"]), 20)
        putText(info["serverAddress"] as? String ?? "", 24, 64)
        putInt32(intValue(info["serverPort"]), 88)
        putIP(info["dnsServerIp"] as? String ?? "", 92)
        putInt32(intValue(info["ioWorkMode"]), 96)
        putInt16(intValue(info["isUpload"]), 100)
        putInt16(intValue(info["deviceId"]), 102)
        putText(info["deviceName"] as? String ?? "", 104, 20)
        putInt32(intValue(info["baudRate"]), 204)
        putInt32(intValue(info["dataBit"]), 208)
        putInt32(intValue(info["parity"]), 212)
        putInt32(intValue(info["stopBit"]), 216)
        putInt32(intValue(info["flowCtrl"]), 220)
        putInt32(intValue(info["tailTime"]), 224)
        putInt32(intValue(info["maxFlameLength"]), 228)
        putInt16(intValue(info["serialMode"]), 248)

        return buffer
    }

    // MARK: - 工具

    private static func write(_ bytes: [UInt8], at offset: Int, into buffer: inout [UInt8]) {
        guard offset + bytes.count <= buffer.count else { return }
        for (index, byte) in bytes.enumerated() {
            buffer[offset + index] = byte
        }
    }

    static func intValue(_ any: Any?) -> Int {
        switch any {
        case let value as Int: return value
        case let value as Int32: return Int(value)
        case let value as Int64: return Int(value)
        case let value as Double: return Int(value)
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value) ?? 0
        default: return 0
        }
    }

    static func trimZero(_ bytes: [UInt8]) -> [UInt8] {
        if let index = bytes.firstIndex(of: 0) {
            return Array(bytes[0..<index])
        }
        return bytes
    }

    /// 结果负载：4 字节（或 2 字节）小端整数
    static func parseResult(_ payload: [UInt8]) -> Int {
        if payload.count >= 4 {
            return Int(Int32(bitPattern: UInt32(payload[0])
                | (UInt32(payload[1]) << 8)
                | (UInt32(payload[2]) << 16)
                | (UInt32(payload[3]) << 24)))
        }
        if payload.count >= 2 {
            return Int(Int16(bitPattern: UInt16(payload[0]) | (UInt16(payload[1]) << 8)))
        }
        return 0
    }
}

// MARK: - 十六进制

enum Hex {
    static func byte(_ value: UInt8) -> String {
        String(format: "%02X", value)
    }

    static func string<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { byte($0) }.joined()
    }

    static func bytes(_ text: String) -> [UInt8] {
        let chars = Array(text)
        var result: [UInt8] = []
        var index = 0
        while index + 1 < chars.count {
            if let value = UInt8(String(chars[index...index + 1]), radix: 16) {
                result.append(value)
            }
            index += 2
        }
        return result
    }
}

// MARK: - GBK

enum GBK {
    static let encoding: String.Encoding = {
        let cf = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        return String.Encoding(rawValue: cf)
    }()

    static func decode(_ bytes: [UInt8]) -> String {
        String(data: Data(bytes), encoding: encoding) ?? ""
    }

    static func encode(_ text: String) -> [UInt8] {
        Array(text.data(using: encoding) ?? Data())
    }
}
