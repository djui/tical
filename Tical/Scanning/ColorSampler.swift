import CoreGraphics
import Foundation
import Vision

/// Picks a pass color from the ticket: the most common vivid color on the ticket itself, adjusted
/// so the pass text stays readable.
nonisolated enum ColorSampler {
    /// - Parameter barcode: Where the code is, normalized with the origin at the top left. The
    ///   ticket is found around it.
    static func passColor(from image: CGImage, barcode: CGRect? = nil) -> RGBColor {
        guard let bitmap = Bitmap(image) else { return .brand }

        // A ticket box on a printed page, or the paper in a photo: only its inside counts.
        if let barcode, let ticket = ticketOutline(in: image, around: barcode),
           let color = bitmap.dominantColor(where: ticket.contains) {
            return readable(color)
        }
        // A screenshot: leave out colored bars of the ticket app. They only count when the
        // ticket has no color of its own, since the app's color still beats a generic one.
        let bars = bitmap.appBars()
        if !bars.isEmpty, let color = bitmap.dominantColor(where: { point in !bars.contains { $0.contains(point.y) } }) {
            return readable(color)
        }
        return bitmap.dominantColor(where: { _ in true }).map(readable) ?? .brand
    }

    /// Keeps the color's hue and makes the pass text readable with the smaller change: light
    /// colors keep their brightness and get dark text, and colors with white text are darkened
    /// only as far as contrast requires.
    static func readable(_ color: RGBColor) -> RGBColor {
        let (hue, rawSaturation, rawBrightness) = hsb(color.red, color.green, color.blue)
        let saturation = min(max(rawSaturation, 0.45), 0.9)
        let start = max(rawBrightness, 0.3)
        let minimumContrast = 4.5

        let withWhiteText = nearestBrightness(from: start, step: -0.02, hue: hue, saturation: saturation) {
            $0.contrast(with: .white) >= minimumContrast
        }
        let withDarkText = nearestBrightness(from: start, step: 0.02, hue: hue, saturation: saturation) {
            $0.contrast(with: .darkText) >= minimumContrast
        }
        switch (withWhiteText, withDarkText) {
        case let (white?, dark?):
            // Most passes use white text, so it wins unless it needs clearly more darkening.
            return start - white.brightness <= dark.brightness - start + 0.12 ? white.color : dark.color
        case let (white?, nil):
            return white.color
        case let (nil, dark?):
            return dark.color
        case (nil, nil):
            return .brand
        }
    }

    /// The first brightness from `start`, moving in `step`s, at which `isReadable` holds.
    private static func nearestBrightness(
        from start: Double,
        step: Double,
        hue: Double,
        saturation: Double,
        where isReadable: (RGBColor) -> Bool
    ) -> (brightness: Double, color: RGBColor)? {
        var brightness = start
        while brightness >= 0.2, brightness <= 1 {
            let color = rgb(hue, saturation, brightness)
            if isReadable(color) { return (brightness, color) }
            brightness += step
        }
        return nil
    }

    // MARK: - Where the ticket is

    /// The outline of the ticket around the code, when Vision finds one: a box on a printed
    /// page, or the paper in a photo.
    private static func ticketOutline(in image: CGImage, around barcode: CGRect) -> Quadrilateral? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 10
        request.minimumSize = 0.15
        request.minimumAspectRatio = 0.15
        request.quadratureTolerance = 20
        request.minimumConfidence = 0.6
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        } catch {
            return nil
        }
        let outlines = (request.results ?? []).map(Quadrilateral.init).filter { $0.area < 0.95 }
        let center = CGPoint(x: barcode.midX, y: barcode.midY)
        let codeArea = barcode.width * barcode.height
        // The largest rectangle around the code that is more than the code itself.
        guard var ticket = outlines
            .filter({ $0.contains(center) && $0.area > codeArea * 2 })
            .max(by: { $0.area < $1.area }) else { return nil }

        // A colored header often comes out as its own rectangle, right above the part with the
        // code. Join rectangles of the same width that share an edge.
        for _ in 0..<4 {
            guard let neighbor = outlines.first(where: ticket.isStacked(with:)) else { break }
            ticket = Quadrilateral(ticket.bounds.union(neighbor.bounds))
        }
        return ticket
    }

    // MARK: - Color math

    fileprivate static func hsb(_ red: Double, _ green: Double, _ blue: Double) -> (Double, Double, Double) {
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

/// A convex four-sided outline, normalized with the origin at the top left.
nonisolated private struct Quadrilateral {
    let corners: [CGPoint]

    init(_ observation: VNRectangleObservation) {
        corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft]
            .map { CGPoint(x: $0.x, y: 1 - $0.y) }
    }

    init(_ rect: CGRect) {
        corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
    }

    var bounds: CGRect {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// True for an outline of the same width directly above or below this one.
    func isStacked(with other: Quadrilateral) -> Bool {
        let a = bounds
        let b = other.bounds
        let sameWidth = abs(a.minX - b.minX) < 0.03 && abs(a.maxX - b.maxX) < 0.03
        let touching = abs(a.minY - b.maxY) < 0.015 || abs(a.maxY - b.minY) < 0.015
        return sameWidth && touching
    }

    var area: Double {
        var twice = 0.0
        for index in corners.indices {
            let a = corners[index]
            let b = corners[(index + 1) % corners.count]
            twice += a.x * b.y - b.x * a.y
        }
        return abs(twice) / 2
    }

    /// True when the point is on the same side of every edge.
    func contains(_ point: CGPoint) -> Bool {
        var side = 0.0
        for index in corners.indices {
            let a = corners[index]
            let b = corners[(index + 1) % corners.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            guard cross != 0 else { continue }
            if side == 0 {
                side = cross
            } else if (cross > 0) != (side > 0) {
                return false
            }
        }
        return true
    }
}

/// The image, scaled down to at most 96 pixels wide, as sRGB components.
nonisolated private struct Bitmap {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        guard image.width > 0, image.height > 0 else { return nil }
        let width = min(96, image.width)
        let height = max(1, min(256, Int((Double(image.height) * Double(width) / Double(image.width)).rounded())))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// Row 0 is the top of the image.
    func color(x: Int, y: Int) -> RGBColor {
        let index = (y * width + x) * 4
        return RGBColor(red: Double(bytes[index]) / 255, green: Double(bytes[index + 1]) / 255, blue: Double(bytes[index + 2]) / 255)
    }

    /// The pixel's center, normalized with the origin at the top left.
    func point(x: Int, y: Int) -> CGPoint {
        CGPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))
    }

    /// The most common vivid color among the pixels `include` accepts, if it covers a
    /// noticeable part of them. Paper, ink, and grays don't count.
    func dominantColor(where include: (CGPoint) -> Bool) -> RGBColor? {
        struct Bucket {
            var weight = 0.0
            var red = 0.0
            var green = 0.0
            var blue = 0.0
        }
        var buckets: [Int: Bucket] = [:]
        var counted = 0
        for y in 0..<height {
            for x in 0..<width where include(point(x: x, y: y)) {
                counted += 1
                let pixel = color(x: x, y: y)
                let (_, saturation, brightness) = ColorSampler.hsb(pixel.red, pixel.green, pixel.blue)
                guard saturation > 0.3, brightness > 0.18 else { continue }
                let key = Int(pixel.red * 7) << 6 | Int(pixel.green * 7) << 3 | Int(pixel.blue * 7)
                // Vivid colors count more than washed-out ones.
                let weight = saturation * saturation
                buckets[key, default: Bucket()].weight += weight
                buckets[key, default: Bucket()].red += pixel.red * weight
                buckets[key, default: Bucket()].green += pixel.green * weight
                buckets[key, default: Bucket()].blue += pixel.blue * weight
            }
        }
        guard let best = buckets.values.max(by: { $0.weight < $1.weight }),
              best.weight > Double(counted) * 0.015 else { return nil }
        return RGBColor(red: best.red / best.weight, green: best.green / best.weight, blue: best.blue / best.weight)
    }

    /// Colored bars across the top or bottom of a phone screenshot, like a navigation bar or a
    /// tab bar, as ranges of normalized rows from the top.
    func appBars() -> [ClosedRange<Double>] {
        guard Double(height) / Double(width) > 1.6 else { return [] }
        var bars: [ClosedRange<Double>] = []
        if let rows = barRows(from: 0, step: 1, limit: 0.18) {
            bars.append(0...Double(rows) / Double(height))
        }
        if let rows = barRows(from: height - 1, step: -1, limit: 0.15) {
            bars.append(1 - Double(rows) / Double(height)...1)
        }
        return bars
    }

    /// How many rows from `start` belong to one vivid bar that spans the full width. A bar that
    /// runs longer than `limit` of the height is part of the ticket's own design.
    private func barRows(from start: Int, step: Int, limit: Double) -> Int? {
        let barColor = color(x: 0, y: start)
        let (_, saturation, brightness) = ColorSampler.hsb(barColor.red, barColor.green, barColor.blue)
        guard saturation > 0.3, brightness > 0.18 else { return nil }

        let maximumRows = Int(Double(height) * limit)
        var rows = 0
        var row = start
        while row >= 0, row < height,
              color(x: 0, y: row).distance(to: barColor) < 0.12,
              color(x: width - 1, y: row).distance(to: barColor) < 0.12 {
            rows += 1
            if rows > maximumRows { return nil }
            row += step
        }
        return rows >= max(2, Int(Double(height) * 0.03)) ? rows : nil
    }
}

private extension RGBColor {
    nonisolated func distance(to other: RGBColor) -> Double {
        let red = self.red - other.red
        let green = self.green - other.green
        let blue = self.blue - other.blue
        return (red * red + green * green + blue * blue).squareRoot()
    }
}
