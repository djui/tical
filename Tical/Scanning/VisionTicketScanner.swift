import CoreImage
import Vision

nonisolated struct RecognizedLine: Sendable, Hashable {
    var text: String
    var midY: Double
    var minX: Double
    var height: Double
}

nonisolated struct ScanResult: Sendable {
    var lines: [RecognizedLine]
    var barcode: DetectedBarcode?

    var isEmpty: Bool { lines.isEmpty && barcode == nil }

    /// Recognized lines from top to bottom, then left to right.
    var orderedLines: [RecognizedLine] {
        lines.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > 0.015 { return lhs.midY > rhs.midY }
            return lhs.minX < rhs.minX
        }
    }
}

/// Finds the code and reads the text with Vision, on this device.
nonisolated enum VisionTicketScanner {
    static let symbologies: [VNBarcodeSymbology] = [.qr, .aztec, .pdf417, .dataMatrix, .code128]

    static func detectBarcode(in image: CGImage) -> DetectedBarcode? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = symbologies
        useSimulatorCompatibleRevision(request)
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        } catch {
            return nil
        }
        let ranked = (request.results ?? []).sorted { lhs, rhs in
            let left = (rank(lhs.symbology), -area(lhs.boundingBox))
            let right = (rank(rhs.symbology), -area(rhs.boundingBox))
            return left < right
        }
        return ranked.lazy.compactMap(detectedBarcode(from:)).first
    }

    /// - Parameter barcode: Where the code is, normalized with the origin at the top left. Text
    ///   read off the code's modules, like "n An", is left out.
    static func recognizeText(in image: CGImage, ignoring barcode: CGRect? = nil) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        } catch {
            return []
        }
        // A phone screenshot carries the status bar: its clock would read as the event time.
        let isPhoneScreenshot = Double(image.height) / Double(max(image.width, 1)) > 1.6
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let box = observation.boundingBox
            if isPhoneScreenshot, box.minY > 0.94, trimmed.count <= 12 {
                return nil
            }
            let bounds = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            if let barcode, isMostlyOnCode(bounds, barcode: barcode) {
                return nil
            }
            return RecognizedLine(
                text: trimmed,
                midY: Double(box.midY),
                minX: Double(box.minX),
                height: Double(box.height)
            )
        }
    }

    /// True when more than half of a text line lies on the code. Both are normalized, with the
    /// origin at the top left.
    static func isMostlyOnCode(_ line: CGRect, barcode: CGRect) -> Bool {
        let overlap = line.intersection(barcode)
        guard !overlap.isNull, line.width > 0, line.height > 0 else { return false }
        return overlap.width * overlap.height > line.width * line.height / 2
    }

    static func detectedBarcode(from observation: VNBarcodeObservation) -> DetectedBarcode? {
        let symbology: DetectedBarcode.Symbology
        switch observation.symbology {
        case .qr: symbology = .qr
        case .aztec: symbology = .aztec
        case .pdf417: symbology = .pdf417
        case .code128: symbology = .code128
        case .dataMatrix: symbology = .dataMatrix
        default: return nil
        }

        var text = observation.payloadStringValue
        if text?.isEmpty == true { text = nil }
        var bytes: Data?
        if text == nil, let descriptor = observation.barcodeDescriptor as? CIQRCodeDescriptor {
            bytes = QRSegmentDecoder.decode(descriptor.errorCorrectedPayload, version: descriptor.symbolVersion)
        }
        guard text != nil || bytes?.isEmpty == false else { return nil }

        let box = observation.boundingBox
        return DetectedBarcode(
            symbology: symbology,
            text: text,
            bytes: bytes,
            bounds: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        )
    }

    /// In the simulator, the current barcode detector fails with "Could not create inference
    /// context", and finds nothing when forced onto the CPU. The first revision, which doesn't
    /// use a neural network, still works there. Devices keep the current, more accurate one.
    static func useSimulatorCompatibleRevision(_ request: VNDetectBarcodesRequest) {
        #if targetEnvironment(simulator)
        request.revision = 1
        #endif
    }

    private static func rank(_ symbology: VNBarcodeSymbology) -> Int {
        switch symbology {
        case .qr: 0
        case .aztec: 1
        case .pdf417: 2
        case .dataMatrix: 3
        case .code128: 4
        default: 9
        }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }
}
