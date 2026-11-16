import Foundation

/// 把 H5 的 udp 命令翻译成私有协议报文，并把响应回传给 H5
final class UDPBridge: UDPClientDelegate {

    weak var host: WebViewController?

    private let client = UDPClient()
    private var started = false

    init(host: WebViewController?) {
        self.host = host
        client.delegate = self
    }

    func start() {
        guard !started else { return }
        started = client.start(port: LoRaProtocol.listenPort)
    }

    func handle(_ params: [String: Any]) {
        start()
        guard let cmd = params["cmd"] as? String else { return }
        let data = params["data"] as? [String: Any] ?? [:]
        DebugLog.shared.append("H5 → udp \(cmd)")

        let mac = Self.macBytes(data["mac"] as? String)
        let deviceIP = data["ip"] as? String

        if cmd.contains("search") {
            send(LoRaProtocol.build(opcode: .search), to: LoRaProtocol.broadcast)
        } else if cmd.contains("getDetail") {
            send(LoRaProtocol.build(opcode: .getDetail, mac: mac), to: LoRaProtocol.broadcast)
        } else if cmd.contains("setDetail") {
            let info = data["detailInfo"] as? [String: Any] ?? [:]
            let payload = LoRaProtocol.buildDetailPayload(from: info)
            send(LoRaProtocol.build(opcode: .setData, mac: mac, payload: payload), to: LoRaProtocol.broadcast)
        } else if cmd.contains("reset") {
            send(LoRaProtocol.build(opcode: .reset, mac: mac), to: deviceIP ?? LoRaProtocol.broadcast)
        } else if cmd.contains("modifyPwd") {
            let old = Hex.bytes(data["oldPassword"] as? String ?? "")
            let new = Hex.bytes(data["newPassword"] as? String ?? "")
            send(LoRaProtocol.build(opcode: .modifyPwd, mac: mac, payload: old + new), to: deviceIP ?? LoRaProtocol.broadcast)
        } else if cmd.contains("clearPwd") {
            send(LoRaProtocol.build(opcode: .clearPwd, mac: mac, payload: [0, 0, 0, 0]), to: deviceIP ?? LoRaProtocol.broadcast)
        } else {
            DebugLog.shared.append("未支持的 udp 命令: \(cmd)")
        }
    }

    private func send(_ packet: [UInt8], to host: String) {
        DebugLog.shared.append("UDP → \(host):\(LoRaProtocol.sendPort) \(Hex.string(packet))")
        client.send(packet, to: host, port: LoRaProtocol.sendPort)
    }

    // MARK: - UDPClientDelegate

    func udpClient(_ client: UDPClient, didReceive bytes: [UInt8], from ip: String) {
        DebugLog.shared.append("UDP ← \(ip) \(Hex.string(bytes))")
        guard let response = LoRaProtocol.parse(bytes) else { return }

        if response.opcode == LoRaProtocol.Opcode.search.response {
            guard let device = LoRaProtocol.parseSearch(response.payload, udpIp: ip) else { return }
            let model = device["model"] as? String ?? ""
            guard ["0275", "0276", "0277"].contains(model) else {
                DebugLog.shared.append("忽略非网关型号: \(model)")
                return
            }
            host?.sendCallback(.udp, payload: ["cmd": "search", "data": device])

        } else if response.opcode == LoRaProtocol.Opcode.getDetail.response {
            guard let detail = LoRaProtocol.parseDetail(response.payload) else { return }
            host?.sendCallback(.udp, payload: ["cmd": "getDetail", "data": detail])

        } else if response.opcode == LoRaProtocol.Opcode.setData.response {
            host?.sendCallback(.udp, payload: ["cmd": "setDetail", "data": LoRaProtocol.parseResult(response.payload)])

        } else if response.opcode == LoRaProtocol.Opcode.reset.response {
            host?.sendCallback(.udp, payload: ["cmd": "reset", "data": LoRaProtocol.parseResult(response.payload)])

        } else if response.opcode == LoRaProtocol.Opcode.modifyPwd.response {
            host?.sendCallback(.udp, payload: ["cmd": "modifyPwd", "data": LoRaProtocol.parseResult(response.payload)])

        } else if response.opcode == LoRaProtocol.Opcode.clearPwd.response {
            host?.sendCallback(.udp, payload: ["cmd": "clearPwd", "data": LoRaProtocol.parseResult(response.payload)])

        } else {
            DebugLog.shared.append("未知响应码: \(String(format: "%02X", response.opcode))")
        }
    }

    private static func macBytes(_ text: String?) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 6)
        guard let text else { return result }
        let parts = text.split(separator: ":")
        for (index, part) in parts.enumerated() where index < 6 {
            result[index] = UInt8(part, radix: 16) ?? 0
        }
        return result
    }
}
