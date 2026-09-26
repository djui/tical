import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// The code as a Wallet pass encodes it: a format, a message, and the encoding that turns the
/// message back into the scanned bytes.
nonisolated struct WalletBarcode: Equatable, Sendable {
    enum Format: String, Sendable {
        case qr = "PKBarcodeFormatQR"
        case aztec = "PKBarcodeFormatAztec"
        case pdf417 = "PKBarcodeFormatPDF417"
        case code128 = "PKBarcodeFormatCode128"
    }

    enum Encoding: String, Sendable {
        case latin1 = "iso-8859-1"
        case utf8 = "utf-8"

        var stringEncoding: String.Encoding {
            self == .latin1 ? .isoLatin1 : .utf8
        }
    }

    var format: Format
    var message: String
    var encoding: Encoding
    /// True when Wallet can't show the original symbology and the pass uses a QR code instead.
    var changesSymbology: Bool

    var messageData: Data? {
        message.data(using: encoding.stringEncoding)
    }

    init?(_ barcode: DetectedBarcode) {
        switch barcode.symbology {
        case .qr: format = .qr
        case .aztec: format = .aztec
        case .pdf417: format = .pdf417
        case .code128: format = .code128
        case .dataMatrix: format = .qr
        }
        changesSymbology = barcode.symbology == .dataMatrix

        if let text = barcode.text, !text.isEmpty {
            message = text
            let fitsLatin1 = text.unicodeScalars.allSatisfy { $0.value <= 0xFF }
            let isASCII = text.unicodeScalars.allSatisfy { $0.value < 0x80 }
            // Vision gives binary Aztec and PDF417 content as one Latin-1 character per byte.
            // Text in QR codes is UTF-8 unless it is plain ASCII.
            if isASCII || (fitsLatin1 && barcode.symbology != .qr) {
                encoding = .latin1
            } else {
                encoding = .utf8
            }
        } else if let bytes = barcode.bytes, !bytes.isEmpty {
            // One Latin-1 character per byte; Wallet encodes them back to the same bytes.
            message = String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
            encoding = .latin1
        } else {
            return nil
        }

        if format == .code128, !message.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
            return nil
        }
    }
}

/// Draws a code the way Wallet will, so the review screen can show it and Tical can check it.
nonisolated enum BarcodeRenderer {
    static func image(for barcode: WalletBarcode, moduleSize: CGFloat = 8) -> CGImage? {
        guard let data = barcode.messageData, let output = ciImage(for: barcode.format, message: data) else {
            return nil
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: moduleSize, y: moduleSize))
        let quietZone = moduleSize * (barcode.format == .code128 || barcode.format == .pdf417 ? 6 : 4)
        let canvas = scaled.extent.insetBy(dx: -quietZone, dy: -quietZone)
        let composed = scaled.composited(over: CIImage(color: .white).cropped(to: canvas))
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(composed, from: canvas)
    }

    /// Renders the code, reads it back with Vision, and compares what comes out with what went
    /// in. A match means a pass built from `barcode` shows a code with the same content.
    static func verify(_ barcode: WalletBarcode, matches original: DetectedBarcode) -> Bool {
        guard let image = image(for: barcode) else { return false }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .aztec, .pdf417, .code128]
        VisionTicketScanner.useSimulatorCompatibleRevision(request)
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        } catch {
            return false
        }
        guard let reread = request.results?.first.flatMap(VisionTicketScanner.detectedBarcode(from:)) else {
            return false
        }
        if let text = original.text {
            return reread.text == text
        }
        if let bytes = original.bytes {
            return (reread.bytes ?? reread.text.flatMap { $0.data(using: .isoLatin1) }) == bytes
        }
        return false
    }

    private static func ciImage(for format: WalletBarcode.Format, message: Data) -> CIImage? {
        switch format {
        case .qr:
            let filter = CIFilter.qrCodeGenerator()
            filter.message = message
            filter.correctionLevel = "M"
            return filter.outputImage
        case .aztec:
            let filter = CIFilter.aztecCodeGenerator()
            filter.message = message
            return filter.outputImage
        case .pdf417:
            let filter = CIFilter.pdf417BarcodeGenerator()
            filter.message = message
            return filter.outputImage
        case .code128:
            let filter = CIFilter.code128BarcodeGenerator()
            filter.message = message
            filter.quietSpace = 0
            return filter.outputImage
        }
    }
}
