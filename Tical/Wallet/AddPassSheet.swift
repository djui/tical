import PassKit
import SwiftUI

/// The system sheet that previews a pass and adds it to Wallet.
struct AddPassSheet: UIViewControllerRepresentable {
    let pass: PKPass
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        guard let controller = PKAddPassesViewController(pass: pass) else {
            return UIViewController()
        }
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, PKAddPassesViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
            onFinish()
        }
    }
}

extension PKPass {
    /// A readable reason when Wallet rejects a pass Tical built.
    static func explanation(for error: Error, ownCertificate: Bool) -> String {
        if let passError = error as? PKPassKitError {
            switch passError.code {
            case .invalidSignature where ownCertificate:
                return String(localized: "Wallet didn't accept the pass signature. Check that the certificate in Settings is your Pass Type ID certificate, and that it hasn't been revoked.")
            case .invalidDataError where ownCertificate:
                // PassKit also reports certificate chain failures this way.
                return String(localized: "Wallet rejected the pass. Usually this means the certificate in Settings isn't a Pass Type ID certificate issued by Apple, or its chain to Apple couldn't be verified.")
            case .invalidSignature, .invalidDataError:
                return String(localized: "Wallet didn't accept the signature from Tical's server. Try again later.")
            case .unsupportedVersionError:
                return String(localized: "This version of Wallet doesn't support the pass.")
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
