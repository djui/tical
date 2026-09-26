import CryptoKit
import Foundation
import Testing
@testable import Tical

struct PassSigningServiceTests {
    private let manifest = Data(#"{"pass.json":"0123456789abcdef"}"#.utf8)
    private let passType = PassType(passTypeIdentifier: "pass.test.tical", teamIdentifier: "TESTTEAM01")

    /// A server for one test, on its own made-up host, with a fresh place to keep the key ID.
    private func makeService(attest: FakeAttest, handler: @escaping StubProtocol.Handler) -> (PassSigningService, UserDefaults) {
        let host = "signing-\(UUID().uuidString.lowercased()).test"
        let service = PassSigningService(
            baseURL: URL(string: "https://\(host)")!,
            session: StubProtocol.session(host: host, handler: handler),
            attest: attest,
            defaults: UserDefaults(suiteName: host)!
        )
        // A second handle on the same suite, since the service owns the first.
        return (service, UserDefaults(suiteName: host)!)
    }

    /// A signature file like the server's, from a certificate for the given pass type.
    private func signatureFile(passTypeIdentifier: String = "pass.test.tical") throws -> Data {
        let identity = try TestIdentity.passType(passTypeIdentifier, team: "TESTTEAM01")
        return try CMSSignature.detached(content: manifest, signer: identity.certificate, intermediates: []) {
            try Keychain.sign($0, with: identity.key)
        }
    }

    @Test func signsTheManifestDigestWithoutAppAttestInTheSimulator() async throws {
        let signature = try signatureFile()
        let recorder = Recorder()
        let (service, _) = makeService(attest: FakeAttest(isSupported: false)) { request, body in
            recorder.record(request, body)
            switch request.url?.path {
            case "/v1/pass-type": return (200, jsonData(["passTypeIdentifier": "pass.test.tical", "teamIdentifier": "TESTTEAM01"]))
            case "/v1/signatures": return (200, jsonData(["signature": signature.base64EncodedString()]))
            default: return (404, Data())
            }
        }

        let signer = try await PassSigner.service(service)
        #expect(signer.passType == passType)
        #expect(try await signer.sign(manifest) == signature)

        let request = try #require(recorder.requests.last)
        #expect(request.path == "/v1/signatures")
        #expect(request.assertion == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: String])
        // Only the digest of the manifest leaves the device.
        #expect(body == ["manifestDigest": Data(SHA256.hash(data: manifest)).base64EncodedString()])
    }

    @Test func registersOneKeyAndAssertsEachRequest() async throws {
        let signature = try signatureFile()
        let challenge = Data((0..<32).map { UInt8($0) })
        let recorder = Recorder()
        let attest = FakeAttest(isSupported: true)
        let (service, defaults) = makeService(attest: attest) { request, body in
            recorder.record(request, body)
            switch request.url?.path {
            case "/v1/challenges": return (200, jsonData(["challenge": challenge.base64EncodedString()]))
            case "/v1/keys": return (201, jsonData([:]))
            case "/v1/signatures": return (200, jsonData(["signature": signature.base64EncodedString()]))
            default: return (404, Data())
            }
        }

        _ = try await service.signature(for: manifest, passType: passType)
        _ = try await service.signature(for: manifest, passType: passType)

        #expect(recorder.requests.map(\.path) == ["/v1/challenges", "/v1/keys", "/v1/signatures", "/v1/signatures"])
        let registration = try #require(try JSONSerialization.jsonObject(with: recorder.requests[1].body) as? [String: String])
        #expect(registration["keyId"] == "key-1")
        #expect(registration["challenge"] == challenge.base64EncodedString())
        // The attestation covers the hash of the server's challenge.
        let attestation = Data("attestation of key-1".utf8) + Data(SHA256.hash(data: challenge))
        #expect(registration["attestation"] == attestation.base64EncodedString())

        let signing = recorder.requests[3]
        #expect(signing.assertion == Data("assertion by key-1".utf8).base64EncodedString())
        // Each assertion covers the exact body that was sent.
        #expect(attest.assertedHashes.last == Data(SHA256.hash(data: signing.body)))
        #expect(defaults.string(forKey: "AppAttestKeyID \(service.baseURL.absoluteString)") == "key-1")
    }

    @Test func registersANewKeyWhenTheServerForgotTheOldOne() async throws {
        let signature = try signatureFile()
        let recorder = Recorder()
        let (service, defaults) = makeService(attest: FakeAttest(isSupported: true)) { request, body in
            recorder.record(request, body)
            switch request.url?.path {
            case "/v1/challenges": return (200, jsonData(["challenge": Data(count: 32).base64EncodedString()]))
            case "/v1/keys": return (201, jsonData([:]))
            case "/v1/signatures" where String(decoding: body, as: UTF8.self).contains("old-key"):
                return (401, jsonData(["error": "unknown-key", "message": "This key isn't registered."]))
            case "/v1/signatures": return (200, jsonData(["signature": signature.base64EncodedString()]))
            default: return (404, Data())
            }
        }
        defaults.set("old-key", forKey: "AppAttestKeyID \(service.baseURL.absoluteString)")

        #expect(try await service.signature(for: manifest, passType: passType) == signature)
        #expect(recorder.requests.map(\.path) == ["/v1/signatures", "/v1/challenges", "/v1/keys", "/v1/signatures"])
    }

    @Test func refusesASignatureFromAnotherPassType() async throws {
        let signature = try signatureFile(passTypeIdentifier: "pass.other.tickets")
        let (service, _) = makeService(attest: FakeAttest(isSupported: false)) { _, _ in
            (200, jsonData(["signature": signature.base64EncodedString()]))
        }
        await #expect(throws: PassSigningService.ServiceError.passTypeChanged) {
            try await service.signature(for: manifest, passType: passType)
        }
    }

    @Test(arguments: [
        (0, PassSigningService.ServiceError.offline),
        (429, .rateLimited),
        (403, .rejected),
        (503, .unavailable),
    ])
    func explainsFailures(status: Int, error: PassSigningService.ServiceError) async throws {
        let (service, _) = makeService(attest: FakeAttest(isSupported: false)) { _, _ in
            (status, jsonData(["error": "whatever"]))
        }
        await #expect(throws: error) {
            try await service.signature(for: manifest, passType: passType)
        }
    }
}

private func jsonData(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

/// App Attest without a Secure Enclave: predictable keys, attestations, and assertions.
nonisolated final class FakeAttest: AppAttesting, @unchecked Sendable {
    let isSupported: Bool
    private let lock = NSLock()
    private var keys = 0
    private var hashes: [Data] = []

    init(isSupported: Bool) {
        self.isSupported = isSupported
    }

    var assertedHashes: [Data] { lock.withLock { hashes } }

    func generateKey() async throws -> String {
        lock.withLock {
            keys += 1
            return "key-\(keys)"
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        Data("attestation of \(keyID)".utf8) + clientDataHash
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { hashes.append(clientDataHash) }
        return Data("assertion by \(keyID)".utf8)
    }
}

/// Keeps what a stub server received.
nonisolated final class Recorder: @unchecked Sendable {
    struct Request {
        var path: String
        var assertion: String?
        var body: Data
    }

    private let lock = NSLock()
    private var received: [Request] = []

    var requests: [Request] { lock.withLock { received } }

    func record(_ request: URLRequest, _ body: Data) {
        let entry = Request(
            path: request.url?.path ?? "",
            assertion: request.value(forHTTPHeaderField: "X-Tical-Assertion"),
            body: body
        )
        lock.withLock { received.append(entry) }
    }
}

/// Answers requests for one made-up host per test, so tests can run side by side.
/// A status of 0 fails the request as if there were no connection.
nonisolated final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (_ request: URLRequest, _ body: Data) -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func session(host: String, handler: @escaping Handler) -> URLSession {
        lock.withLock { handlers[host] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handlers[request.url?.host ?? ""] }
        let (status, body) = handler?(request, Self.body(of: request)) ?? (404, Data())
        guard status != 0, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
