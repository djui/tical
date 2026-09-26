import CryptoKit
import Foundation

/// Builds the detached PKCS #7 / CMS `SignedData` that Wallet expects in a pass's `signature` file.
///
/// The structure matches what Apple's `signpass` and OpenSSL produce: SHA-256 digest, RSA
/// PKCS #1 v1.5 signature, signed attributes for content type, signing time, and message
/// digest, and the signer certificate plus the WWDR intermediate in the certificate set.
nonisolated enum CMSSignature {
    /// - Parameters:
    ///   - content: The bytes being signed. For a pass, that is `manifest.json`.
    ///   - signer: The Pass Type ID certificate.
    ///   - intermediates: Certificates that link the signer to Apple's root, usually the WWDR intermediate.
    ///   - sign: Signs its argument with the signer's private key using RSA PKCS #1 v1.5 and SHA-256.
    static func detached(
        content: Data,
        signer: X509Certificate,
        intermediates: [X509Certificate],
        signingTime: Date = Date(),
        sign: (Data) throws -> Data
    ) rethrows -> Data {
        let digest = Data(SHA256.hash(data: content))
        let attributes = [
            attribute(OID.contentType, value: DER.objectIdentifier(OID.data)),
            attribute(OID.signingTime, value: DER.utcTime(signingTime)),
            attribute(OID.messageDigest, value: DER.octetString(digest)),
        ]
        // The signature covers the attributes encoded as a SET; the SignerInfo carries the
        // same bytes under an implicit [0] tag.
        let signedAttributes = DER.set(attributes)
        let signature = try sign(signedAttributes)

        let signerInfo = DER.sequence([
            DER.integer(1),
            DER.sequence([signer.issuer, signer.serialNumber]),
            DER.algorithmIdentifier(OID.sha256),
            DER.context(0, DER.setContents(attributes)),
            DER.algorithmIdentifier(OID.rsaEncryption),
            DER.octetString(signature),
        ])

        let certificates = ([signer] + intermediates).reduce(into: Data()) { $0.append($1.der) }
        let signedData = DER.sequence([
            DER.integer(1),
            DER.set([DER.algorithmIdentifier(OID.sha256)]),
            DER.sequence([DER.objectIdentifier(OID.data)]),
            DER.context(0, certificates),
            DER.set([signerInfo]),
        ])

        return DER.sequence([
            DER.objectIdentifier(OID.signedData),
            DER.context(0, signedData),
        ])
    }

    private static func attribute(_ type: String, value: Data) -> Data {
        DER.sequence([DER.objectIdentifier(type), DER.set([value])])
    }
}
