import CryptoKit
import Foundation
import Testing
@testable import Tical

/// Makes a pass with a running signing server, such as `npm run dev` in server/. Skipped
/// unless you point it at one:
///
///     TEST_RUNNER_TICAL_SIGNING_SERVICE_URL=http://127.0.0.1:8787 xcodebuild test …
///
/// The simulator can't use App Attest, so the server must allow unattested requests, as
/// `npm run dev-vars` sets up.
struct SigningServerIntegrationTests {
    static let serverURL = ProcessInfo.processInfo.environment["TICAL_SIGNING_SERVICE_URL"].flatMap(URL.init(string:))

    @Test(.enabled(if: serverURL != nil, "Set TICAL_SIGNING_SERVICE_URL to a running signing server."))
    func signsAPassOnTheServer() async throws {
        let service = PassSigningService(baseURL: try #require(Self.serverURL), attest: FakeAttest(isSupported: false))
        let signer = try await PassSigner.service(service)
        var draft = TicketDraft()
        draft.title = "Integration Test"
        draft.start = Date()
        let archive = try await PassBuilder.archive(for: PassContent(draft: draft, barcode: nil, color: .brand), signer: signer)

        let files = StoredZip.entries(of: archive)
        let manifest = try #require(files["manifest.json"])
        let signature = try #require(files["signature"])
        let passJSON = try #require(files["pass.json"])
        let pass = try #require(try JSONSerialization.jsonObject(with: passJSON) as? [String: Any])

        let signedData = try DER.parse(signature).children()[1].children()[0].children()
        let certificates = try #require(signedData.first { $0.tag == 0xA0 }).children()
        let signerCertificate = try #require(certificates.first)
        let certificate = try X509Certificate(der: signerCertificate.encoded)
        let signerInfo = try signedData[4].children()[0].children()
        let attributes = try DER.parseAll(signerInfo[3].content).map { try $0.children() }
        let messageDigest = try #require(attributes.first { DER.objectIdentifierString($0[0].content) == OID.messageDigest })

        // The pass names the certificate that signed it, and the signature covers this manifest.
        #expect(pass["passTypeIdentifier"] as? String == certificate.userID)
        #expect(pass["teamIdentifier"] as? String == certificate.organizationalUnit)
        #expect(try messageDigest[1].children()[0].content == Data(SHA256.hash(data: manifest)))
        #expect(TestIdentity.verify(signerInfo[5].content, of: DER.tlv(DER.Tag.set, signerInfo[3].content), with: certificate))
        #expect(certificates.count >= 2, "Wallet needs the intermediate certificate too")
    }
}
