import SwiftUI
import UniformTypeIdentifiers

/// Guides you through making a Pass Type ID certificate, so Tical can sign Wallet passes.
struct WalletSetupView: View {
    @Bindable var store: PassSigningStore

    private enum ImportKind {
        case certificate
        case pkcs12
    }

    @State private var importKind: ImportKind = .certificate
    @State private var showingImporter = false
    @State private var pkcs12Data: Data?
    @State private var password = ""
    @State private var askingPassword = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmingRemoval = false
    @State private var requestFile: URL?

    var body: some View {
        Form {
            if let certificate = store.certificate {
                readyContent(certificate)
            } else {
                introSection
                stepsSection
                pkcs12Section
            }
        }
        .navigationTitle("Wallet Passes")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView()
                    .controlSize(.large)
                    .padding(24)
                    .glassEffect(in: .rect(cornerRadius: 20))
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: importKind == .pkcs12 ? [.pkcs12] : [.x509Certificate, .data]
        ) { result in
            handleImport(result)
        }
        .alert("Password for the .p12 File", isPresented: $askingPassword) {
            SecureField("Password", text: $password)
            Button("Import") { importPKCS12() }
            Button("Cancel", role: .cancel) { pkcs12Data = nil }
        } message: {
            Text("Enter the password you chose when you exported the file.")
        }
        .alert(
            "Couldn't Set Up Wallet",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Remove the certificate?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Certificate", role: .destructive) { store.removeCertificate() }
        } message: {
            Text("Tical deletes the certificate and its private key from this iPhone. Passes already in Wallet stay there.")
        }
        .onChange(of: store.pendingRequest, initial: true) { _, request in
            requestFile = request?.writeFile()
        }
        .sensoryFeedback(.success, trigger: store.isReady) { _, ready in ready }
        .animation(.smooth, value: store.certificate)
        .animation(.smooth, value: store.pendingRequest)
    }

    // MARK: - Setup

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "wallet.pass.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Wallet only accepts passes signed with a Pass Type ID certificate from Apple.")
                    .font(.headline)
                Text("If you're in the Apple Developer Program, you can make one in a few minutes. Tical then makes and signs passes on this iPhone, and the signing key never leaves its keychain.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private var stepsSection: some View {
        Section {
            StepRow(number: 1, title: "Create a signing request", isDone: store.pendingRequest != nil) {
                if let request = store.pendingRequest {
                    Text("Created \(request.createdAt.formatted(.relative(presentation: .named))). Upload it in step 2.")
                    ShareLink(item: requestFile ?? request.writeFile()) {
                        Label("Share or Save Request", systemImage: "square.and.arrow.up")
                    }
                    Button("Start Over", role: .destructive) { store.discardRequest() }
                        .font(.footnote)
                } else {
                    Text("Tical makes a private key on this iPhone and a request that Apple turns into a certificate.")
                    Button("Create Request", systemImage: "key.fill") { createRequest() }
                }
            }

            StepRow(number: 2, title: "Make the certificate", isDone: false) {
                Text("In your Apple Developer account, register a Pass Type ID. Then create a Pass Type ID certificate for it and upload the request.")
                Link(destination: URL(string: "https://developer.apple.com/account/resources/identifiers/list/passTypeId")!) {
                    Label("Pass Type IDs", systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://developer.apple.com/account/resources/certificates/add")!) {
                    Label("New Certificate", systemImage: "arrow.up.right.square")
                }
            }

            StepRow(number: 3, title: "Import the certificate", isDone: false) {
                Text("Download the certificate Apple makes, usually pass.cer, and import it here.")
                Button("Import Certificate", systemImage: "square.and.arrow.down") {
                    importKind = .certificate
                    showingImporter = true
                }
                .disabled(store.pendingRequest == nil)
            }
        } header: {
            Text("Set Up")
        } footer: {
            Text("If the certificate file doesn't include Apple's intermediate certificate, iOS downloads that public certificate once.")
        }
    }

    private var pkcs12Section: some View {
        Section {
            Button("Import .p12 File", systemImage: "doc.badge.plus") {
                importKind = .pkcs12
                showingImporter = true
            }
        } header: {
            Text("Already Have a Certificate?")
        } footer: {
            Text("On a Mac, export the Pass Type ID certificate and its private key from Keychain Access as a .p12 file.")
        }
    }

    // MARK: - Ready

    @ViewBuilder
    private func readyContent(_ certificate: SigningCertificate) -> some View {
        Section {
            Label {
                Text(certificate.isExpired ? "The certificate has expired" : "Wallet passes are on")
                    .font(.headline)
            } icon: {
                Image(systemName: certificate.isExpired ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(certificate.isExpired ? .orange : .green)
            }
            LabeledContent("Pass Type ID", value: certificate.passTypeIdentifier)
            LabeledContent("Team", value: certificate.teamIdentifier)
            if !certificate.ownerName.isEmpty {
                LabeledContent("Owner", value: certificate.ownerName)
            }
            if let expires = certificate.expires {
                LabeledContent("Expires") {
                    Text(expires.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(expiresSoon(expires) ? .orange : .secondary)
                }
            }
        } footer: {
            Text("Tical signs each pass on this iPhone with this certificate.")
        }

        if certificate.isExpired || certificate.expires.map(expiresSoon) == true || store.pendingRequest != nil {
            Section {
                if let request = store.pendingRequest {
                    ShareLink(item: requestFile ?? request.writeFile()) {
                        Label("Share or Save Request", systemImage: "square.and.arrow.up")
                    }
                    Button("Import New Certificate", systemImage: "square.and.arrow.down") {
                        importKind = .certificate
                        showingImporter = true
                    }
                } else {
                    Button("Create New Request", systemImage: "key.fill") { createRequest() }
                }
            } header: {
                Text("Renew")
            } footer: {
                Text("Upload the new request for the same Pass Type ID, then import the certificate Apple makes.")
            }
        }

        Section {
            Button("Remove Certificate", role: .destructive) { confirmingRemoval = true }
        }
    }

    // MARK: - Actions

    private func expiresSoon(_ date: Date) -> Bool {
        date.timeIntervalSinceNow < 30 * 86_400
    }

    private func createRequest() {
        run { _ = try await store.createRequest() }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = String(localized: "Tical couldn't read that file.")
            return
        }
        switch importKind {
        case .certificate:
            run { try await store.importCertificate(data) }
        case .pkcs12:
            pkcs12Data = data
            password = ""
            askingPassword = true
        }
    }

    private func importPKCS12() {
        guard let data = pkcs12Data else { return }
        let password = password
        pkcs12Data = nil
        self.password = ""
        run { try await store.importPKCS12(data, password: password) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct StepRow<Content: View>: View {
    let number: Int
    let title: LocalizedStringKey
    let isDone: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(isDone ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                } else {
                    Text(number, format: .number)
                        .font(.subheadline.weight(.bold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                content
                    .font(.subheadline)
                    // Several buttons share this row; each should only react to its own taps.
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Step \(number)"))
    }
}
