import Foundation

/// 本地配置，替代 Android 端的 SPUtil（share_config）
final class AppSettings {
    static let shared = AppSettings()

    /// 内置页面（离线可用，不经过厂商服务器）
    static let bundledBaseURL = "lora://app/index.html"

    /// 未配置时使用内置页面
    static let defaultBaseURL = bundledBaseURL

    private let defaults = UserDefaults.standard

    private init() {
        // 早期版本默认连厂商云地址，升级后自动切回内置页面（自定义地址保持不变）
        if defaults.string(forKey: Key.baseURL) == "http://iot.konnad.com:10200" {
            defaults.set(Self.bundledBaseURL, forKey: Key.baseURL)
        }
    }

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

    /// 与 Android 端一致：没写协议头时补 http://；留空则回落到内置页面
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultBaseURL }
        if trimmed.contains("://") { return trimmed }
        return "http://" + trimmed
    }
}
