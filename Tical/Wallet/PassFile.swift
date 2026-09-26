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
            let credentials = try await file.signing.credentials()
            let data = try PassBuilder.archive(for: file.content, credentials: credentials)
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
