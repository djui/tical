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
