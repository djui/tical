import CryptoKit
import DeviceCheck
import Foundation

/// Tical's signing server, which signs passes with Tical's own Pass Type ID certificate. It
/// only ever receives the SHA-256 digest of a pass's `manifest.json`, never the ticket.
///
/// App Attest proves each request comes from Tical on a real device. The simulator can't
/// attest, so debug builds there ask without it, which only a development server accepts.
actor PassSigningService {
    enum ServiceError: LocalizedError, Equatable {
        case offline
        case unavailable
        case rateLimited
        case rejected
        case unsupportedDevice
        case passTypeChanged

        var errorDescription: String? {
            switch self {
            case .offline:
                String(localized: "Tical couldn't reach its signing server. Check your internet connection and try again.")
            case .unavailable:
                String(localized: "Tical's signing server isn't available right now. Try again later.")
            case .rateLimited:
                String(localized: "You've made a lot of passes today. Try again tomorrow.")
            case .rejected:
                String(localized: "Tical's signing server didn't accept the request. Try again later.")
            case .unsupportedDevice:
                String(localized: "Tical's signing server needs App Attest, which this device doesn't support.")
            case .passTypeChanged:
                String(localized: "Tical's signing certificate changed while making the pass. Try again.")
            }
        }
    }

    nonisolated let baseURL: URL
    private let session: URLSession
    private let attest: any AppAttesting
    private let defaults: UserDefaults
    private var cachedPassType: PassType?
    private var keyRegistration: Task<String, Error>?

    init(baseURL: URL, session: URLSession = .shared, attest: any AppAttesting = SystemAppAttest(), defaults: UserDefaults = .standard) {
        self.baseURL = baseURL
        self.session = session
        self.attest = attest
        self.defaults = defaults
    }

    /// The server this build uses: the `-TicalSigningServiceURL` launch argument, or the
    /// `TicalSigningServiceURL` Info.plist value. Without one, passes need your own certificate.
    nonisolated static var configuredURL: URL? {
        let value = UserDefaults.standard.string(forKey: "TicalSigningServiceURL")
            ?? Bundle.main.object(forInfoDictionaryKey: "TicalSigningServiceURL") as? String
        guard let value, let url = URL(string: value), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    /// The pass type and team that passes signed here must name.
    func passType() async throws -> PassType {
        if let cachedPassType { return cachedPassType }
        let passType: PassType = try await send(makeRequest("v1/pass-type", method: "GET"))
        cachedPassType = passType
        return passType
    }

    /// Returns the `signature` file for a pass, given its `manifest.json`.
    func signature(for manifest: Data, passType: PassType) async throws -> Data {
        let digest = Data(SHA256.hash(data: manifest))
        let signature: Data
        do {
            signature = try await requestSignature(digest: digest)
        } catch Failure.unknownKey {
            // The server forgot this device's key, for example after a long time unused.
            defaults.removeObject(forKey: keyIDDefaultsKey)
            signature = try await requestSignature(digest: digest)
        }
        guard Self.passType(signedBy: signature) == passType else {
            cachedPassType = nil
            throw ServiceError.passTypeChanged
        }
        return signature
    }

    // MARK: - Requests

    private func requestSignature(digest: Data) async throws -> Data {
        let keyID = try await registeredKeyID()
        let body = try Self.encode(SignatureRequest(keyId: keyID, manifestDigest: digest))
        var request = makeRequest("v1/signatures", body: body)
        if let keyID {
            let assertion = try await attest.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: body)))
            request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-Tical-Assertion")
        }
        let response: SignatureResponse = try await send(request)
        return response.signature
    }

    /// This device's App Attest key, registered with the server on first use.
    private func registeredKeyID() async throws -> String? {
        guard attest.isSupported else {
            #if DEBUG
            return nil
            #else
            throw ServiceError.unsupportedDevice
            #endif
        }
        if let keyID = defaults.string(forKey: keyIDDefaultsKey) { return keyID }
        if let keyRegistration { return try await keyRegistration.value }
        let registration = Task { try await registerKey() }
        keyRegistration = registration
        defer { keyRegistration = nil }
        let keyID = try await registration.value
        defaults.set(keyID, forKey: keyIDDefaultsKey)
        return keyID
    }

    private func registerKey() async throws -> String {
        let keyID = try await attest.generateKey()
        let challenge: ChallengeResponse = try await send(makeRequest("v1/challenges", body: Data()))
        guard let challengeData = Data(base64Encoded: challenge.challenge) else { throw ServiceError.unavailable }
        let attestation = try await attest.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: challengeData)))
        let body = try Self.encode(KeyRequest(keyId: keyID, challenge: challenge.challenge, attestation: attestation))
        let _: Empty = try await send(makeRequest("v1/keys", body: body))
        return keyID
    }

    private var keyIDDefaultsKey: String { "AppAttestKeyID \(baseURL.absoluteString)" }

    private func makeRequest(_ path: String, method: String = "POST", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw ServiceError.unavailable }
            return decoded
        case 401 where Self.errorCode(in: data) == "unknown-key":
            throw Failure.unknownKey
        case 401 where Self.errorCode(in: data) == "attestation-required":
            // Only a development server signs without App Attest, which the simulator lacks.
            throw ServiceError.unsupportedDevice
        case 429:
            throw ServiceError.rateLimited
        case 400..<500:
            throw ServiceError.rejected
        default:
            throw ServiceError.unavailable
        }
    }

    private nonisolated static func errorCode(in data: Data) -> String? {
        (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
    }

    /// The pass type of the certificate that made a signature, so a pass never names another.
    nonisolated static func passType(signedBy signature: Data) -> PassType? {
        guard let contentInfo = try? DER.parse(signature).children(), contentInfo.count == 2,
              let signedData = try? contentInfo[1].children().first?.children(),
              let certificates = signedData.first(where: { $0.tag == 0xA0 }),
              let signer = try? certificates.children().first,
              let certificate = try? X509Certificate(der: signer.encoded),
              let passTypeIdentifier = certificate.userID,
              let teamIdentifier = certificate.organizationalUnit else { return nil }
        return PassType(passTypeIdentifier: passTypeIdentifier, teamIdentifier: teamIdentifier)
    }

    private nonisolated static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private enum Failure: Error {
        case unknownKey
    }

    private nonisolated struct SignatureRequest: Encodable {
        var keyId: String?
        var manifestDigest: Data
    }

    private nonisolated struct SignatureResponse: Decodable {
        var signature: Data
    }

    private nonisolated struct ChallengeResponse: Decodable {
        var challenge: String
    }

    private nonisolated struct KeyRequest: Encodable {
        var keyId: String
        var challenge: String
        var attestation: Data
    }

    private nonisolated struct ErrorResponse: Decodable {
        var error: String
    }

    private nonisolated struct Empty: Decodable {}
}

/// App Attest, behind a protocol so tests can stand in for the Secure Enclave.
nonisolated protocol AppAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

nonisolated struct SystemAppAttest: AppAttesting {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}
