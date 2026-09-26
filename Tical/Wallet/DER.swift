import Foundation

/// The small subset of ASN.1 DER that Wallet signing needs: building CMS and PKCS #10
/// structures, and reading the issuer, serial number, and subject out of a certificate.
nonisolated enum DER {
    enum ParseError: Error {
        case truncated
        case unsupportedLength
        case unexpectedTag(expected: UInt8, found: UInt8)
    }

    enum Tag {
        static let integer: UInt8 = 0x02
        static let bitString: UInt8 = 0x03
        static let octetString: UInt8 = 0x04
        static let null: UInt8 = 0x05
        static let objectIdentifier: UInt8 = 0x06
        static let utf8String: UInt8 = 0x0C
        static let printableString: UInt8 = 0x13
        static let teletexString: UInt8 = 0x14
        static let ia5String: UInt8 = 0x16
        static let utcTime: UInt8 = 0x17
        static let generalizedTime: UInt8 = 0x18
        static let bmpString: UInt8 = 0x1E
        static let sequence: UInt8 = 0x30
        static let set: UInt8 = 0x31
    }

    // MARK: - Encoding

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var encoded = Data([tag])
        encoded.append(length(content.count))
        encoded.append(content)
        return encoded
    }

    static func sequence(_ elements: [Data]) -> Data {
        tlv(Tag.sequence, elements.reduce(into: Data()) { $0.append($1) })
    }

    /// A SET OF, with its elements in the ascending byte order DER requires.
    static func set(_ elements: [Data]) -> Data {
        tlv(Tag.set, setContents(elements))
    }

    /// The contents of a DER SET OF without its tag, for `[n] IMPLICIT` encodings of the same set.
    static func setContents(_ elements: [Data]) -> Data {
        elements
            .sorted { $0.lexicographicallyPrecedes($1) }
            .reduce(into: Data()) { $0.append($1) }
    }

    /// A constructed context-specific tag, `[number]`, around already encoded contents.
    static func context(_ number: UInt8, _ content: Data) -> Data {
        tlv(0xA0 | number, content)
    }

    static func integer(_ value: Int) -> Data {
        precondition(value >= 0, "Only non-negative integers are needed here.")
        var bytes: [UInt8] = []
        var remaining = value
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        return integer(unsignedBigEndian: Data(bytes))
    }

    static func integer(unsignedBigEndian bytes: Data) -> Data {
        var trimmed = Data(bytes.drop { $0 == 0 })
        if trimmed.isEmpty || trimmed[trimmed.startIndex] & 0x80 != 0 {
            trimmed.insert(0, at: 0)
        }
        return tlv(Tag.integer, trimmed)
    }

    static func objectIdentifier(_ dotted: String) -> Data {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        precondition(arcs.count >= 2, "An object identifier needs at least two arcs.")
        var content = base128(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) {
            content.append(base128(arc))
        }
        return tlv(Tag.objectIdentifier, content)
    }

    static let null = Data([Tag.null, 0x00])

    static func octetString(_ data: Data) -> Data {
        tlv(Tag.octetString, data)
    }

    static func bitString(_ data: Data) -> Data {
        var content = Data([0x00])
        content.append(data)
        return tlv(Tag.bitString, content)
    }

    static func utf8String(_ string: String) -> Data {
        tlv(Tag.utf8String, Data(string.utf8))
    }

    /// UTCTime, `YYMMDDHHMMSSZ`, which CMS uses for signing times between 1950 and 2049.
    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(Tag.utcTime, Data(formatter.string(from: date).utf8))
    }

    static func algorithmIdentifier(_ oid: String, withNullParameters: Bool = true) -> Data {
        withNullParameters ? sequence([objectIdentifier(oid), null]) : sequence([objectIdentifier(oid)])
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 {
            return Data([UInt8(count)])
        }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func base128(_ value: UInt64) -> Data {
        var bytes: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return Data(bytes)
    }

    // MARK: - Parsing

    struct Node {
        let tag: UInt8
        /// The element's contents, without tag and length.
        let content: Data
        /// The full encoding: tag, length, and contents.
        let encoded: Data

        var isConstructed: Bool { tag & 0x20 != 0 }

        func children() throws -> [Node] {
            try DER.parseAll(content)
        }

        func expect(_ expected: UInt8) throws -> Node {
            guard tag == expected else { throw ParseError.unexpectedTag(expected: expected, found: tag) }
            return self
        }
    }

    /// Parses the first element in `data` and ignores anything after it.
    static func parse(_ data: Data) throws -> Node {
        let bytes = [UInt8](data)
        var offset = 0
        return try parseElement(bytes, &offset)
    }

    static func parseAll(_ data: Data) throws -> [Node] {
        let bytes = [UInt8](data)
        var offset = 0
        var nodes: [Node] = []
        while offset < bytes.count {
            nodes.append(try parseElement(bytes, &offset))
        }
        return nodes
    }

    private static func parseElement(_ bytes: [UInt8], _ offset: inout Int) throws -> Node {
        let start = offset
        guard offset + 2 <= bytes.count else { throw ParseError.truncated }
        let tag = bytes[offset]
        guard tag & 0x1F != 0x1F else { throw ParseError.unsupportedLength }
        offset += 1
        var length = Int(bytes[offset])
        offset += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, offset + count <= bytes.count else { throw ParseError.unsupportedLength }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[offset])
                offset += 1
            }
        }
        guard offset + length <= bytes.count else { throw ParseError.truncated }
        let content = Data(bytes[offset..<(offset + length)])
        let encoded = Data(bytes[start..<(offset + length)])
        offset += length
        return Node(tag: tag, content: content, encoded: encoded)
    }

    static func objectIdentifierString(_ content: Data) -> String {
        var arcs: [UInt64] = []
        var value: UInt64 = 0
        for byte in content {
            value = (value << 7) | UInt64(byte & 0x7F)
            if byte & 0x80 == 0 {
                if arcs.isEmpty {
                    let first: UInt64 = value < 80 ? value / 40 : 2
                    arcs.append(first)
                    arcs.append(value - first * 40)
                } else {
                    arcs.append(value)
                }
                value = 0
            }
        }
        return arcs.map(String.init).joined(separator: ".")
    }

    static func string(from node: Node) -> String? {
        switch node.tag {
        case Tag.utf8String, Tag.printableString, Tag.ia5String:
            return String(data: node.content, encoding: .utf8)
        case Tag.teletexString:
            return String(data: node.content, encoding: .isoLatin1)
        case Tag.bmpString:
            return String(data: node.content, encoding: .utf16BigEndian)
        default:
            return nil
        }
    }

    static func date(from node: Node) -> Date? {
        guard let text = String(data: node.content, encoding: .ascii) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        switch node.tag {
        case Tag.utcTime:
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            formatter.twoDigitStartDate = Date(timeIntervalSince1970: -631_152_000) // 1950-01-01, per RFC 5280
            return formatter.date(from: text)
        case Tag.generalizedTime:
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return formatter.date(from: text)
        default:
            return nil
        }
    }

    // MARK: - PEM

    /// Decodes the first PEM block with the given label, or returns `data` unchanged when it is not PEM.
    static func unwrapPEM(_ data: Data, label: String? = nil) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") else { return data }
        let lines = text.components(separatedBy: .newlines)
        var body = ""
        var inside = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-----BEGIN") {
                if let label, !trimmed.contains(label) { continue }
                inside = true
                continue
            }
            if trimmed.hasPrefix("-----END") {
                if inside { break }
                continue
            }
            if inside { body += trimmed }
        }
        return Data(base64Encoded: body) ?? data
    }

    static func pem(_ data: Data, label: String) -> String {
        let base64 = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }
}

nonisolated enum OID {
    static let signedData = "1.2.840.113549.1.7.2"
    static let data = "1.2.840.113549.1.7.1"
    static let sha256 = "2.16.840.1.101.3.4.2.1"
    static let rsaEncryption = "1.2.840.113549.1.1.1"
    static let sha256WithRSAEncryption = "1.2.840.113549.1.1.11"
    static let contentType = "1.2.840.113549.1.9.3"
    static let messageDigest = "1.2.840.113549.1.9.4"
    static let signingTime = "1.2.840.113549.1.9.5"
    static let commonName = "2.5.4.3"
    static let countryName = "2.5.4.6"
    static let organizationName = "2.5.4.10"
    static let organizationalUnitName = "2.5.4.11"
    static let userID = "0.9.2342.19200300.100.1.1"
}
