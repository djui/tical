import ImageIO
import UIKit
import Vision

struct RecognizedLine: Sendable, Hashable {
    var text: String
    var midY: Double
    var minX: Double
    var height: Double
}

struct ScanResult: Sendable {
    var lines: [RecognizedLine]
    var barcodePayload: String
    var barcodeSymbology: String
    var barcodeImageJPEG: Data?
    var warning: String?

    static let empty = ScanResult(
        lines: [],
        barcodePayload: "",
        barcodeSymbology: "",
        barcodeImageJPEG: nil,
        warning: nil
    )
}

enum VisionTicketScanner {
    /// Runs Vision on device. Safe to call off the main actor; it does not touch UI state.
    nonisolated static func scan(imageData: Data) -> ScanResult {
        guard let cgImage = normalizedCGImage(from: imageData) else {
            return ScanResult(
                lines: [],
                barcodePayload: "",
                barcodeSymbology: "",
                barcodeImageJPEG: nil,
                warning: "Tical couldn't open that image."
            )
        }

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true

        let barcodeRequest = VNDetectBarcodesRequest()
        barcodeRequest.symbologies = [.qr, .pdf417, .aztec, .dataMatrix, .code128]

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([barcodeRequest, textRequest])
        } catch {
            return ScanResult(
                lines: [],
                barcodePayload: "",
                barcodeSymbology: "",
                barcodeImageJPEG: nil,
                warning: "Tical couldn't read this image on the device."
            )
        }

        let lines = (textRequest.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let box = observation.boundingBox
            return RecognizedLine(
                text: trimmed,
                midY: Double(box.midY),
                minX: Double(box.minX),
                height: Double(box.height)
            )
        }

        let barcode = bestBarcode(in: barcodeRequest.results ?? [])
        var payload = ""
        var symbology = ""
        var jpeg: Data?
        if let barcode {
            payload = barcode.payloadStringValue ?? ""
            symbology = displayName(for: barcode.symbology)
            jpeg = cropJPEG(cgImage, normalizedBox: barcode.boundingBox)
        }

        var warning: String?
        if lines.isEmpty && payload.isEmpty && symbology.isEmpty {
            warning = "No text or code was found. You can type the ticket details yourself."
        } else if symbology.isEmpty {
            warning = nil
        } else if payload.isEmpty {
            warning = "A \(symbology) code was found, but it has no text payload."
        }

        return ScanResult(
            lines: lines,
            barcodePayload: payload,
            barcodeSymbology: symbology,
            barcodeImageJPEG: jpeg,
            warning: warning
        )
    }

    private nonisolated static func bestBarcode(in observations: [VNBarcodeObservation]) -> VNBarcodeObservation? {
        observations.max { lhs, rhs in
            let left = (rank(lhs.symbology), -(lhs.boundingBox.width * lhs.boundingBox.height))
            let right = (rank(rhs.symbology), -(rhs.boundingBox.width * rhs.boundingBox.height))
            return left > right
        }
    }

    private nonisolated static func rank(_ symbology: VNBarcodeSymbology) -> Int {
        switch symbology {
        case .qr: return 0
        case .pdf417: return 1
        case .aztec: return 2
        case .dataMatrix: return 3
        case .code128: return 4
        default: return 9
        }
    }

    private nonisolated static func displayName(for symbology: VNBarcodeSymbology) -> String {
        switch symbology {
        case .qr: return "QR"
        case .pdf417: return "PDF417"
        case .aztec: return "Aztec"
        case .dataMatrix: return "Data Matrix"
        case .code128: return "Code 128"
        default: return symbology.rawValue
        }
    }

    private nonisolated static func cropJPEG(_ image: CGImage, normalizedBox: CGRect) -> Data? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var rect = CGRect(
            x: normalizedBox.origin.x * width,
            y: (1 - normalizedBox.origin.y - normalizedBox.height) * height,
            width: normalizedBox.width * width,
            height: normalizedBox.height * height
        )
        let pad = max(rect.width, rect.height) * 0.12
        rect = rect.insetBy(dx: -pad, dy: -pad)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        rect = rect.intersection(bounds).integral
        guard rect.width > 8, rect.height > 8, let cropped = image.cropping(to: rect) else {
            return nil
        }
        return jpegData(from: cropped)
    }

    private nonisolated static func normalizedCGImage(from data: Data) -> CGImage? {
        guard let image = UIImage(data: data) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var size = image.size
        guard size.width > 1, size.height > 1 else { return nil }
        let longest = max(size.width, size.height)
        let maxDimension: CGFloat = 2400
        if longest > maxDimension {
            let scale = maxDimension / longest
            size = CGSize(width: size.width * scale, height: size.height * scale)
        }
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    private nonisolated static func jpegData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
