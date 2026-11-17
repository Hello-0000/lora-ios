import Foundation

/// 本地配置，替代 Android 端的 SPUtil（share_config）
final class AppSettings {
    static let shared = AppSettings()

    /// 厂商在线页面（需要外网）
    static let vendorBaseURL = "http://iot.konnad.com:10200"

    private let defaults = UserDefaults.standard

    private init() {
        // 早期版本默认连厂商云地址，升级后改为「空值 = 内置页面」，需要在线可手动切换
        if defaults.string(forKey: Key.baseURL) == Self.vendorBaseURL {
            defaults.set("", forKey: Key.baseURL)
        }
    }

    private enum Key {
        static let baseURL = "baseURL"
        static let language = "language"
        static let devTools = "showDevTools"
    }

    /// 是否显示前端自带的 eruda 调试面板（默认关闭）
    var showDevTools: Bool {
        get { defaults.bool(forKey: Key.devTools) }
        set { defaults.set(newValue, forKey: Key.devTools) }
    }

    /// 空字符串表示使用内置页面
    var baseURL: String {
        get { defaults.string(forKey: Key.baseURL) ?? "" }
        set { defaults.set(Self.normalize(newValue), forKey: Key.baseURL) }
    }

    var language: String {
        get { defaults.string(forKey: Key.language) ?? "zh" }
        set { defaults.set(newValue, forKey: Key.language) }
    }

    /// 留空 = 内置页面；没写协议头时补 http://
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.contains("://") { return trimmed }
        return "http://" + trimmed
    }
}
