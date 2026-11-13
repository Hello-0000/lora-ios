import UIKit

/// 对应 Android 的 SettingActivity：地址 + 语言
final class SettingsViewController: UIViewController {

    private let onSave: () -> Void
    private let urlField = UITextField()
    private let languageControl = UISegmentedControl(items: ["中文", "English"])

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
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
        urlField.placeholder = AppSettings.defaultBaseURL
        urlField.text = AppSettings.shared.baseURL
        urlField.heightAnchor.constraint(equalToConstant: 44).isActive = true

        languageControl.selectedSegmentIndex = AppSettings.shared.language == "en" ? 1 : 0
        languageControl.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let stack = UIStackView(arrangedSubviews: [
            makeLabel("服务器地址"),
            urlField,
            makeLabel("语言"),
            languageControl,
            makeLabel("提示：局域网直连设备时，填设备的 Web 地址（例如 192.168.4.1），不写 http:// 会自动补全。"),
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

    @objc private func save() {
        AppSettings.shared.baseURL = urlField.text ?? ""
        AppSettings.shared.language = languageControl.selectedSegmentIndex == 1 ? "en" : "zh"
        dismiss(animated: true) { [onSave] in onSave() }
    }
}
