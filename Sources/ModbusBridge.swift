import Foundation

/// 处理 H5 的 modbusTcp 命令，接口形状对齐原厂实现：
/// 回调 onModbusTCPCallback({"cmd": ..., "data": {"code":..., "data":..., "msg":"..."}})
final class ModbusBridge {

    weak var host: WebViewController?

    private var sessions: [String: ModbusClient] = [:]
    private var params: [String: [String: Any]] = [:]
    private let queue = DispatchQueue(label: "com.alexdtu.lora.modbus.bridge")

    init(host: WebViewController?) {
        self.host = host
    }

    func handle(_ params: [String: Any]) {
        queue.async { [weak self] in
            self?.process(params)
        }
    }

    private func process(_ request: [String: Any]) {
        guard let cmd = request["cmd"] as? String else { return }
        let data = request["data"] as? [String: Any] ?? [:]
        let ip = data["ip"] as? String ?? ""
        let port = LoRaProtocol.intValue(data["port"])
        let key = "\(ip)\(port)"

        DebugLog.shared.append("modbus \(cmd) \(key)")

        if cmd.contains("init") {
            initialize(cmd: cmd, data: data, ip: ip, port: port, key: key)
        } else if cmd.contains("read") {
            read(cmd: cmd, data: data, key: key)
        } else if cmd.contains("write") {
            write(cmd: cmd, data: data, key: key)
        } else if cmd.contains("unInit") {
            uninitialize(cmd: cmd, key: key)
        }
    }

    private func initialize(cmd: String, data: [String: Any], ip: String, port: Int, key: String) {
        if let existing = sessions[key], existing.isConnected {
            reply(cmd: cmd, code: 0, data: paramInfo(ip: ip, port: port, data: data), msg: "OK")
            return
        }

        let timeout = max(1.0, Double(LoRaProtocol.intValue(data["timeout"])) / 1000.0)
        let client = ModbusClient(host: ip, port: UInt16(clamping: port), timeout: timeout)
        if let error = client.connect() {
            DebugLog.shared.append("modbus 连接失败: \(error)")
            reply(cmd: cmd, code: -1, data: paramInfo(ip: ip, port: port, data: data), msg: error)
            return
        }

        sessions[key] = client
        params[key] = data
        DebugLog.shared.append("modbus 已连接 \(key)")
        reply(cmd: cmd, code: 0, data: paramInfo(ip: ip, port: port, data: data), msg: "OK")
    }

    private func read(cmd: String, data: [String: Any], key: String) {
        let slaveId = LoRaProtocol.intValue(data["slaveId"])
        let start = LoRaProtocol.intValue(data["start"])
        let length = LoRaProtocol.intValue(data["length"])
        let ip = data["ip"] as? String ?? ""

        guard let client = sessions[key], client.isConnected else {
            reply(cmd: cmd, code: -2, data: detailInfo(slaveId: slaveId, start: start, length: length, values: nil, ip: ip), msg: "this modbus connection is broken now")
            return
        }

        switch client.readHoldingRegisters(slaveId: slaveId, start: start, length: length) {
        case .success(let values):
            DebugLog.shared.append("modbus 读 \(start)+\(length) = \(values)")
            reply(cmd: cmd, code: 0, data: detailInfo(slaveId: slaveId, start: start, length: length, values: values, ip: ip), msg: "OK")
        case .failure(let error):
            DebugLog.shared.append("modbus 读失败: \(error.message)")
            reply(cmd: cmd, code: -1, data: detailInfo(slaveId: slaveId, start: start, length: length, values: nil, ip: ip), msg: error.message)
        }
    }

    private func write(cmd: String, data: [String: Any], key: String) {
        let slaveId = LoRaProtocol.intValue(data["slaveId"])
        let start = LoRaProtocol.intValue(data["start"])
        let ip = data["ip"] as? String ?? ""
        let values = (data["shortArray"] as? [Any])?.map { LoRaProtocol.intValue($0) } ?? []

        guard let client = sessions[key], client.isConnected else {
            reply(cmd: cmd, code: -2, data: detailInfo(slaveId: slaveId, start: start, length: 0, values: nil, ip: ip), msg: "this modbus connection is broken now")
            return
        }

        if let error = client.writeRegisters(slaveId: slaveId, start: start, values: values) {
            DebugLog.shared.append("modbus 写失败: \(error)")
            reply(cmd: cmd, code: -1, data: detailInfo(slaveId: slaveId, start: start, length: 0, values: nil, ip: ip), msg: error)
        } else {
            DebugLog.shared.append("modbus 写 \(start) = \(values)")
            reply(cmd: cmd, code: 0, data: detailInfo(slaveId: slaveId, start: start, length: 0, values: nil, ip: ip), msg: "OK")
        }
    }

    private func uninitialize(cmd: String, key: String) {
        guard let client = sessions[key] else {
            reply(cmd: cmd, code: -1, data: key, msg: "can not find modbus tcp by this ip and port")
            return
        }
        client.close()
        sessions.removeValue(forKey: key)
        let info = params.removeValue(forKey: key) ?? [:]
        reply(cmd: cmd, code: 0, data: paramInfo(ip: "", port: 0, data: info), msg: "OK")
    }

    // MARK: - 回调

    private func reply(cmd: String, code: Int, data: Any, msg: String) {
        host?.sendCallback(.modbus, payload: [
            "cmd": cmd,
            "data": ["code": code, "data": data, "msg": msg],
        ])
    }

    private func paramInfo(ip: String, port: Int, data: [String: Any]) -> [String: Any] {
        [
            "host": ip,
            "port": port,
            "encapsulated": 0,
            "keepAlive": 1,
            "timeout": LoRaProtocol.intValue(data["timeout"]),
            "retries": 2,
        ]
    }

    private func detailInfo(slaveId: Int, start: Int, length: Int, values: [Int]?, ip: String) -> [String: Any] {
        var info: [String: Any] = [
            "slaveId": slaveId,
            "start": start,
            "length": length,
            "ip": ip,
        ]
        if let values {
            info["shortArray"] = values
        }
        return info
    }
}
