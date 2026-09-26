import CoreGraphics
import Foundation

/// A barcode read from the ticket image.
nonisolated struct DetectedBarcode: Equatable, Sendable {
    enum Symbology: String, Sendable {
        case qr
        case aztec
        case pdf417
        case code128
        case dataMatrix

        var displayName: String {
            switch self {
            case .qr: "QR"
            case .aztec: "Aztec"
            case .pdf417: "PDF417"
            case .code128: "Code 128"
            case .dataMatrix: "Data Matrix"
            }
        }
    }

    var symbology: Symbology
    /// The decoded text, when the code carries text. Aztec and PDF417 codes with binary
    /// content come through as one Latin-1 character per byte.
    var text: String?
    /// The decoded bytes of a QR code whose content isn't text.
    var bytes: Data?
    /// Where the code is in the scanned image, normalized, with the origin at the top left.
    var bounds: CGRect

    /// What the review screen shows and what the copy button copies.
    var displayPayload: String {
        if let text { return text }
        guard let bytes else { return "" }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// A short payload that reads like a booking reference, not a URL or a blob.
    var looksLikeReference: Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 20
            && trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9\-]{4,}$"#, options: .regularExpression) != nil
            && trimmed.range(of: #"\d"#, options: .regularExpression) != nil
    }
}

/// Recovers the bytes of a QR code from its error-corrected codewords. Vision returns those
/// codewords, mode bits and padding included, as `payloadData`, and returns no string when
/// the code holds binary data.
nonisolated enum QRSegmentDecoder {
    static func decode(_ codewords: Data, version: Int) -> Data? {
        var reader = BitReader(bytes: [UInt8](codewords))
        var output = Data()
        let alphanumeric = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:".utf8)

        while let mode = reader.read(4) {
            switch mode {
            case 0b0000:
                return output
            case 0b0100: // byte
                guard let count = reader.read(version <= 9 ? 8 : 16) else { return nil }
                for _ in 0..<count {
                    guard let byte = reader.read(8) else { return nil }
                    output.append(UInt8(byte))
                }
            case 0b0001: // numeric
                guard var count = reader.read(version <= 9 ? 10 : version <= 26 ? 12 : 14) else { return nil }
                while count >= 3 {
                    guard let value = reader.read(10), value < 1000 else { return nil }
                    output.append(contentsOf: String(format: "%03d", value).utf8)
                    count -= 3
                }
                if count == 2 {
                    guard let value = reader.read(7), value < 100 else { return nil }
                    output.append(contentsOf: String(format: "%02d", value).utf8)
                } else if count == 1 {
                    guard let value = reader.read(4), value < 10 else { return nil }
                    output.append(contentsOf: String(value).utf8)
                }
            case 0b0010: // alphanumeric
                guard var count = reader.read(version <= 9 ? 9 : version <= 26 ? 11 : 13) else { return nil }
                while count >= 2 {
                    guard let value = reader.read(11), value < 45 * 45 else { return nil }
                    output.append(alphanumeric[value / 45])
                    output.append(alphanumeric[value % 45])
                    count -= 2
                }
                if count == 1 {
                    guard let value = reader.read(6), value < 45 else { return nil }
                    output.append(alphanumeric[value])
                }
            case 0b0111: // ECI designator: the bytes that follow keep their values
                guard let first = reader.read(8) else { return nil }
                if first & 0x80 == 0 {
                    break
                } else if first & 0xC0 == 0x80 {
                    guard reader.read(8) != nil else { return nil }
                } else {
                    guard reader.read(16) != nil else { return nil }
                }
            default:
                // Kanji, structured append, and FNC1 don't appear on tickets Tical handles.
                return nil
            }
        }
        return output
    }

    private struct BitReader {
        let bytes: [UInt8]
        var position = 0

        mutating func read(_ count: Int) -> Int? {
            guard position + count <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                let bit = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
                value = (value << 1) | Int(bit)
                position += 1
            }
            return value
        }
    }
}
