import EventKit
import PassKit
import SwiftUI

struct ReviewView: View {
    @Bindable var ticket: TicketImport
    let model: AppModel

    @State private var editorEvent: EditorEvent?
    @State private var passToAdd: PassPresentation?
    @State private var isBuildingPass = false
    @State private var showingWalletSetup = false
    @State private var showingOriginal = false
    @State private var copiedCode = false
    @State private var formWidth: CGFloat = 0
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .navigationTitle(ticket.isReady ? "Review" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(item: $editorEvent) { item in
                EventEditorSheet(event: item.event, store: item.store) { action in
                    editorEvent = nil
                    if action == .saved {
                        ticket.addedToCalendar = true
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(item: $passToAdd) { item in
                AddPassSheet(pass: item.pass) {
                    passToAdd = nil
                    if PKPassLibrary().containsPass(item.pass) {
                        ticket.walletPassURL = item.pass.passURL ?? URL(string: "shoebox://")
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showingWalletSetup) {
                NavigationStack {
                    WalletSetupView(store: model.signing)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(role: .close) { showingWalletSetup = false }
                            }
                        }
                }
            }
            .fullScreenCover(isPresented: $showingOriginal) {
                OriginalImageView(image: ticket.image, highlight: ticket.barcode?.bounds)
            }
            .sensoryFeedback(.success, trigger: ticket.addedToCalendar) { _, added in added }
            .sensoryFeedback(.success, trigger: ticket.walletPassURL) { _, url in url != nil }
    }

    @ViewBuilder
    private var content: some View {
        switch ticket.phase {
        case .reading(let step):
            ReadingView(image: ticket.image, step: step)
                .transition(.opacity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Read Ticket", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .ready:
            form
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        }
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section {
                TicketCardView(
                    draft: ticket.draft,
                    color: ticket.passColor,
                    codeImage: ticket.codeImage,
                    codeCaption: codeCaption
                )
                .onTapGesture { showingOriginal = true }
                .accessibilityAction(named: "Show Original") { showingOriginal = true }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            } footer: {
                if let page = ticket.pdfPage, page.count > 1 {
                    Text("From page \(page.number) of \(page.count) of the PDF.")
                }
            }

            Section("Event") {
                TextField("Event name", text: $ticket.draft.title, axis: .vertical)
                    .font(.headline)
                    .lineLimit(1...3)
                TextField("Venue", text: $ticket.draft.location, axis: .vertical)
                    .lineLimit(1...3)
                    .textContentType(.fullStreetAddress)
            }

            scheduleSection

            Section("Ticket") {
                LabeledField("Seat", text: $ticket.draft.seatInfo, prompt: "Section, row, seat")
                LabeledField("Booking", text: $ticket.draft.confirmationCode, prompt: "Order or booking code", monospaced: true)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                LabeledField("Organizer", text: $ticket.draft.organizer, prompt: "Promoter or presenter")
            }

            Section("Notes") {
                TextField("Anything else to remember", text: $ticket.draft.notes, axis: .vertical)
                    .lineLimit(2...6)
            }

            codeSection
            colorSection

            if let method = ticket.method {
                Section {
                } footer: {
                    Label(method.summary(on: Device.name), systemImage: Device.symbol)
                        .font(.footnote)
                }
            }
        }
        .contentMargins(.bottom, 12, for: .scrollContent)
        // Keep a readable width on iPad; nil keeps the system margins everywhere else.
        .contentMargins(.horizontal, formWidth > 800 ? (formWidth - 720) / 2 : nil, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { formWidth = $0 }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaBar(edge: .bottom) {
            actionBar
        }
        // Wallet's badge isn't glass, which otherwise makes the system draw a hard edge.
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    private var scheduleSection: some View {
        Section {
            if ticket.draft.start == nil {
                Button("Add Date and Time", systemImage: "calendar.badge.plus") {
                    ticket.draft.start = defaultStart
                    ticket.draft.startTimeIsAssumed = false
                    ticket.draft.end = defaultStart.addingTimeInterval(TicketDefaults.assumedDuration)
                    ticket.draft.endIsAssumed = true
                }
            } else {
                DatePicker("Starts", selection: startBinding)
                DatePicker("Ends", selection: endBinding, in: (ticket.draft.start ?? .distantPast)...)
            }
        } header: {
            Text("When")
        } footer: {
            if let hint = scheduleHint {
                Text(hint)
            }
        }
    }

    private var codeSection: some View {
        Section {
            if let barcode = ticket.barcode {
                LabeledContent("Type", value: barcode.symbology.displayName)
                HStack(alignment: .firstTextBaseline) {
                    Text(barcode.displayPayload)
                        .font(.callout.monospaced())
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(copiedCode ? "Copied" : "Copy", systemImage: copiedCode ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = barcode.displayPayload
                        copiedCode = true
                    }
                    .labelStyle(.iconOnly)
                    .contentTransition(.symbolEffect(.replace))
                    .sensoryFeedback(.success, trigger: copiedCode) { _, copied in copied }
                    .task(id: copiedCode) {
                        guard copiedCode else { return }
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedCode = false
                    }
                }
            } else {
                Label("No code found in this image.", systemImage: "qrcode")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Code")
        } footer: {
            codeFooter
        }
    }

    @ViewBuilder
    private var codeFooter: some View {
        switch ticket.codeStatus {
        case .verified:
            Label("Checked: the Wallet pass shows a code with the same content.", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .changedSymbology:
            Label("Wallet can't show Data Matrix codes, so the pass uses a QR code with the same content. Some scanners may not accept it.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unverified:
            Label("Tical couldn't confirm that the redrawn code matches. Keep the original ticket at hand.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unsupported:
            Label("Wallet can't show this code. The pass will have the details but no code.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .missing:
            Text("A pass without a code still keeps the details together in Wallet.")
        }
    }

    private var colorSection: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(colorChoices, id: \.self) { choice in
                        Button {
                            ticket.passColor = choice
                        } label: {
                            Circle()
                                .fill(Color(choice).gradient)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if choice == ticket.passColor {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Color(choice.foreground))
                                    }
                                }
                                .padding(3)
                                .overlay {
                                    Circle().strokeBorder(choice == ticket.passColor ? Color(choice) : .clear, lineWidth: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice == ticket.sampledColor ? "Color from the ticket" : "Pass color")
                        .accessibilityAddTraits(choice == ticket.passColor ? .isSelected : [])
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
        } header: {
            Text("Pass Color")
        } footer: {
            Text("The first color comes from the ticket.")
        }
    }

    // MARK: - Actions

    private var actionBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    addToCalendar()
                } label: {
                    Label(
                        ticket.addedToCalendar ? "Added" : "Calendar",
                        systemImage: ticket.addedToCalendar ? "checkmark.circle.fill" : "calendar.badge.plus"
                    )
                    .contentTransition(.symbolEffect(.replace))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(ticket.addedToCalendar ? "Added to Calendar. Add again" : "Add to Calendar")

                Group {
                    if let url = ticket.walletPassURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label("View in Wallet", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.black)
                    } else if !Self.canAddPasses {
                        // No Wallet here, as on iPad: send the pass to an iPhone instead.
                        if model.signing.isReady {
                            ShareLink(
                                item: PassFile(content: ticket.passContent, signing: model.signing),
                                preview: SharePreview(ticket.draft.displayTitle)
                            ) {
                                Label("Send Pass", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glassProminent)
                            .tint(.black)
                        }
                    } else {
                        // Apple's own badge: its guidelines don't allow a custom one.
                        AddPassToWalletButton {
                            addToWallet()
                        }
                        .addPassToWalletButtonStyle(colorScheme == .dark ? .blackOutline : .black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .disabled(isBuildingPass)
                    }
                }
            }
            .controlSize(.large)
            .fontWeight(.semibold)
            // Match the corners of Wallet's badge, which can't be changed.
            .buttonBorderShape(.roundedRectangle(radius: 4))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: 600)
    }

    private static let canAddPasses = PKAddPassesViewController.canAddPasses()

    private func addToCalendar() {
        let store = EKEventStore()
        let event = CalendarEvent.make(from: ticket.draft, barcode: ticket.barcode, in: store)
        editorEvent = EditorEvent(event: event, store: store)
    }

    private func addToWallet() {
        guard model.signing.isReady else {
            showingWalletSetup = true
            return
        }
        isBuildingPass = true
        Task {
            defer { isBuildingPass = false }
            do {
                let pass = try await ticket.makePass(signing: model.signing)
                passToAdd = PassPresentation(pass: pass)
            } catch {
                model.show(String(localized: "Couldn't Make the Pass"), error.localizedDescription)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if ticket.isReady {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Button("Show Original", systemImage: "photo") { showingOriginal = true }
                    if let payload = ticket.barcode?.displayPayload {
                        Button("Copy Code Content", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = payload
                        }
                    }
                    if !ticket.draft.confirmationCode.isEmpty {
                        Button("Copy Booking Code", systemImage: "number") {
                            UIPasteboard.general.string = ticket.draft.confirmationCode
                        }
                    }
                    if model.signing.isReady {
                        Divider()
                        ShareLink(
                            item: PassFile(content: ticket.passContent, signing: model.signing),
                            preview: SharePreview(
                                ticket.draft.displayTitle,
                                image: Image(uiImage: ticket.codeImage ?? ticket.image ?? UIImage())
                            )
                        ) {
                            Label("Share Pass File", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var codeCaption: String? {
        let booking = ticket.draft.confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !booking.isEmpty { return booking }
        guard let text = ticket.barcode?.text, text.count <= 32,
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) else { return nil }
        return text
    }

    private var colorChoices: [RGBColor] {
        var choices = [ticket.sampledColor]
        for preset in RGBColor.presets where !choices.contains(preset) {
            choices.append(preset)
        }
        if !choices.contains(ticket.passColor) {
            choices.insert(ticket.passColor, at: 0)
        }
        return choices
    }

    private var defaultStart: Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(
            bySettingHour: TicketDefaults.assumedStartHour,
            minute: TicketDefaults.assumedStartMinute,
            second: 0,
            of: today
        ) ?? Date()
    }

    private var scheduleHint: String? {
        var hints: [String] = []
        if ticket.draft.startTimeIsAssumed, let start = ticket.draft.start {
            hints.append(String(localized: "The ticket shows no time, so the start is set to \(start.formatted(date: .omitted, time: .shortened))."))
        }
        if ticket.draft.endIsAssumed {
            let minutes = Int(TicketDefaults.assumedDuration / 60)
            let length = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
            hints.append(String(localized: "No end time is printed, so the event lasts \(length)."))
        }
        return hints.isEmpty ? nil : hints.joined(separator: " ")
    }

    private var startBinding: Binding<Date> {
        Binding {
            ticket.draft.start ?? defaultStart
        } set: { newValue in
            let oldStart = ticket.draft.start
            ticket.draft.start = newValue
            ticket.draft.startTimeIsAssumed = false
            // Moving the start moves the end with it, like Calendar does.
            if let oldStart, let end = ticket.draft.end {
                ticket.draft.end = end.addingTimeInterval(newValue.timeIntervalSince(oldStart))
            } else {
                ticket.draft.end = newValue.addingTimeInterval(TicketDefaults.assumedDuration)
            }
        }
    }

    private var endBinding: Binding<Date> {
        Binding {
            ticket.draft.effectiveEnd ?? defaultStart
        } set: { newValue in
            ticket.draft.end = newValue
            ticket.draft.endIsAssumed = false
        }
    }
}

private struct EditorEvent: Identifiable {
    let id = UUID()
    let event: EKEvent
    let store: EKEventStore
}

private struct PassPresentation: Identifiable {
    let id = UUID()
    let pass: PKPass
}

/// A text field with its label on the leading side, like Contacts.
private struct LabeledField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    let prompt: LocalizedStringKey
    var monospaced = false

    init(_ label: LocalizedStringKey, text: Binding<String>, prompt: LocalizedStringKey, monospaced: Bool = false) {
        self.label = label
        _text = text
        self.prompt = prompt
        self.monospaced = monospaced
    }

    var body: some View {
        LabeledContent {
            TextField(label, text: $text, prompt: Text(prompt), axis: .vertical)
                .lineLimit(1...3)
                .multilineTextAlignment(.trailing)
                .monospaced(monospaced)
        } label: {
            Text(label)
        }
    }
}
