import Foundation
import Security

/// The Pass Type ID certificate that signs passes, and the certificates that link it to Apple.
nonisolated struct SigningCertificate: Equatable, Sendable {
    let certificate: X509Certificate
    let intermediates: [X509Certificate]

    var passTypeIdentifier: String { certificate.userID ?? "" }
    var teamIdentifier: String { certificate.organizationalUnit ?? "" }
    var ownerName: String { certificate.organizationName ?? "" }
    var expires: Date? { certificate.notAfter }
    var isExpired: Bool { expires.map { $0 < Date() } ?? false }

    static func isPassTypeCertificate(_ certificate: X509Certificate) -> Bool {
        (certificate.userID?.hasPrefix("pass.") ?? false) && !(certificate.organizationalUnit ?? "").isEmpty
    }
}

/// A signing request created on this iPhone, waiting for its certificate.
nonisolated struct PendingSigningRequest: Codable, Equatable, Sendable {
    var pem: String
    var createdAt: Date

    /// Writes the request to a file named the way Keychain Access names them, for sharing.
    func writeFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Tical.certSigningRequest")
        try? Data(pem.utf8).write(to: url, options: .atomic)
        return url
    }
}

/// What pass building needs: the private key and the certificate chain.
nonisolated struct PassCredentials: @unchecked Sendable {
    let privateKey: SecKey
    let signing: SigningCertificate
}

/// Sets up and keeps the pass signing identity. The private key is created on this iPhone
/// (or imported from a .p12 file) and never leaves the keychain.
@MainActor
@Observable
final class PassSigningStore {
    enum SetupError: LocalizedError {
        case notConfigured
        case notAPassTypeCertificate
        case keyMismatch
        case wrongPassword
        case unreadableFile
        case expired(Date)
        case missingIntermediate

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                String(localized: "Set up Wallet passes in Settings first.")
            case .notAPassTypeCertificate:
                String(localized: "That isn't a Pass Type ID certificate. In your Apple Developer account, create the certificate under Pass Type IDs.")
            case .keyMismatch:
                String(localized: "That certificate was made for a different signing request. Upload the request from this iPhone and import the certificate Apple returns.")
            case .wrongPassword:
                String(localized: "That password doesn't open the .p12 file.")
            case .unreadableFile:
                String(localized: "Tical couldn't read a certificate from that file.")
            case .expired(let date):
                String(localized: "The certificate expired on \(date.formatted(date: .abbreviated, time: .omitted)). Create a new one to keep making passes.")
            case .missingIntermediate:
                String(localized: "Tical couldn't get Apple's intermediate certificate, which Wallet needs. Connect to the internet and try again.")
            }
        }
    }

    private(set) var certificate: SigningCertificate?
    private(set) var pendingRequest: PendingSigningRequest?

    /// True when passes can be signed right now.
    var isReady: Bool { certificate.map { !$0.isExpired } ?? false }

    private enum Storage {
        static let certificate = "certificate"
        static let pendingRequest = "pending-request"
        static let activeKey = "com.tical.pass-signing.key"
        static let pendingKey = "com.tical.pass-signing.pending-key"
    }

    private struct StoredCertificate: Codable {
        var certificate: Data
        var intermediates: [Data]
    }

    init() {
        reload()
    }

    func reload() {
        if let data = Keychain.data(for: Storage.certificate),
           let stored = try? JSONDecoder().decode(StoredCertificate.self, from: data),
           let leaf = try? X509Certificate(der: stored.certificate),
           Keychain.privateKey(tag: Storage.activeKey) != nil {
            certificate = SigningCertificate(
                certificate: leaf,
                intermediates: stored.intermediates.compactMap { try? X509Certificate(der: $0) }
            )
        } else {
            certificate = nil
        }
        pendingRequest = Keychain.data(for: Storage.pendingRequest)
            .flatMap { try? JSONDecoder().decode(PendingSigningRequest.self, from: $0) }
    }

    // MARK: - Setup

    /// Creates a new private key on this iPhone and a certificate signing request for it.
    func createRequest() async throws -> PendingSigningRequest {
        let tag = Storage.pendingKey
        let request = try await Task.detached(priority: .userInitiated) {
            let key = try Keychain.makePrivateKey(tag: tag)
            guard let publicKey = Keychain.publicKeyBytes(of: key) else { throw SetupError.unreadableFile }
            let der = try CertificateSigningRequest.make(commonName: "Tical Pass Signing", rsaPublicKey: publicKey) {
                try Keychain.sign($0, with: key)
            }
            return PendingSigningRequest(pem: CertificateSigningRequest.pem(der), createdAt: Date())
        }.value
        try Keychain.setData(JSONEncoder().encode(request), for: Storage.pendingRequest)
        pendingRequest = request
        return request
    }

    /// Imports the certificate Apple issued for a request from this iPhone. A PEM file may
    /// also carry the intermediate certificate.
    func importCertificate(_ data: Data) async throws {
        let certificates = Self.certificates(in: data)
        guard !certificates.isEmpty else { throw SetupError.unreadableFile }
        guard let leaf = certificates.first(where: SigningCertificate.isPassTypeCertificate) else {
            throw SetupError.notAPassTypeCertificate
        }
        if let expires = leaf.notAfter, expires < Date() { throw SetupError.expired(expires) }
        guard let certificateKey = Self.publicKeyBytes(of: leaf) else { throw SetupError.unreadableFile }

        let pendingKey = Keychain.privateKey(tag: Storage.pendingKey)
        let activeKey = Keychain.privateKey(tag: Storage.activeKey)
        let matchesPending = pendingKey.flatMap(Keychain.publicKeyBytes(of:)) == certificateKey
        let matchesActive = activeKey.flatMap(Keychain.publicKeyBytes(of:)) == certificateKey
        guard matchesPending || matchesActive else { throw SetupError.keyMismatch }

        let intermediates = try await Self.intermediates(for: leaf, candidates: certificates)
        if matchesPending {
            try Keychain.retagKey(from: Storage.pendingKey, to: Storage.activeKey)
            Keychain.deleteData(for: Storage.pendingRequest)
        }
        try save(leaf, intermediates: intermediates)
    }

    /// Imports a Pass Type ID certificate and its private key, exported from Keychain Access.
    func importPKCS12(_ data: Data, password: String) async throws {
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status != errSecAuthFailed else { throw SetupError.wrongPassword }
        guard status == errSecSuccess,
              let entries = items as? [[String: Any]],
              let entry = entries.first,
              let identityValue = entry[kSecImportItemIdentity as String],
              CFGetTypeID(identityValue as CFTypeRef) == SecIdentityGetTypeID() else {
            throw SetupError.unreadableFile
        }
        let identity = identityValue as! SecIdentity
        var privateKey: SecKey?
        var certificateRef: SecCertificate?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              SecIdentityCopyCertificate(identity, &certificateRef) == errSecSuccess,
              let privateKey, let certificateRef,
              let leaf = try? X509Certificate(der: SecCertificateCopyData(certificateRef) as Data) else {
            throw SetupError.unreadableFile
        }
        guard SigningCertificate.isPassTypeCertificate(leaf) else { throw SetupError.notAPassTypeCertificate }
        if let expires = leaf.notAfter, expires < Date() { throw SetupError.expired(expires) }

        let chain = (entry[kSecImportItemCertChain as String] as? [SecCertificate] ?? [])
            .compactMap { try? X509Certificate(der: SecCertificateCopyData($0) as Data) }
        let intermediates = try await Self.intermediates(for: leaf, candidates: chain)
        try Keychain.storePrivateKey(privateKey, tag: Storage.activeKey)
        try save(leaf, intermediates: intermediates)
    }

    func removeCertificate() {
        Keychain.deleteData(for: Storage.certificate)
        Keychain.deleteKey(tag: Storage.activeKey)
        reload()
    }

    func discardRequest() {
        Keychain.deleteData(for: Storage.pendingRequest)
        Keychain.deleteKey(tag: Storage.pendingKey)
        reload()
    }

    func credentials() throws -> PassCredentials {
        guard let certificate, let key = Keychain.privateKey(tag: Storage.activeKey) else {
            throw SetupError.notConfigured
        }
        if certificate.isExpired, let expires = certificate.expires { throw SetupError.expired(expires) }
        return PassCredentials(privateKey: key, signing: certificate)
    }

    private func save(_ leaf: X509Certificate, intermediates: [X509Certificate]) throws {
        let stored = StoredCertificate(certificate: leaf.der, intermediates: intermediates.map(\.der))
        try Keychain.setData(JSONEncoder().encode(stored), for: Storage.certificate)
        reload()
    }

    // MARK: - Certificates

    /// Reads one DER certificate, or every certificate in a PEM file.
    private static func certificates(in data: Data) -> [X509Certificate] {
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
            return text.components(separatedBy: "-----END CERTIFICATE-----").compactMap { block in
                guard block.contains("-----BEGIN CERTIFICATE-----") else { return nil }
                return try? X509Certificate(der: Data((block + "-----END CERTIFICATE-----").utf8))
            }
        }
        return (try? X509Certificate(der: data)).map { [$0] } ?? []
    }

    private static func publicKeyBytes(of certificate: X509Certificate) -> Data? {
        guard let reference = SecCertificateCreateWithData(nil, certificate.der as CFData),
              let key = SecCertificateCopyKey(reference) else { return nil }
        return SecKeyCopyExternalRepresentation(key, nil) as Data?
    }

    /// Finds the certificate that issued `leaf`: among the given candidates, or through the
    /// system, which can download the issuer that the certificate names. For a Pass Type ID
    /// certificate, that's Apple's WWDR intermediate.
    private static func intermediates(for leaf: X509Certificate, candidates: [X509Certificate]) async throws -> [X509Certificate] {
        if let issuer = candidates.first(where: { leaf.isIssued(by: $0) && !$0.isSelfIssued }) {
            return [issuer]
        }
        guard let reference = SecCertificateCreateWithData(nil, leaf.der as CFData) else {
            throw SetupError.unreadableFile
        }
        let chain = await systemChain(for: reference)
        if let issuer = chain.first(where: { leaf.isIssued(by: $0) && !$0.isSelfIssued }) {
            return [issuer]
        }
        throw SetupError.missingIntermediate
    }

    private nonisolated static func systemChain(for certificate: SecCertificate) async -> [X509Certificate] {
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { return [] }
        SecTrustSetNetworkFetchAllowed(trust, true)
        let box = TrustBox(trust: trust)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.tical.trust")
            queue.async {
                SecTrustEvaluateAsyncWithError(box.trust, queue) { _, _, _ in
                    continuation.resume()
                }
            }
        }
        let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? []
        return certificates.dropFirst().compactMap { try? X509Certificate(der: SecCertificateCopyData($0) as Data) }
    }

    private nonisolated final class TrustBox: @unchecked Sendable {
        let trust: SecTrust
        init(trust: SecTrust) { self.trust = trust }
    }
}
