import SwiftUI

struct ReviewView: View {
    @Bindable var model: TicketImportModel
    @State private var showingWallet = false

    var body: some View {
        Form {
            previewSection
            sourceSection
            detailsSection
            scheduleSection
            codeSection
            actionsSection
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingWallet) {
            if let draft = model.draft {
                WalletLimitationView(draft: draft) {
                    model.copyBarcodePayload()
                }
            }
        }
    }

    private var previewSection: some View {
        Section {
            if let screenshot = model.screenshot {
                Image(uiImage: screenshot)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 220)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Ticket screenshot")
            }
            if let barcodeImage = model.barcodeImage {
                Image(uiImage: barcodeImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 160)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .accessibilityLabel(barcodeAccessibilityLabel)
            } else {
                Text("No barcode or QR code was found in this image.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sourceSection: some View {
        Section {
            Text(model.draft?.extractionDetail ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(model.draft?.extractionDetail ?? "Extraction details")
        }
    }

    private var detailsSection: some View {
        Section("Ticket") {
            TextField("Event", text: text(\.title), axis: .vertical)
                .lineLimit(1...3)
            TextField("Location or venue", text: text(\.location), axis: .vertical)
                .lineLimit(1...3)
            TextField("Organizer or name", text: text(\.organizer), axis: .vertical)
                .lineLimit(1...2)
            TextField("Seat, section, or row", text: text(\.seatInfo), axis: .vertical)
                .lineLimit(1...3)
            TextField("Confirmation or order code", text: text(\.confirmationCode))
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            TextField("Notes", text: text(\.notes), axis: .vertical)
                .lineLimit(2...5)
        }
    }

    private var scheduleSection: some View {
        Section("When") {
            if model.draft?.start == nil {
                Button("Add start date and time") {
                    model.draft?.start = Date()
                    model.draft?.startTimeIsAssumed = false
                }
                .accessibilityLabel("Add start date and time")
            } else {
                DatePicker(
                    "Starts",
                    selection: startBinding,
                    displayedComponents: [.date, .hourAndMinute]
                )
                if model.draft?.startTimeIsAssumed == true {
                    Text("No clock time was printed. This is set to 7:00 PM so you can change it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Clear start") {
                    model.draft?.start = nil
                    model.draft?.startTimeIsAssumed = false
                }
                .accessibilityLabel("Clear start date")
            }

            if model.draft?.end == nil {
                Text("If you leave the end empty, Calendar uses a 2 hour duration.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Add end date and time") {
                    let start = model.draft?.start ?? Date()
                    model.draft?.end = start.addingTimeInterval(TicketDefaults.assumedDuration)
                    model.draft?.endIsAssumed = true
                }
                .accessibilityLabel("Add end date and time")
            } else {
                DatePicker(
                    "Ends",
                    selection: endBinding,
                    displayedComponents: [.date, .hourAndMinute]
                )
                if model.draft?.endIsAssumed == true {
                    Text("No end time was found. This is 2 hours after the start. Change it if the ticket says otherwise.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Clear end") {
                    model.draft?.end = nil
                    model.draft?.endIsAssumed = false
                }
                .accessibilityHint("Calendar will use a 2 hour duration when the end is empty.")
            }
        }
    }

    private var codeSection: some View {
        Section("Detected code") {
            if let symbology = model.draft?.barcodeSymbology, !symbology.isEmpty {
                LabeledContent("Symbology", value: symbology)
            }
            TextField("Barcode or QR payload", text: text(\.barcodePayload), axis: .vertical)
                .lineLimit(2...6)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Copy payload") {
                model.copyBarcodePayload()
            }
            .disabled((model.draft?.barcodePayload ?? "").isEmpty)
            .accessibilityLabel("Copy barcode payload")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await model.addToCalendar() }
            } label: {
                if model.isSavingCalendar {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .disabled(model.isSavingCalendar)
            .accessibilityLabel("Add ticket to Calendar")

            Button {
                showingWallet = true
            } label: {
                Label("Add to Wallet", systemImage: "wallet.pass")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .accessibilityLabel("Add to Wallet")
            .accessibilityHint("Explains that Wallet still needs an Apple signing certificate. Does not create a pass.")
        }
    }

    private var barcodeAccessibilityLabel: String {
        let symbology = model.draft?.barcodeSymbology ?? ""
        if symbology.isEmpty { return "No barcode detected" }
        return "Detected \(symbology) code"
    }

    private var startBinding: Binding<Date> {
        Binding {
            model.draft?.start ?? Date()
        } set: { newValue in
            model.draft?.start = newValue
            model.draft?.startTimeIsAssumed = false
        }
    }

    private var endBinding: Binding<Date> {
        Binding {
            model.draft?.end ?? Date()
        } set: { newValue in
            model.draft?.end = newValue
            model.draft?.endIsAssumed = false
        }
    }

    private func text(_ keyPath: WritableKeyPath<TicketDraft, String>) -> Binding<String> {
        Binding {
            model.draft?[keyPath: keyPath] ?? ""
        } set: { newValue in
            model.draft?[keyPath: keyPath] = newValue
        }
    }
}
