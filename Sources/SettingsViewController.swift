import UIKit

/// 对应 Android 的 SettingActivity：地址 + 语言
final class SettingsViewController: UIViewController {

    private let onSave: () -> Void
    private let onSelfCheck: (() -> Void)?
    private let urlField = UITextField()
    private let languageControl = UISegmentedControl(items: ["中文", "English"])
    private let devToolsSwitch = UISwitch()

    init(onSave: @escaping () -> Void, onSelfCheck: (() -> Void)? = nil) {
        self.onSave = onSave
        self.onSelfCheck = onSelfCheck
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        view.backgroundColor = .systemGroupedBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "取消", style: .plain, target: self, action: #selector(cancel)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "保存", style: .done, target: self, action: #selector(save)
        )

        urlField.borderStyle = .roundedRect
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.clearButtonMode = .whileEditing
        urlField.placeholder = "留空 = 内置页面（离线）"
        urlField.text = AppSettings.shared.baseURL

        let resetButton = UIButton(type: .system)
        resetButton.setTitle("使用内置页面（离线）", for: .normal)
        resetButton.contentHorizontalAlignment = .left
        resetButton.addTarget(self, action: #selector(useBundled), for: .touchUpInside)
        resetButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        let vendorButton = UIButton(type: .system)
        vendorButton.setTitle("使用厂商在线页面", for: .normal)
        vendorButton.contentHorizontalAlignment = .left
        vendorButton.addTarget(self, action: #selector(useVendor), for: .touchUpInside)
        vendorButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
        urlField.heightAnchor.constraint(equalToConstant: 44).isActive = true

        languageControl.selectedSegmentIndex = AppSettings.shared.language == "en" ? 1 : 0
        languageControl.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let logButton = UIButton(type: .system)
        logButton.setTitle("查看通信日志", for: .normal)
        logButton.contentHorizontalAlignment = .left
        logButton.addTarget(self, action: #selector(showLogs), for: .touchUpInside)
        logButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let checkButton = UIButton(type: .system)
        checkButton.setTitle("网络自检（探测网关）", for: .normal)
        checkButton.contentHorizontalAlignment = .left
        checkButton.addTarget(self, action: #selector(runSelfCheck), for: .touchUpInside)
        checkButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let devToolsRow = UIStackView(arrangedSubviews: [makeLabel("显示调试面板（eruda）"), devToolsSwitch])
        devToolsRow.axis = .horizontal
        devToolsRow.alignment = .center
        devToolsSwitch.isOn = AppSettings.shared.showDevTools

        let stack = UIStackView(arrangedSubviews: [
            makeLabel("页面地址"),
            urlField,
            resetButton,
            vendorButton,
            makeLabel("语言"),
            languageControl,
            devToolsRow,
            checkButton,
            logButton,
            makeLabel("提示：默认使用打包在 App 内的离线页面，不经过外网；需要在线版本时点「使用厂商在线页面」，也可以直接填设备 Web 地址（如 192.168.4.1）。"),
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(20, after: urlField)
        stack.setCustomSpacing(20, after: languageControl)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func makeLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    @objc private func showLogs() {
        let controller = DebugLogViewController()
        navigationController?.pushViewController(controller, animated: true)
    }

    @objc private func runSelfCheck() {
        onSelfCheck?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.showLogs()
        }
    }

    @objc private func useBundled() {
        urlField.text = ""
        AppSettings.shared.baseURL = ""
        dismiss(animated: true) { [onSave] in onSave() }
    }

    @objc private func useVendor() {
        urlField.text = AppSettings.vendorBaseURL
        AppSettings.shared.baseURL = AppSettings.vendorBaseURL
        dismiss(animated: true) { [onSave] in onSave() }
    }

    @objc private func save() {
        AppSettings.shared.baseURL = urlField.text ?? ""
        AppSettings.shared.language = languageControl.selectedSegmentIndex == 1 ? "en" : "zh"
        AppSettings.shared.showDevTools = devToolsSwitch.isOn
        dismiss(animated: true) { [onSave] in onSave() }
    }
}
