import UIKit

/// Keep these three values identical to `TicketDefaults` in the app target.
private enum ShareHandoff {
    static let appGroupID = "group.com.tical.app"
    static let pendingFilename = "pending-ticket.jpg"
    static let urlScheme = "tical"
}

class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .label
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "Sending this screenshot to Tical."
        statusLabel.accessibilityLabel = "Sending this screenshot to Tical"
        activity.startAnimating()

        let stack = UIStackView(arrangedSubviews: [activity, statusLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        preferredContentSize = CGSize(width: 0, height: 180)
        importSharedImage()
    }

    private func importSharedImage() {
        guard let attachment = (extensionContext?.inputItems.first as? NSExtensionItem)?.attachments?.first,
              attachment.hasItemConformingToTypeIdentifier("public.image") else {
            fail("Tical can only take an image.")
            return
        }

        attachment.loadDataRepresentation(forTypeIdentifier: "public.image") { [weak self] data, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.fail(error.localizedDescription)
                    return
                }
                guard let data, let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.92) else {
                    self.fail("Tical couldn't read that image.")
                    return
                }
                self.handOff(jpeg)
            }
        }
    }

    private func handOff(_ data: Data) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ShareHandoff.appGroupID
        ) else {
            fail("Tical can't share files with the app until the App Group \(ShareHandoff.appGroupID) is enabled for both targets.")
            return
        }
        let url = container.appendingPathComponent(ShareHandoff.pendingFilename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            fail("Tical couldn't save the screenshot on this iPhone.")
            return
        }

        let openURL = URL(string: "\(ShareHandoff.urlScheme)://import")
        guard let openURL else {
            showMessage("Open Tical. The screenshot is waiting.")
            return
        }
        extensionContext?.open(openURL) { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.extensionContext?.completeRequest(returningItems: nil)
                } else {
                    self?.showMessage("Open Tical. The screenshot is waiting there.")
                }
            }
        }
    }

    private func fail(_ message: String) {
        showMessage(message)
    }

    private func showMessage(_ message: String) {
        activity.stopAnimating()
        statusLabel.text = message
        statusLabel.accessibilityLabel = message
        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        close.titleLabel?.adjustsFontForContentSizeCategory = true
        close.addAction(UIAction { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, for: .touchUpInside)
        close.accessibilityLabel = "Close"
        if let stack = statusLabel.superview as? UIStackView, stack.arrangedSubviews.count < 3 {
            stack.addArrangedSubview(close)
        }
    }
}
