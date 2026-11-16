import Foundation

/// 简易内存日志，用于真机排查（设置页可查看）
final class DebugLog {
    static let shared = DebugLog()

    private let queue = DispatchQueue(label: "com.alexdtu.lora.log")
    private let limit = 500
    private var storage: [String] = []

    private init() {}

    func append(_ text: String) {
        queue.async {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            self.storage.append("[\(formatter.string(from: Date()))] \(text)")
            if self.storage.count > self.limit {
                self.storage.removeFirst(self.storage.count - self.limit)
            }
        }
    }

    func snapshot() -> String {
        queue.sync { storage.joined(separator: "\n") }
    }

    func clear() {
        queue.sync { storage.removeAll() }
    }
}
