import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// A Wallet pass, declared by the system.
    nonisolated static let walletPass = UTType("com.apple.pkpass") ?? .data
}

/// A signed .pkpass file for the share sheet, built only when the share sheet asks for it.
struct PassFile: Transferable {
    let content: PassContent
    let signing: PassSigningStore

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .walletPass) { file in
            let signer = try await file.signing.signer()
            let data = try await PassBuilder.archive(for: file.content, signer: signer)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(file.fileName)
                .appendingPathExtension("pkpass")
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    private nonisolated var fileName: String {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = content.draft.displayTitle.components(separatedBy: unsafe).joined(separator: " ")
        return String(cleaned.trimmingCharacters(in: .whitespaces).prefix(60))
    }
}
