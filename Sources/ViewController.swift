import UIKit

/// M0 阶段：仅用于验证「Xcode 构建 → IPA → TrollStore 安装」链路是否通畅。
final class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let title = UILabel()
        title.text = "LoRa"
        title.font = .systemFont(ofSize: 34, weight: .bold)

        let subtitle = UILabel()
        subtitle.text = "iOS 客户端 · M0 安装验证"
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabel

        let info = UILabel()
        info.numberOfLines = 0
        info.textAlignment = .center
        info.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        info.textColor = .secondaryLabel
        info.text = [
            "版本: \(Self.appVersion)",
            "Bundle ID: \(Bundle.main.bundleIdentifier ?? "-")",
            "系统: iOS \(UIDevice.current.systemVersion)",
            "机型: \(Self.machineName)",
        ].joined(separator: "\n")

        [title, subtitle, info].forEach { stack.addArrangedSubview($0) }

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static var machineName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }
}
