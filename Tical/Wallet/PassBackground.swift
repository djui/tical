import CoreGraphics
import Foundation

/// A photo behind the pass details, in place of the pass color.
nonisolated struct PassBackground: @unchecked Sendable {
    enum Style: String, CaseIterable, Identifiable, Sendable {
        /// An event ticket with the photo behind the details, which Wallet blurs.
        case blurred
        /// A poster pass: the photo sharp and full size, with the details at the bottom. Wallet
        /// has shown these since iOS 27; older devices show the blurred event ticket instead.
        case poster

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .blurred: "Blurred"
            case .poster: "Poster"
            }
        }
    }

    /// Upright, and small enough for the pass images. CGImage is immutable, so sharing it is safe.
    let image: CGImage
    /// The photo's average color. The pass uses it as its color, so the text color suits the photo.
    let color: RGBColor
    var style: Style

    /// Enough for the poster's largest image, which is 1074 × 1344 pixels.
    static let maxPixelSize = 1600

    init?(data: Data, style: Style = .blurred) {
        guard let image = TicketPageLoader.image(from: data, maxPixelSize: Self.maxPixelSize) else { return nil }
        self.init(image: image, style: style)
    }

    init(image: CGImage, style: Style = .blurred) {
        self.image = image
        self.color = Self.averageColor(of: image)
        self.style = style
    }

    private static func averageColor(of image: CGImage) -> RGBColor {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return .brand }
        var red = 0.0, green = 0.0, blue = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            red += Double(pixels[index])
            green += Double(pixels[index + 1])
            blue += Double(pixels[index + 2])
        }
        let total = Double(side * side) * 255
        return RGBColor(red: red / total, green: green / total, blue: blue / total)
    }
}
