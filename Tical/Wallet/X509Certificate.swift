import Foundation

/// The parts of an X.509 certificate that pass signing reads. A Pass Type ID certificate
/// names the pass type in its subject `UID` and the team in its subject `OU`.
nonisolated struct X509Certificate: Equatable, Sendable {
    enum ParseError: Error {
        case malformed
    }

    let der: Data
    /// The full DER encoding of the serial number INTEGER, as CMS needs it.
    let serialNumber: Data
    /// The full DER encoding of the issuer Name, as CMS needs it.
    let issuer: Data
    /// The full DER encoding of the subject Name.
    let subject: Data
    let subjectAttributes: [String: String]
    let issuerAttributes: [String: String]
    let notBefore: Date?
    let notAfter: Date?

    init(der input: Data) throws {
        let der = DER.unwrapPEM(input, label: "CERTIFICATE")
        let certificate = try DER.parse(der).expect(DER.Tag.sequence)
        guard let tbs = try certificate.children().first?.expect(DER.Tag.sequence) else {
            throw ParseError.malformed
        }
        var fields = try tbs.children()
        if fields.first?.tag == 0xA0 {
            fields.removeFirst() // [0] EXPLICIT version
        }
        // serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo, ...
        guard fields.count >= 6,
              fields[0].tag == DER.Tag.integer,
              fields[2].tag == DER.Tag.sequence,
              fields[3].tag == DER.Tag.sequence,
              fields[4].tag == DER.Tag.sequence else {
            throw ParseError.malformed
        }
        self.der = der
        serialNumber = fields[0].encoded
        issuer = fields[2].encoded
        subject = fields[4].encoded
        issuerAttributes = try Self.attributes(of: fields[2])
        subjectAttributes = try Self.attributes(of: fields[4])
        let validity = try fields[3].children()
        notBefore = validity.first.flatMap(DER.date(from:))
        notAfter = validity.dropFirst().first.flatMap(DER.date(from:))
    }

    var commonName: String? { subjectAttributes[OID.commonName] }
    var organizationName: String? { subjectAttributes[OID.organizationName] }
    var organizationalUnit: String? { subjectAttributes[OID.organizationalUnitName] }
    var userID: String? { subjectAttributes[OID.userID] }

    var isSelfIssued: Bool { issuer == subject }

    func isIssued(by candidate: X509Certificate) -> Bool {
        issuer == candidate.subject
    }

    /// Reads each RDN's first value, keyed by attribute type OID.
    private static func attributes(of name: DER.Node) throws -> [String: String] {
        var result: [String: String] = [:]
        for rdn in try name.children() {
            for attribute in try rdn.children() {
                let parts = try attribute.children()
                guard parts.count == 2, parts[0].tag == DER.Tag.objectIdentifier,
                      let value = DER.string(from: parts[1]) else { continue }
                let oid = DER.objectIdentifierString(parts[0].content)
                if result[oid] == nil {
                    result[oid] = value
                }
            }
        }
        return result
    }
}
