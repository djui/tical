import UIKit
import UniformTypeIdentifiers

/// Keep these values identical to `TicketDefaults` in the app target.
private enum ShareHandoff {
    static let appGroupID = "group.com.tical.app"
    static let inboxFolder = "Inbox"
    static let importURL = URL(string: "tical://import")!
}

/// Takes one ticket image or PDF from the share sheet, leaves it in the App Group inbox, and
/// opens Tical to read it.
final class ShareViewController: UIViewController {
    private enum ShareError: LocalizedError {
        case noTicket
        case unreadable
        case noAppGroup

        var errorDescription: String? {
            switch self {
            case .noTicket: String(localized: "Share a ticket image or PDF with Tical.")
            case .unreadable: String(localized: "Tical couldn't read that file.")
            case .noAppGroup: String(localized: "Tical can't receive files until its App Group is set up.")
            }
        }
    }

    private let symbol = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private lazy var doneButton = UIButton(configuration: .filled(), primaryAction: UIAction(title: String(localized: "Done")) { [weak self] _ in
        self?.extensionContext?.completeRequest(returningItems: nil)
    })

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        Task { await handOff() }
    }

    // MARK: - Hand-off

    private func handOff() async {
        do {
            let (data, type) = try await loadTicket()
            try saveToInbox(data, type: type)
        } catch {
            show(title: String(localized: "Couldn't Send to Tical"), detail: error.localizedDescription, symbolName: "exclamationmark.triangle.fill")
            return
        }
        if openTical() {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            show(
                title: String(localized: "Ready in Tical"),
                detail: String(localized: "Open Tical to review the ticket. It's waiting there."),
                symbolName: "checkmark.circle.fill"
            )
        }
    }

    private func loadTicket() async throws -> (Data, UTType) {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for wanted in [UTType.pdf, UTType.image] {
            for provider in providers {
                guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: wanted) }) else { continue }
                if let data = try? await provider.dataRepresentation(for: type) {
                    return (data, type)
                }
            }
        }
        // Some apps share an image object rather than a file.
        for provider in providers where provider.canLoadObject(ofClass: UIImage.self) {
            if let image = try? await provider.image(), let data = image.pngData() {
                return (data, .png)
            }
        }
        throw providers.isEmpty ? ShareError.noTicket : ShareError.unreadable
    }

    private func saveToInbox(_ data: Data, type: UTType) throws {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ShareHandoff.appGroupID
        ) else { throw ShareError.noAppGroup }
        let inbox = container.appendingPathComponent(ShareHandoff.inboxFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(type.preferredFilenameExtension ?? "dat")
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Share extensions can't open URLs through `NSExtensionContext`; iOS only honors that for
    /// some extension types. The app object in the responder chain still can.
    private func openTical() -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias OpenURL = @convention(c) (NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: OpenURL.self)
                open(application, selector, ShareHandoff.importURL as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    // MARK: - Interface

    private func buildInterface() {
        view.backgroundColor = .systemBackground

        let configuration = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        symbol.image = UIImage(systemName: "ticket.fill", withConfiguration: configuration)
        symbol.tintColor = .tintColor
        symbol.contentMode = .scaleAspectFit

        titleLabel.text = String(localized: "Opening Tical")
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.isHidden = true

        doneButton.isHidden = true
        doneButton.configuration?.cornerStyle = .capsule
        activity.startAnimating()

        let stack = UIStackView(arrangedSubviews: [symbol, titleLabel, detailLabel, activity, doneButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(20, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            doneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        preferredContentSize = CGSize(width: 0, height: 260)
    }

    private func show(title: String, detail: String, symbolName: String) {
        activity.stopAnimating()
        activity.isHidden = true
        symbol.image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold))
        titleLabel.text = title
        detailLabel.text = detail
        detailLabel.isHidden = false
        doneButton.isHidden = false
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }
}

private extension NSItemProvider {
    func dataRepresentation(for type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    func image() async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: UIImage.self) { object, error in
                if let image = object as? UIImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
