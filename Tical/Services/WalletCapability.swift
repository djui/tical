import PassKit

enum WalletCapability {
    /// True when this device can present the system Add to Wallet sheet.
    /// Tical still does not build a pass: Wallet rejects anything that is not signed
    /// with an Apple-issued Pass Type ID certificate.
    static var deviceCanAddPasses: Bool {
        PKAddPassesViewController.canAddPasses()
    }
}
