import UIKit

/// How the app refers to the device it runs on, so iPad text doesn't say "iPhone".
enum Device {
    /// "iPhone" or "iPad", as the system names it.
    static var name: String { UIDevice.current.localizedModel }

    static var symbol: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }
}
