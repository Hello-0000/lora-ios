import UIKit

/// 通信日志查看器：把 UDP 收发和桥接调用都记下来，方便真机排查
final class DebugLogViewController: UIViewController {

    private let textView = UITextView()
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "通信日志"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "清空", style: .plain, target: self, action: #selector(clearLog)
        )

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func refresh() {
        let content = DebugLog.shared.snapshot()
        guard textView.text != content else { return }
        textView.text = content
        if !content.isEmpty {
            textView.scrollRangeToVisible(NSRange(location: content.count - 1, length: 1))
        }
    }

    @objc private func clearLog() {
        DebugLog.shared.clear()
        refresh()
    }
}
