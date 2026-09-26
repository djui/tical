import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Tical

struct DERTests {
    @Test func encodesObjectIdentifiers() {
        #expect(DER.objectIdentifier(OID.sha256) == Data(hex: "0609608648016503040201"))
        #expect(DER.objectIdentifier(OID.signedData) == Data(hex: "06092a864886f70d010702"))
    }

    @Test func encodesIntegersWithSignPadding() {
        #expect(DER.integer(1) == Data(hex: "020101"))
        #expect(DER.integer(128) == Data(hex: "02020080"))
        #expect(DER.integer(unsignedBigEndian: Data(hex: "0000ff")) == Data(hex: "020200ff"))
    }

    @Test func encodesLongLengths() {
        let content = Data(repeating: 7, count: 300)
        let encoded = DER.octetString(content)
        #expect(encoded.prefix(4) == Data(hex: "0482012c"))
        #expect(encoded.count == 304)
    }

    @Test func sortsSetElements() {
        let set = DER.set([Data(hex: "0402bbbb"), Data(hex: "0401aa")])
        #expect(set == Data(hex: "31070401aa0402bbbb"))
    }

    @Test func roundTripsObjectIdentifierStrings() throws {
        let node = try DER.parse(DER.objectIdentifier(OID.userID))
        #expect(DER.objectIdentifierString(node.content) == OID.userID)
    }
}

struct CertificateTests {
    @Test func readsPassTypeFieldsFromSubject() throws {
        let identity = try TestIdentity.passType("pass.example.tickets", team: "ABCDE12345")
        let certificate = identity.certificate
        #expect(certificate.userID == "pass.example.tickets")
        #expect(certificate.organizationalUnit == "ABCDE12345")
        #expect(certificate.organizationName == "Test Developer")
        #expect(certificate.isSelfIssued)
        #expect(SigningCertificate.isPassTypeCertificate(certificate))
        let expires = try #require(certificate.notAfter)
        #expect(expires > Date())
    }

    @Test func acceptsPEM() throws {
        let identity = try TestIdentity.passType()
        let pem = DER.pem(identity.certificate.der, label: "CERTIFICATE")
        let parsed = try X509Certificate(der: Data(pem.utf8))
        #expect(parsed == identity.certificate)
    }
}

struct CMSSignatureTests {
    @Test func signsDetachedContentVerifiably() throws {
        let identity = try TestIdentity.passType()
        let content = Data(#"{"pass.json":"0123"}"#.utf8)
        let signature = try CMSSignature.detached(content: content, signer: identity.certificate, intermediates: []) {
            try Keychain.sign($0, with: identity.key)
        }

        // ContentInfo → [0] → SignedData
        let contentInfo = try DER.parse(signature).children()
        #expect(DER.objectIdentifierString(contentInfo[0].content) == OID.signedData)
        let signedData = try contentInfo[1].children()[0].children()
        #expect(signedData.count == 5)
        #expect(signedData[3].tag == 0xA0)
        #expect(signedData[3].content == identity.certificate.der)

        let signerInfo = try signedData[4].children()[0].children()
        let issuerAndSerial = try signerInfo[1].children()
        #expect(issuerAndSerial[0].encoded == identity.certificate.issuer)
        #expect(issuerAndSerial[1].encoded == identity.certificate.serialNumber)

        // The signature covers the signed attributes encoded as a SET.
        let signedAttributes = signerInfo[3]
        #expect(signedAttributes.tag == 0xA0)
        let signedBytes = DER.tlv(DER.Tag.set, signedAttributes.content)
        #expect(TestIdentity.verify(signerInfo[5].content, of: signedBytes, with: identity.certificate))

        // And the message digest attribute matches the content.
        var digest: Data?
        for attribute in try signedAttributes.children() {
            let parts = try attribute.children()
            if DER.objectIdentifierString(parts[0].content) == OID.messageDigest {
                digest = try parts[1].children().first?.content
            }
        }
        #expect(digest == Data(SHA256.hash(data: content)))
    }

    @Test func includesIntermediates() throws {
        let signer = try TestIdentity.passType()
        let other = try TestIdentity.passType("pass.other")
        let signature = try CMSSignature.detached(content: Data("x".utf8), signer: signer.certificate, intermediates: [other.certificate]) {
            try Keychain.sign($0, with: signer.key)
        }
        let signedData = try DER.parse(signature).children()[1].children()[0].children()
        #expect(signedData[3].content == signer.certificate.der + other.certificate.der)
    }
}

struct CertificateSigningRequestTests {
    @Test func producesSelfSignedRequest() throws {
        let key = try TestIdentity.makeKey()
        let publicKey = try #require(Keychain.publicKeyBytes(of: key))
        let der = try CertificateSigningRequest.make(commonName: "Tical Pass Signing", rsaPublicKey: publicKey) {
            try Keychain.sign($0, with: key)
        }
        let parts = try DER.parse(der).children()
        #expect(parts.count == 3)
        let info = parts[0]
        let signature = parts[2].content.dropFirst() // BIT STRING: skip the unused-bits byte
        let verifyingKey = try #require(SecKeyCopyPublicKey(key))
        #expect(SecKeyVerifySignature(verifyingKey, .rsaSignatureMessagePKCS1v15SHA256, info.encoded as CFData, Data(signature) as CFData, nil))
        #expect(CertificateSigningRequest.pem(der).hasPrefix("-----BEGIN CERTIFICATE REQUEST-----"))
    }
}

struct ZipArchiveTests {
    @Test func computesStandardCRC() {
        #expect(ZipArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func storesEntriesReadably() {
        let archive = ZipArchive.stored([
            .init(name: "pass.json", data: Data("{}".utf8)),
            .init(name: "icon.png", data: Data([1, 2, 3])),
        ])
        #expect(archive.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
        let entries = StoredZip.entries(of: archive)
        #expect(entries["pass.json"] == Data("{}".utf8))
        #expect(entries["icon.png"] == Data([1, 2, 3]))
        // End of central directory lists both entries.
        let end = archive.suffix(22)
        #expect(end.prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]))
        #expect(end[end.startIndex + 10] == 2)
    }
}

@MainActor
struct PassBuilderTests {
    private func content() -> PassContent {
        var draft = TicketDraft()
        draft.title = "The Midnight Owls"
        draft.location = "Uber Arena, Berlin"
        draft.start = Date(timeIntervalSince1970: 1_792_260_000)
        draft.seatInfo = "Block C · Row 12 · Seat 7"
        draft.confirmationCode = "TKT-8842-XK"
        let barcode = WalletBarcode(DetectedBarcode(symbology: .qr, text: "MOWL-2026", bytes: nil, bounds: .zero))
        return PassContent(draft: draft, barcode: barcode, color: .brand, serialNumber: "SERIAL-1")
    }

    @Test func writesPassJSON() throws {
        let passType = PassType(passTypeIdentifier: "pass.example.tickets", teamIdentifier: "ABCDE12345")
        let data = try PassBuilder.passJSON(for: content(), passType: passType)
        let pass = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(pass["formatVersion"] as? Int == 1)
        #expect(pass["passTypeIdentifier"] as? String == "pass.example.tickets")
        #expect(pass["teamIdentifier"] as? String == "ABCDE12345")
        #expect(pass["serialNumber"] as? String == "SERIAL-1")
        #expect((pass["backgroundColor"] as? String)?.hasPrefix("rgb(") == true)
        #expect(pass["relevantDate"] is String)

        let barcode = try #require((pass["barcodes"] as? [[String: Any]])?.first)
        #expect(barcode["format"] as? String == "PKBarcodeFormatQR")
        #expect(barcode["message"] as? String == "MOWL-2026")
        #expect(barcode["messageEncoding"] as? String == "iso-8859-1")
        #expect(barcode["altText"] as? String == "TKT-8842-XK")

        let ticket = try #require(pass["eventTicket"] as? [String: Any])
        let primary = try #require((ticket["primaryFields"] as? [[String: Any]])?.first)
        #expect(primary["value"] as? String == "The Midnight Owls")

        // The day in the header, and only the time below it.
        let header = try #require((ticket["headerFields"] as? [[String: Any]])?.first)
        #expect(header["key"] as? String == "date")
        #expect(header["dateStyle"] as? String == "PKDateStyleShort")
        #expect(header["timeStyle"] as? String == "PKDateStyleNone")
        let secondary = try #require(ticket["secondaryFields"] as? [[String: Any]])
        #expect(secondary.compactMap { $0["key"] as? String } == ["starts", "venue"])
        #expect(secondary[0]["dateStyle"] as? String == "PKDateStyleNone")
        #expect(secondary[0]["timeStyle"] as? String == "PKDateStyleShort")
    }

    @Test func leavesOutAnAssumedStartTime() throws {
        var dateOnly = content()
        dateOnly.draft.startTimeIsAssumed = true
        let passType = PassType(passTypeIdentifier: "pass.example.tickets", teamIdentifier: "ABCDE12345")
        let data = try PassBuilder.passJSON(for: dateOnly, passType: passType)
        let pass = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ticket = try #require(pass["eventTicket"] as? [String: Any])
        #expect((ticket["headerFields"] as? [[String: Any]])?.first?["key"] as? String == "date")
        #expect((ticket["secondaryFields"] as? [[String: Any]])?.compactMap { $0["key"] as? String } == ["venue"])
    }

    @Test func buildsSignedArchive() async throws {
        let identity = try TestIdentity.passType()
        let credentials = PassCredentials(
            privateKey: identity.key,
            signing: SigningCertificate(certificate: identity.certificate, intermediates: [])
        )
        let archive = try await PassBuilder.archive(for: content(), signer: .certificate(credentials))
        let files = StoredZip.entries(of: archive)
        for name in ["pass.json", "manifest.json", "signature", "icon.png", "icon@2x.png", "icon@3x.png", "logo.png", "logo@2x.png", "logo@3x.png"] {
            #expect(files[name] != nil, "missing \(name)")
        }

        let manifestData = try #require(files["manifest.json"])
        let manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: String])
        #expect(manifest.count == files.count - 2)
        for (name, hash) in manifest {
            let data = try #require(files[name])
            #expect(Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash)
        }

        let signature = try #require(files["signature"])
        let signerInfo = try DER.parse(signature).children()[1].children()[0].children()[4].children()[0].children()
        let signedBytes = DER.tlv(DER.Tag.set, signerInfo[3].content)
        #expect(TestIdentity.verify(signerInfo[5].content, of: signedBytes, with: identity.certificate))
    }

    @Test func blurredBackgroundKeepsTheEventTicket() throws {
        var content = self.content()
        content.background = PassBackground(image: try Self.image(gray: 0.2), style: .blurred)
        let pass = try passJSON(for: content)
        #expect(pass["eventTicket"] != nil)
        #expect(pass["posterGeneric"] == nil)

        let files = PassArtwork.files(for: content)
        #expect(files["background.png"] != nil)
        #expect(files["background@2x.png"] != nil)
        #expect(files["artwork@2x.png"] == nil)
    }

    @Test func posterBackgroundAddsThePosterStyle() throws {
        var content = self.content()
        content.background = PassBackground(image: try Self.image(gray: 0.2), style: .poster)
        let pass = try passJSON(for: content)
        // Devices without poster passes show the event ticket.
        #expect(pass["eventTicket"] != nil)
        let poster = try #require(pass["posterGeneric"] as? [String: Any])
        #expect(Self.keys(poster["primaryFields"]) == ["event", "starts"])
        #expect((poster["primaryFields"] as? [[String: Any]])?.first?["label"] as? String == "Event")
        // Wallet shows one footer line; the rest goes under the pass.
        #expect(Self.keys(poster["footerFields"]) == ["seat"])
        #expect(Self.keys(poster["additionalInfoFields"]) == ["venue", "booking"])

        let files = PassArtwork.files(for: content)
        for name in ["artwork@2x.png", "artwork@3x.png", "background.png", "primaryLogo.png", "primaryLogo@3x.png"] {
            #expect(files[name] != nil, "missing \(name)")
        }
    }

    @Test func posterShowsTheVenueWhenTheTicketHasNoTime() throws {
        var content = self.content()
        content.draft.startTimeIsAssumed = true
        content.background = PassBackground(image: try Self.image(gray: 0.2), style: .poster)
        let poster = try #require(try passJSON(for: content)["posterGeneric"] as? [String: Any])
        #expect(Self.keys(poster["primaryFields"]) == ["event", "venue"])
        #expect(Self.keys(poster["footerFields"]) == ["seat"])
        #expect(Self.keys(poster["additionalInfoFields"]) == ["booking"])
    }

    @Test func posterFooterFallsBackToTheVenue() throws {
        var content = self.content()
        content.draft.seatInfo = ""
        content.background = PassBackground(image: try Self.image(gray: 0.2), style: .poster)
        let poster = try #require(try passJSON(for: content)["posterGeneric"] as? [String: Any])
        #expect(Self.keys(poster["footerFields"]) == ["venue"])
        #expect(Self.keys(poster["additionalInfoFields"]) == ["booking"])
    }

    private static func keys(_ fields: Any?) -> [String] {
        (fields as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
    }

    @Test func backgroundPhotoDecidesTheTextColor() throws {
        #expect(PassBackground(image: try Self.image(gray: 0.95)).color.foreground == .darkText)
        #expect(PassBackground(image: try Self.image(gray: 0.05)).color.foreground == .white)
    }

    @Test func symbolChangesTheLogo() {
        var content = self.content()
        let ticket = PassArtwork.files(for: content)["logo@2x.png"]
        content.symbol = .music
        let music = PassArtwork.files(for: content)["logo@2x.png"]
        #expect(ticket != nil)
        #expect(music != nil)
        #expect(ticket != music)
    }

    private func passJSON(for content: PassContent) throws -> [String: Any] {
        let passType = PassType(passTypeIdentifier: "pass.example.tickets", teamIdentifier: "ABCDE12345")
        let data = try PassBuilder.passJSON(for: content, passType: passType)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A photo of one gray.
    private static func image(gray: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: 40,
            height: 50,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 50))
        return try #require(context.makeImage())
    }
}

struct PassSymbolTests {
    @Test(arguments: PassSymbol.allCases)
    func drawsInsideItsFrame(_ symbol: PassSymbol) {
        let rect = CGRect(x: 10, y: 20, width: 64, height: 40)
        let path = symbol.path(in: rect)
        #expect(!path.isEmpty)
        let bounds = path.boundingBoxOfPath
        #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(bounds))
        // As large as the frame allows: the full height, or the full width for the ticket.
        #expect(bounds.height > rect.height * 0.8)
        #expect(abs(bounds.midX - rect.midX) < rect.width * 0.05)
    }
}
