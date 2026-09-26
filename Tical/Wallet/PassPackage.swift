import CryptoKit
import Foundation

/// The files of a pass, and the step that turns them into a signed `.pkpass` archive:
/// `manifest.json` lists the SHA-1 of every file, and `signature` signs the manifest.
nonisolated struct PassPackage {
    /// File name to contents, for example `pass.json` and `icon@2x.png`.
    var files: [String: Data]

    func manifest() throws -> Data {
        let hashes = files.mapValues { data in
            Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return try JSONSerialization.data(withJSONObject: hashes, options: [.sortedKeys, .prettyPrinted])
    }

    /// The `.pkpass` archive: every file, the manifest, and the manifest's signature.
    func archive(manifest: Data, signature: Data) -> Data {
        var entries = files.keys.sorted().map { ZipArchive.Entry(name: $0, data: files[$0] ?? Data()) }
        entries.append(ZipArchive.Entry(name: "manifest.json", data: manifest))
        entries.append(ZipArchive.Entry(name: "signature", data: signature))
        return ZipArchive.stored(entries)
    }
}
