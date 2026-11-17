import Foundation
import CoreNFC

/// NFC 终端交互（对应安卓的 Protocol_Reader + Ntag_Commands）
///
/// 安卓用 NfcA.transceive 裸发 NTAG 指令；iOS 映射到 NFCMiFareTag.sendMiFareCommand。
/// 卡内是 NTAG 5 系列：Session 寄存器在 0xEC~0xED，SRAM 在 0xF0~0xFF。
final class NFCBridge: NSObject {

    weak var host: WebViewController?

    private let lock = NSLock()
    private let workQueue = DispatchQueue(label: "com.alexdtu.lora.nfc")
    private var session: NFCTagReaderSession?
    private var tag: NFCMiFareTag?
    private var currentSector: UInt8 = 0

    init(host: WebViewController?) {
        self.host = host
    }

    // MARK: - 对外入口

    func handle(_ params: [String: Any]) {
        guard let cmd = params["cmd"] as? String else { return }
        let data = params["data"] as? [String: Any] ?? [:]
        DebugLog.shared.append("nfc \(cmd)")

        if cmd.contains("openNfc") {
            open()
            return
        }
        if cmd.contains("closeNfc") {
            close()
            return
        }

        workQueue.async { [weak self] in
            self?.perform(cmd: cmd, data: data)
        }
    }

    // MARK: - 会话

    private func open() {
        guard NFCTagReaderSession.readingAvailable else {
            DebugLog.shared.append("NFC 不可用（缺少 entitlement 或设备不支持）")
            reply(cmd: "openNfc", code: -4, data: "", msg: "NFC unavailable")
            return
        }
        guard session == nil else { return }

        guard let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: nil) else {
            DebugLog.shared.append("NFC 会话创建失败")
            reply(cmd: "openNfc", code: -4, data: "", msg: "NFC session unavailable")
            return
        }
        session.alertMessage = "请将 iPhone 靠近终端"
        session.begin()
        self.session = session
        DebugLog.shared.append("NFC 会话已启动")

        // 卡片已经在场时立即回报，等价于安卓 onNewIntent 的 openNfc 回调
        if currentTag() != nil {
            reply(cmd: "openNfc", code: 0, data: "", msg: "OK")
        }
    }

    private func close() {
        session?.invalidate()
        session = nil
        setTag(nil)
        DebugLog.shared.append("NFC 会话已关闭")
    }

    private func setTag(_ value: NFCMiFareTag?) {
        lock.lock()
        tag = value
        lock.unlock()
    }

    private func currentTag() -> NFCMiFareTag? {
        lock.lock()
        defer { lock.unlock() }
        return tag
    }

    /// 等卡片出现（最多 timeout 秒）
    private func waitForTag(_ timeout: TimeInterval) -> NFCMiFareTag? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let tag = currentTag() { return tag }
            usleep(50_000)
        }
        return nil
    }

    // MARK: - 指令分发

    private func perform(cmd: String, data: [String: Any]) {
        guard waitForTag(8) != nil else {
            reply(cmd: cmd, code: -4, data: "", msg: "NFC Tag is null too!")
            return
        }

        do {
            var result: [UInt8]
            if cmd.contains("getBaseInfo") {
                result = try deviceInfo(type: 1)
            } else if cmd.contains("getDetailInfo") {
                result = try deviceInfo(type: 2)
            } else if cmd.contains("setGatewayId") {
                result = try setGatewayId(Hex.bytes(data["gatewayId"] as? String ?? ""))
            } else if cmd.contains("setOpenStatus") {
                result = try setStatus(command: 4, value: UInt8(LoRaProtocol.intValue(data["isOn"]) & 0xFF))
            } else if cmd.contains("setSoundLightStatus") {
                result = try setStatus(command: 5, value: UInt8(LoRaProtocol.intValue(data["isOn"]) & 0xFF))
            } else if cmd.contains("dataInteraction") {
                result = try interact(Hex.bytes(data["hexString"] as? String ?? ""))
            } else {
                reply(cmd: cmd, code: -4, data: "", msg: "unknown nfc command")
                return
            }
            reply(cmd: cmd, code: 0, data: Hex.string(result), msg: "OK")
        } catch let error as NFCProtocolError {
            reply(cmd: cmd, code: error.code, data: "", msg: error.message)
        } catch {
            reply(cmd: cmd, code: -4, data: "", msg: error.localizedDescription)
        }
    }

    // MARK: - 具体操作

    private func deviceInfo(type: UInt8) throws -> [UInt8] {
        try ensureReady()
        var payload = [UInt8](repeating: 0, count: 64)
        payload[60] = type
        payload[61] = 1
        try fastWrite(payload, from: 0xF0, to: 0xFF)
        try waitForSRamReady()
        return try fastRead(from: 0xFC, to: 0xFF)
    }

    private func setGatewayId(_ gatewayId: [UInt8]) throws -> [UInt8] {
        try ensureReady()
        var payload = [UInt8](repeating: 0, count: 56)
        payload += gatewayId
        payload += [3, 1, 0, 0]
        try fastWrite(payload, from: 0xF0, to: 0xFF)
        try waitForSRamReady()
        return try fastRead(from: 0xFF, to: 0xFF)
    }

    private func setStatus(command: UInt8, value: UInt8) throws -> [UInt8] {
        try ensureReady()
        var payload = [UInt8](repeating: 0, count: 64)
        payload[60] = command
        payload[61] = 1
        payload[62] = value
        try fastWrite(payload, from: 0xF0, to: 0xFF)
        try waitForSRamReady()
        return try fastRead(from: 0xFF, to: 0xFF)
    }

    private func interact(_ bytes: [UInt8]) throws -> [UInt8] {
        try ensureReady()
        try fastWrite(bytes, from: 0xF0, to: 0xFF)
        try waitForSRamReady()
        return try fastRead(from: 0xF0, to: 0xFF)
    }

    // MARK: - 状态检查（对应 checkIfPassThroughOn / RFLock / SRamReady）

    private func ensureReady() throws {
        try sectorSelect(0)
        if !(try passThroughOn()) {
            try wait(until: { try self.passThroughOn() })
            guard try passThroughOn() else {
                throw NFCProtocolError(code: -1, message: "直通模式没有打开")
            }
        }
        if !(try rfLockOn()) {
            try wait(until: { try self.rfLockOn() })
            guard try rfLockOn() else {
                throw NFCProtocolError(code: -2, message: "RFLock 标志位没有打开")
            }
        }
    }

    private func waitForSRamReady() throws {
        if try sRamReady() { return }
        try wait(until: { try self.sRamReady() })
        guard try sRamReady() else {
            throw NFCProtocolError(code: -3, message: "SRamReady 标志位没有打开")
        }
    }

    private func wait(until check: () throws -> Bool) throws {
        // 对应安卓的 1000 次 × 1ms
        for _ in 0..<100 {
            if try check() { return }
            usleep(10_000)
        }
    }

    private func registers() throws -> [UInt8] {
        try sectorSelect(0)
        return try fastRead(from: 0xEC, to: 0xED)
    }

    private func passThroughOn() throws -> Bool {
        let values = try registers()
        guard values.count >= 1 else { return false }
        let nc = values[0]
        return (nc & 0x40) != 0 && (nc & 0x01) != 0
    }

    private func rfLockOn() throws -> Bool {
        let values = try registers()
        guard values.count >= 7 else { return false }
        return (values[6] & 0x20) != 0
    }

    private func sRamReady() throws -> Bool {
        let values = try registers()
        guard values.count >= 7 else { return false }
        return (values[6] & 0x08) != 0
    }

    // MARK: - NTAG 指令

    private func sectorSelect(_ sector: UInt8) throws {
        if currentSector == sector { return }
        _ = try transceive([0xC2, 0xFF])
        _ = try transceive([sector, 0x00, 0x00, 0x00])
        currentSector = sector
    }

    private func fastRead(from: UInt8, to: UInt8) throws -> [UInt8] {
        try transceive([0x3A, from, to])
    }

    private func fastWrite(_ payload: [UInt8], from: UInt8, to: UInt8) throws {
        var command: [UInt8] = [0xA6, from, to]
        command += payload
        _ = try transceive(command)
    }

    private func transceive(_ bytes: [UInt8]) throws -> [UInt8] {
        guard let tag = currentTag() else {
            throw NFCProtocolError(code: -4, message: "NFC Tag is null too!")
        }

        var output: [UInt8] = []
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)

        tag.sendMiFareCommand(commandPacket: Data(bytes)) { data, error in
            output = [UInt8](data)
            failure = error
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            throw NFCProtocolError(code: -4, message: "NFC 响应超时")
        }
        if let failure {
            throw NFCProtocolError(code: -4, message: failure.localizedDescription)
        }
        return output
    }

    // MARK: - 回调

    private func reply(cmd: String, code: Int, data: Any, msg: String) {
        DebugLog.shared.append("nfc \(cmd) → code=\(code) \(msg)")
        host?.sendCallback(.nfc, payload: [
            "cmd": cmd,
            "data": ["code": code, "data": data, "msg": msg],
        ])
    }
}

struct NFCProtocolError: Error {
    let code: Int
    let message: String
}

extension NFCBridge: NFCTagReaderSessionDelegate {

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        DebugLog.shared.append("NFC 会话已激活，等待贴卡")
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        DebugLog.shared.append("NFC 会话结束: \(error.localizedDescription)")
        self.session = nil
        setTag(nil)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first else {
            session.restartPolling()
            return
        }
        guard case let .miFare(mifare) = first else {
            session.invalidate(errorMessage: "不支持的卡片类型")
            return
        }

        session.connect(to: first) { [weak self] error in
            guard let self else { return }
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                return
            }
            self.setTag(mifare)
            self.currentSector = 0
            session.alertMessage = "已连接，正在读取"
            DebugLog.shared.append("NFC 已连接 \(mifare.identifier.map { String(format: "%02X", $0) }.joined())")
            // 对应安卓 onNewIntent 里的 openNfc 成功回调：H5 收到后才开始下发指令
            self.reply(cmd: "openNfc", code: 0, data: "", msg: "OK")
        }
    }
}
