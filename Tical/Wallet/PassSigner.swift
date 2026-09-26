import Foundation

/// The pass type and team a pass names in `pass.json`, which must match the certificate that signs it.
nonisolated struct PassType: Codable, Equatable, Sendable {
    var passTypeIdentifier: String
    var teamIdentifier: String
}

/// Turns a pass's `manifest.json` into its `signature` file: on this device with your own
/// certificate, or on Tical's server with Tical's certificate.
nonisolated struct PassSigner: Sendable {
    let passType: PassType
    let sign: @Sendable (_ manifest: Data) async throws -> Data

    static func certificate(_ credentials: PassCredentials) -> PassSigner {
        let signing = credentials.signing
        let passType = PassType(passTypeIdentifier: signing.passTypeIdentifier, teamIdentifier: signing.teamIdentifier)
        return PassSigner(passType: passType) { manifest in
            try CMSSignature.detached(content: manifest, signer: signing.certificate, intermediates: signing.intermediates) {
                try Keychain.sign($0, with: credentials.privateKey)
            }
        }
    }

    static func service(_ service: PassSigningService) async throws -> PassSigner {
        let passType = try await service.passType()
        return PassSigner(passType: passType) { manifest in
            try await service.signature(for: manifest, passType: passType)
        }
    }
}
