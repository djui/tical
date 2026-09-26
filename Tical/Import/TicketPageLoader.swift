import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A ticket as it arrives: an image or a PDF.
nonisolated enum ImportInput: Sendable {
    case image(Data)
    case pdf(Data)

    init(data: Data) {
        self = data.starts(with: Array("%PDF".utf8)) ? .pdf(data) : .image(data)
    }

    init(data: Data, contentType: UTType?) {
        if let contentType, contentType.conforms(to: .pdf) {
            self = .pdf(data)
        } else {
            self.init(data: data)
        }
    }
}

/// The image Tical reads: the screenshot itself, or the PDF page that carries the code.
nonisolated struct TicketPage: @unchecked Sendable {
    struct PDFPosition: Equatable, Sendable {
        /// One-based.
        var number: Int
        var count: Int
    }

    let image: CGImage
    var pdfPage: PDFPosition?
}

nonisolated enum TicketPageLoader {
    /// Long enough for small print and dense codes, small enough for a share extension's memory.
    static let maxPixelSize = 2400

    static func load(_ input: ImportInput) -> TicketPage? {
        switch input {
        case .image(let data):
            return image(from: data).map { TicketPage(image: $0) }
        case .pdf(let data):
            return page(fromPDF: data)
        }
    }

    // MARK: - Images

    private static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return flattened(image)
    }

    /// Draws the image on white so transparent areas don't read as black.
    private static func flattened(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = bitmapContext(width: image.width, height: image.height) else { return image }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    // MARK: - PDF

    private static func page(fromPDF data: Data) -> TicketPage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else { return nil }
        let count = document.numberOfPages

        // Multi-page PDFs often put terms or ads first. Use the first page with a code.
        for number in 1...min(count, 6) {
            guard let page = document.page(at: number),
                  let preview = render(page, maxPixelSize: 1600) else { continue }
            if VisionTicketScanner.detectBarcode(in: preview) != nil {
                let image = render(page, maxPixelSize: maxPixelSize) ?? preview
                return TicketPage(image: image, pdfPage: .init(number: number, count: count))
            }
        }
        guard let first = document.page(at: 1), let image = render(first, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return TicketPage(image: image, pdfPage: .init(number: 1, count: count))
    }

    private static func render(_ page: CGPDFPage, maxPixelSize: Int) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let quarterTurns = (page.rotationAngle / 90) % 2 != 0
        let size = quarterTurns ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 1, size.height > 1 else { return nil }
        let scale = min(CGFloat(maxPixelSize) / max(size.width, size.height), 6)
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard let context = bitmapContext(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // The target rect matches the rotated box size, so this transform only rotates and moves.
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }
}
