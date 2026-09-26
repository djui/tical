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

    func signedArchive(
        signer: X509Certificate,
        intermediates: [X509Certificate],
        sign: (Data) throws -> Data
    ) throws -> Data {
        let manifest = try manifest()
        let signature = try CMSSignature.detached(
            content: manifest,
            signer: signer,
            intermediates: intermediates,
            sign: sign
        )
        var entries = files.keys.sorted().map { ZipArchive.Entry(name: $0, data: files[$0] ?? Data()) }
        entries.append(ZipArchive.Entry(name: "manifest.json", data: manifest))
        entries.append(ZipArchive.Entry(name: "signature", data: signature))
        return ZipArchive.stored(entries)
    }
}
