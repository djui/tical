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
        let identity = try TestIdentity.passType("pass.example.tickets", team: "ABCDE12345")
        let signing = SigningCertificate(certificate: identity.certificate, intermediates: [])
        let data = try PassBuilder.passJSON(for: content(), signing: signing)
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
    }

    @Test func buildsSignedArchive() throws {
        let identity = try TestIdentity.passType()
        let credentials = PassCredentials(
            privateKey: identity.key,
            signing: SigningCertificate(certificate: identity.certificate, intermediates: [])
        )
        let archive = try PassBuilder.archive(for: content(), credentials: credentials)
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
}
