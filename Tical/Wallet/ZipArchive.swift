import Foundation

/// Writes an uncompressed ZIP archive. A `.pkpass` is a ZIP, and its files are small enough
/// that storing them without compression costs little.
nonisolated enum ZipArchive {
    struct Entry {
        let name: String
        let data: Data
    }

    static func stored(_ entries: [Entry], modified: Date = Date()) -> Data {
        let (time, date) = dosTimestamp(modified)
        var archive = Data()
        var directory = Data()

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(archive.count)

            archive.append(le32: 0x0403_4B50)
            archive.append(le16: 20) // version needed to extract
            archive.append(le16: 0) // flags
            archive.append(le16: 0) // stored
            archive.append(le16: time)
            archive.append(le16: date)
            archive.append(le32: crc)
            archive.append(le32: size)
            archive.append(le32: size)
            archive.append(le16: UInt16(name.count))
            archive.append(le16: 0) // extra field length
            archive.append(name)
            archive.append(entry.data)

            directory.append(le32: 0x0201_4B50)
            directory.append(le16: 20) // version made by
            directory.append(le16: 20) // version needed to extract
            directory.append(le16: 0)
            directory.append(le16: 0)
            directory.append(le16: time)
            directory.append(le16: date)
            directory.append(le32: crc)
            directory.append(le32: size)
            directory.append(le32: size)
            directory.append(le16: UInt16(name.count))
            directory.append(le16: 0) // extra field length
            directory.append(le16: 0) // comment length
            directory.append(le16: 0) // disk number
            directory.append(le16: 0) // internal attributes
            directory.append(le32: 0) // external attributes
            directory.append(le32: offset)
            directory.append(name)
        }

        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32: 0x0605_4B50)
        archive.append(le16: 0)
        archive.append(le16: 0)
        archive.append(le16: UInt16(entries.count))
        archive.append(le16: UInt16(entries.count))
        archive.append(le32: UInt32(directory.count))
        archive.append(le32: directoryOffset)
        archive.append(le16: 0) // comment length
        return archive
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            in: .current,
            from: date
        )
        let year = max(1980, parts.year ?? 1980)
        let time = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
        let day = UInt16((year - 1980) << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        return (time, day)
    }
}

private extension Data {
    nonisolated mutating func append(le16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    nonisolated mutating func append(le32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8(value >> 24),
        ])
    }
}
