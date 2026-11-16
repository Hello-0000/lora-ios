import Foundation

/// 把 H5 的 udp 命令翻译成私有协议报文，并把响应回传给 H5
///
/// iOS 上向 255.255.255.255 广播需要苹果审批的 multicast 权限，TrollStore 装的应用拿不到，
/// 所以搜索改为「同网段 254 个地址逐个单播」，不依赖任何特殊权限。
final class UDPBridge: UDPClientDelegate {

    weak var host: WebViewController?

    private let client = UDPClient()
    private let sweepQueue = DispatchQueue(label: "com.alexdtu.lora.sweep")
    private var started = false
    private var sweeping = false

    /// mac（大写冒号格式）→ 设备上报的 IP，用于后续单播
    private var knownIPs: [String: String] = [:]

    init(host: WebViewController?) {
        self.host = host
        client.delegate = self
    }

    func start() {
        guard !started else { return }
        started = client.start(port: LoRaProtocol.listenPort)
        logNetwork()
    }

    func handle(_ params: [String: Any]) {
        start()
        guard let cmd = params["cmd"] as? String else { return }
        let data = params["data"] as? [String: Any] ?? [:]
        DebugLog.shared.append("H5 → udp \(cmd)")

        let mac = Self.macBytes(data["mac"] as? String)
        let macKey = Self.macKey(data["mac"] as? String)
        let deviceIP = (data["ip"] as? String) ?? knownIPs[macKey] ?? LoRaProtocol.broadcast

        if cmd.contains("search") {
            search()
        } else if cmd.contains("getDetail") {
            dispatch(LoRaProtocol.build(opcode: .getDetail, mac: mac), preferred: knownIPs[macKey])
        } else if cmd.contains("setDetail") {
            let info = data["detailInfo"] as? [String: Any] ?? [:]
            let payload = LoRaProtocol.buildDetailPayload(from: info)
            dispatch(LoRaProtocol.build(opcode: .setData, mac: mac, payload: payload), preferred: knownIPs[macKey])
        } else if cmd.contains("reset") {
            send(LoRaProtocol.build(opcode: .reset, mac: mac), to: deviceIP)
        } else if cmd.contains("modifyPwd") {
            let old = Hex.bytes(data["oldPassword"] as? String ?? "")
            let new = Hex.bytes(data["newPassword"] as? String ?? "")
            send(LoRaProtocol.build(opcode: .modifyPwd, mac: mac, payload: old + new), to: deviceIP)
        } else if cmd.contains("clearPwd") {
            send(LoRaProtocol.build(opcode: .clearPwd, mac: mac, payload: [0, 0, 0, 0]), to: deviceIP)
        } else {
            DebugLog.shared.append("未支持的 udp 命令: \(cmd)")
        }
    }

    // MARK: - 发送

    /// 优先发给已知 IP，否则广播 + 网段扫描
    private func dispatch(_ packet: [UInt8], preferred ip: String?) {
        if let ip {
            send(packet, to: ip)
        } else {
            send(packet, to: LoRaProtocol.broadcast)
            sweep(packet)
        }
    }

    private func search() {
        let packet = LoRaProtocol.build(opcode: .search)
        send(packet, to: LoRaProtocol.broadcast)
        sweep(packet)
    }

    /// 同网段逐地址单播，分两轮覆盖丢包
    private func sweep(_ packet: [UInt8]) {
        guard let info = NetworkInfo.wifiIPv4() else {
            DebugLog.shared.append("未发现 Wi-Fi IPv4，无法扫描（是否没连 Wi-Fi？）")
            return
        }
        guard !sweeping else { return }
        sweeping = true
        DebugLog.shared.append("扫描 \(info.address) 网段，共 \(info.hosts.count) 个地址")

        sweepQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<2 {
                for ip in info.hosts {
                    self.client.send(packet, to: ip, port: LoRaProtocol.sendPort)
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
            self.sweeping = false
        }
    }

    private func send(_ packet: [UInt8], to host: String) {
        guard !host.isEmpty else { return }
        DebugLog.shared.append("UDP → \(host):\(LoRaProtocol.sendPort) \(Hex.string(packet))")
        client.send(packet, to: host, port: LoRaProtocol.sendPort)
    }

    /// 自检：打印本机网络信息，并探测网关与设备默认地址是否可达
    func selfCheck() {
        start()
        logNetwork()
        guard let info = NetworkInfo.wifiIPv4() else {
            DebugLog.shared.append("自检：手机没有 Wi-Fi IPv4 地址")
            return
        }
        send(LoRaProtocol.build(opcode: .search), to: info.gateway)
        httpProbe("http://\(info.gateway)/")
        httpProbe("http://192.168.4.1/")
    }

    private func httpProbe(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        DebugLog.shared.append("HTTP 探测 \(urlString)")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                DebugLog.shared.append("HTTP 不通 \(urlString): \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse {
                DebugLog.shared.append("HTTP 可达 \(urlString) 状态 \(http.statusCode)")
            } else {
                DebugLog.shared.append("HTTP 无响应 \(urlString)")
            }
        }.resume()
    }

    private func logNetwork() {
        guard let info = NetworkInfo.wifiIPv4() else {
            DebugLog.shared.append("Wi-Fi 未连接（无 en0 IPv4 地址）")
            return
        }
        DebugLog.shared.append("Wi-Fi \(info.address)/\(info.netmask) 网关 \(info.gateway)")
    }

    // MARK: - UDPClientDelegate

    func udpClient(_ client: UDPClient, didReceive bytes: [UInt8], from ip: String) {
        DebugLog.shared.append("UDP ← \(ip) \(Hex.string(bytes))")
        guard let response = LoRaProtocol.parse(bytes) else { return }

        if response.opcode == LoRaProtocol.Opcode.search.response {
            guard let device = LoRaProtocol.parseSearch(response.payload, udpIp: ip) else { return }
            if let mac = device["mac"] as? String {
                knownIPs[mac.uppercased()] = ip
            }
            DebugLog.shared.append("搜索响应 payload(\(response.payload.count)): \(Self.dump(response.payload))")
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

    // MARK: - 工具

    private static func macBytes(_ text: String?) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 6)
        guard let text else { return result }
        for (index, part) in text.split(separator: ":").enumerated() where index < 6 {
            result[index] = UInt8(part, radix: 16) ?? 0
        }
        return result
    }

    private static func macKey(_ text: String?) -> String {
        (text ?? "").uppercased()
    }

    /// 带偏移量的字节转储，便于对齐协议字段
    private static func dump(_ bytes: [UInt8]) -> String {
        stride(from: 0, to: min(bytes.count, 48), by: 8).map { start in
            let end = min(start + 8, bytes.count)
            return "\(start):" + bytes[start..<end].map { Hex.byte($0) }.joined(separator: " ")
        }.joined(separator: " | ")
    }
}
