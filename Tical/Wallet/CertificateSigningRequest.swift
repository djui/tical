import Foundation

/// A PKCS #10 certificate signing request for an RSA key, in the form the Apple Developer
/// website accepts when you create a Pass Type ID certificate.
nonisolated enum CertificateSigningRequest {
    /// - Parameters:
    ///   - rsaPublicKey: A PKCS #1 `RSAPublicKey`, as `SecKeyCopyExternalRepresentation` returns it.
    ///   - sign: Signs its argument with the matching private key using RSA PKCS #1 v1.5 and SHA-256.
    /// - Returns: The DER encoding of the request.
    static func make(commonName: String, rsaPublicKey: Data, sign: (Data) throws -> Data) rethrows -> Data {
        let subject = DER.sequence([
            DER.set([DER.sequence([DER.objectIdentifier(OID.commonName), DER.utf8String(commonName)])]),
        ])
        let subjectPublicKeyInfo = DER.sequence([
            DER.algorithmIdentifier(OID.rsaEncryption),
            DER.bitString(rsaPublicKey),
        ])
        let requestInfo = DER.sequence([
            DER.integer(0),
            subject,
            subjectPublicKeyInfo,
            DER.context(0, Data()),
        ])
        let signature = try sign(requestInfo)
        return DER.sequence([
            requestInfo,
            DER.algorithmIdentifier(OID.sha256WithRSAEncryption),
            DER.bitString(signature),
        ])
    }

    static func pem(_ der: Data) -> String {
        DER.pem(der, label: "CERTIFICATE REQUEST")
    }
}
