import Foundation

/// 本地配置，替代 Android 端的 SPUtil（share_config）
final class AppSettings {
    static let shared = AppSettings()

    static let defaultBaseURL = "http://iot.konnad.com:10200"

    private let defaults = UserDefaults.standard

    private enum Key {
        static let baseURL = "baseURL"
        static let language = "language"
    }

    var baseURL: String {
        get { defaults.string(forKey: Key.baseURL) ?? Self.defaultBaseURL }
        set { defaults.set(Self.normalize(newValue), forKey: Key.baseURL) }
    }

    var language: String {
        get { defaults.string(forKey: Key.language) ?? "zh" }
        set { defaults.set(newValue, forKey: Key.language) }
    }

    /// 与 Android 端一致：没写协议头时补 http://
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultBaseURL }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed
        }
        return "http://" + trimmed
    }
}
