import CoreImage
import Foundation
import Security
@testable import Tical

/// Throwaway signing identities for tests, made fresh each run so no private key lives in the repo.
enum TestIdentity {
    struct Identity {
        let key: SecKey
        let certificate: X509Certificate
    }

    /// A self-signed certificate shaped like a Pass Type ID certificate: pass type in `UID`, team in `OU`.
    static func passType(_ passTypeID: String = "pass.test.tical", team: String = "TESTTEAM01") throws -> Identity {
        let key = try makeKey()
        guard let publicKey = Keychain.publicKeyBytes(of: key) else { throw CocoaError(.featureUnsupported) }
        let name = DER.sequence([
            rdn(OID.userID, passTypeID),
            rdn(OID.commonName, "Pass Type ID: \(passTypeID)"),
            rdn(OID.organizationalUnitName, team),
            rdn(OID.organizationName, "Test Developer"),
        ])
        let tbs = DER.sequence([
            DER.context(0, DER.integer(2)),
            DER.integer(4242),
            DER.algorithmIdentifier(OID.sha256WithRSAEncryption),
            name,
            DER.sequence([
                DER.utcTime(Date(timeIntervalSinceNow: -3600)),
                DER.utcTime(Date(timeIntervalSinceNow: 365 * 86_400)),
            ]),
            name,
            DER.sequence([DER.algorithmIdentifier(OID.rsaEncryption), DER.bitString(publicKey)]),
        ])
        let signature = try Keychain.sign(tbs, with: key)
        let der = DER.sequence([tbs, DER.algorithmIdentifier(OID.sha256WithRSAEncryption), DER.bitString(signature)])
        return Identity(key: key, certificate: try X509Certificate(der: der))
    }

    static func makeKey() throws -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        return key
    }

    static func verify(_ signature: Data, of data: Data, with certificate: X509Certificate) -> Bool {
        guard let reference = SecCertificateCreateWithData(nil, certificate.der as CFData),
              let key = SecCertificateCopyKey(reference) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signature as CFData, nil)
    }

    private static func rdn(_ oid: String, _ value: String) -> Data {
        DER.set([DER.sequence([DER.objectIdentifier(oid), DER.utf8String(value)])])
    }
}

/// Reads the stored (uncompressed) entries of a ZIP archive, which is all Tical writes.
enum StoredZip {
    static func entries(of archive: Data) -> [String: Data] {
        let bytes = [UInt8](archive)
        var entries: [String: Data] = [:]
        var offset = 0
        func le16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func le32(_ at: Int) -> Int { le16(at) | le16(at + 2) << 16 }
        while offset + 30 <= bytes.count, le32(offset) == 0x0403_4B50 {
            let size = le32(offset + 18)
            let nameLength = le16(offset + 26)
            let extraLength = le16(offset + 28)
            let nameStart = offset + 30
            let dataStart = nameStart + nameLength + extraLength
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            entries[name] = Data(bytes[dataStart..<(dataStart + size)])
            offset = dataStart + size
        }
        return entries
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}

/// Draws simple ticket scenes for color tests: colored areas and a real QR code, no text.
enum TicketScene {
    /// Draws with the origin at the top left, like the scenes are described.
    static func image(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return context.makeImage()!
    }

    static func fill(_ context: CGContext, _ rect: CGRect, _ color: RGBColor, cornerRadius: CGFloat = 0) {
        context.setFillColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context.fillPath()
    }

    static func qrCode(_ context: CGContext, in rect: CGRect) {
        let filter = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("TICAL-TEST-0042".utf8), "inputCorrectionLevel": "M"])!
        let output = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let code = CIContext().createCGImage(output, from: output.extent)!
        context.saveGState()
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(code, in: rect)
        context.restoreGState()
    }

    static let white = RGBColor(red: 1, green: 1, blue: 1)
    static let pageGray = RGBColor(red: 0.95, green: 0.95, blue: 0.95)

    /// A phone screenshot: an inset white ticket card with a colored header, and optional
    /// colored app bars across the top and bottom.
    static func screenshot(header: RGBColor?, appBars: RGBColor?) -> CGImage {
        image(width: 603, height: 1311) { context in
            fill(context, CGRect(x: 0, y: 0, width: 603, height: 1311), pageGray)
            if let appBars {
                fill(context, CGRect(x: 0, y: 0, width: 603, height: 170), appBars)
                fill(context, CGRect(x: 0, y: 1220, width: 603, height: 91), appBars)
            }
            let card = CGRect(x: 30, y: 210, width: 543, height: 970)
            fill(context, card, white, cornerRadius: 18)
            if let header {
                context.saveGState()
                context.addPath(CGPath(roundedRect: card, cornerWidth: 18, cornerHeight: 18, transform: nil))
                context.clip()
                fill(context, CGRect(x: card.minX, y: card.minY, width: card.width, height: 150), header)
                context.restoreGState()
            }
            qrCode(context, in: CGRect(x: 181, y: 520, width: 240, height: 240))
        }
    }

    /// A printed page: a bordered ticket box with a colored header, and a large ad below it.
    static func pageWithAd(header: RGBColor, ad: RGBColor) -> CGImage {
        image(width: 850, height: 1200) { context in
            fill(context, CGRect(x: 0, y: 0, width: 850, height: 1200), white)
            let box = CGRect(x: 50, y: 50, width: 750, height: 650)
            fill(context, CGRect(x: box.minX, y: box.minY, width: box.width, height: 120), header)
            context.setStrokeColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
            context.setLineWidth(3)
            context.stroke(box)
            qrCode(context, in: CGRect(x: 305, y: 300, width: 240, height: 240))
            fill(context, CGRect(x: 50, y: 750, width: 750, height: 400), ad)
        }
    }

    /// A photo: a slightly turned white paper ticket with a colored band, on a colored table.
    static func photo(band: RGBColor, table: RGBColor) -> CGImage {
        image(width: 600, height: 800) { context in
            fill(context, CGRect(x: 0, y: 0, width: 600, height: 800), table)
            context.translateBy(x: 300, y: 400)
            context.rotate(by: 0.06)
            context.translateBy(x: -300, y: -400)
            let paper = CGRect(x: 100, y: 100, width: 400, height: 600)
            fill(context, paper, white, cornerRadius: 14)
            context.saveGState()
            context.addPath(CGPath(roundedRect: paper, cornerWidth: 14, cornerHeight: 14, transform: nil))
            context.clip()
            fill(context, CGRect(x: paper.minX, y: paper.minY, width: paper.width, height: 90), band)
            context.restoreGState()
            qrCode(context, in: CGRect(x: 180, y: 300, width: 240, height: 240))
        }
    }
}

extension RGBColor {
    /// Hue from 0 to 1.
    var hue: Double {
        let maximum = max(red, green, blue), minimum = min(red, green, blue), delta = maximum - minimum
        guard delta > 0 else { return 0 }
        var hue: Double
        if maximum == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue /= 6
        return hue < 0 ? hue + 1 : hue
    }
}
