import SwiftUI

struct WalletLimitationView: View {
    let draft: TicketDraft
    var copyPayload: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(deviceSentence)
                    Text("Tical can read the code in the screenshot. It cannot put that code into Wallet.")
                }

                Section("Why") {
                    Text("Wallet only accepts a signed pass file, a .pkpass. The signature uses an Apple-issued Pass Type ID certificate and Apple's WWDR intermediate certificate.")
                    Text("PassKit on the iPhone can show a pass that is already signed. It cannot create the signature. Apple's Pass Builder tools sign passes on a Mac or a server, and they still ask for those certificates.")
                    Text("Tical does not build an unsigned pass, and it does not send the screenshot anywhere to be signed.")
                }

                Section("Detected code") {
                    if draft.barcodeSymbology.isEmpty && draft.barcodePayload.isEmpty {
                        Text("No barcode payload was found in this image.")
                            .foregroundStyle(.secondary)
                    } else {
                        if !draft.barcodeSymbology.isEmpty {
                            LabeledContent("Symbology", value: draft.barcodeSymbology)
                        }
                        if !draft.barcodePayload.isEmpty {
                            Text(draft.barcodePayload)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityLabel("Barcode payload")
                            Button("Copy payload", action: copyPayload)
                                .accessibilityLabel("Copy barcode payload")
                        }
                    }
                }

                Section("What still works") {
                    Text("Add to Calendar saves this event on the iPhone. A real Wallet pass would have to be signed outside Tical, with a Pass Type ID you create in the Apple Developer account. Tical will not ask you to paste that private key into the app.")
                }
            }
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityLabel("Done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var deviceSentence: String {
        if WalletCapability.deviceCanAddPasses {
            return "This device can add Wallet passes."
        }
        return "This device can't add Wallet passes."
    }
}
