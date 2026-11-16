import Foundation
import Darwin

/// 读取当前 Wi-Fi 的 IPv4 信息，用于同网段扫描
enum NetworkInfo {

    struct IPv4Info {
        let interface: String
        let address: String
        let netmask: String
        let gateway: String
        let hosts: [String]
    }

    static func wifiIPv4() -> IPv4Info? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            pointer = current.pointee.ifa_next

            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            guard name == "en0" else { continue }

            let ip = hostString(address)
            let mask = current.pointee.ifa_netmask.map(hostString) ?? "255.255.255.0"
            guard !ip.isEmpty, !mask.isEmpty else { continue }

            return IPv4Info(
                interface: name,
                address: ip,
                netmask: mask,
                gateway: gatewayAddress(ip: ip) ?? "",
                hosts: sweepHosts(ip: ip)
            )
        }
        return nil
    }

    private static func hostString(_ pointer: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            pointer,
            socklen_t(pointer.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        return result == 0 ? String(cString: host) : ""
    }

    /// 同网段其余主机（按 /24 处理，最多 254 个）
    private static func sweepHosts(ip: String) -> [String] {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return [] }
        return (1...254)
            .map { "\(parts[0]).\(parts[1]).\(parts[2]).\($0)" }
            .filter { $0 != ip }
    }

    private static func gatewayAddress(ip: String) -> String? {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2]).1"
    }
}
