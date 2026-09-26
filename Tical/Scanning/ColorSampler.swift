import CoreGraphics
import Foundation

/// Picks a pass color from the ticket: the most common vivid color, darkened or lightened so
/// the pass text stays readable.
nonisolated enum ColorSampler {
    static func passColor(from image: CGImage) -> RGBColor {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
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
        guard drew else { return .brand }

        struct Bucket {
            var weight = 0.0
            var red = 0.0
            var green = 0.0
            var blue = 0.0
        }
        var buckets: [Int: Bucket] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let (_, saturation, brightness) = hsb(red, green, blue)
            // Skip paper, ink, and grays.
            guard saturation > 0.3, brightness > 0.18, brightness < 0.97 else { continue }
            let key = Int(red * 7) << 6 | Int(green * 7) << 3 | Int(blue * 7)
            let weight = saturation * saturation
            buckets[key, default: Bucket()].weight += weight
            buckets[key, default: Bucket()].red += red * weight
            buckets[key, default: Bucket()].green += green * weight
            buckets[key, default: Bucket()].blue += blue * weight
        }

        // Ignore specks: a color has to cover a noticeable part of the ticket.
        guard let best = buckets.values.max(by: { $0.weight < $1.weight }),
              best.weight > Double(side * side) * 0.015 else { return .brand }
        let color = RGBColor(red: best.red / best.weight, green: best.green / best.weight, blue: best.blue / best.weight)
        return readable(color)
    }

    /// Keeps the color vivid and dark enough for white text, or light enough for black text.
    static func readable(_ color: RGBColor) -> RGBColor {
        var (hue, saturation, brightness) = hsb(color.red, color.green, color.blue)
        saturation = min(max(saturation, 0.45), 0.9)
        brightness = min(max(brightness, 0.3), 0.72)
        var adjusted = rgb(hue, saturation, brightness)
        // Yellows and light greens stay light: give them dark text rather than muddy them.
        while !adjusted.prefersDarkText, contrast(adjusted, .init(red: 1, green: 1, blue: 1)) < 4.5, brightness > 0.2 {
            brightness -= 0.04
            adjusted = rgb(hue, saturation, brightness)
        }
        return adjusted
    }

    private static func contrast(_ lhs: RGBColor, _ rhs: RGBColor) -> Double {
        let (light, dark) = lhs.luminance > rhs.luminance ? (lhs.luminance, rhs.luminance) : (rhs.luminance, lhs.luminance)
        return (light + 0.05) / (dark + 0.05)
    }

    private static func hsb(_ red: Double, _ green: Double, _ blue: Double) -> (Double, Double, Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        var hue = 0.0
        if delta > 0 {
            if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, maximum == 0 ? 0 : delta / maximum, maximum)
    }

    private static func rgb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> RGBColor {
        let sector = hue * 6
        let chroma = brightness * saturation
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - chroma
        let (r, g, b): (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: (r, g, b) = (chroma, x, 0)
        case 1: (r, g, b) = (x, chroma, 0)
        case 2: (r, g, b) = (0, chroma, x)
        case 3: (r, g, b) = (0, x, chroma)
        case 4: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        return RGBColor(red: r + m, green: g + m, blue: b + m)
    }
}
