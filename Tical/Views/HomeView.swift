import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Bindable var model: AppModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var showingFiles = false
    @State private var showingSettings = false
    @State private var showingWalletSetup = false
    @State private var isDropTargeted = false
    @State private var canPaste = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                HeroTickets()
                    .frame(height: 200)
                    .padding(.top, 8)

                VStack(spacing: 10) {
                    Text("Tickets, sorted.")
                        .font(.largeTitle.weight(.bold))
                    Text("Turn a ticket screenshot or PDF into a calendar event and a Wallet pass. Tical reads it on this iPhone.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                actions
                tips
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 32)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                    .padding(12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: isDropTargeted)
        .navigationTitle("Tical")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photoItem, matching: .images, preferredItemEncoding: .current)
        .fileImporter(isPresented: $showingFiles, allowedContentTypes: [.image, .pdf]) { result in
            if case .success(let url) = result {
                model.open(fileAt: url)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await load(item) }
        }
        .dropDestination(for: TicketFile.self) { files, _ in
            guard let file = files.first else { return false }
            model.open(file.input)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .pasteDestination(for: TicketFile.self) { files in
            if let file = files.first { model.open(file.input) }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(model: model)
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
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { refreshPasteboard() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshPasteboard()
        }
    }

    /// Checks the pasteboard's types without reading it, which doesn't ask for permission.
    private func refreshPasteboard() {
        let pasteboard = UIPasteboard.general
        canPaste = pasteboard.hasImages || pasteboard.contains(pasteboardTypes: [UTType.pdf.identifier])
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                Button {
                    showingPhotos = true
                    TicketExtractionService.prewarm()
                } label: {
                    Label("Choose Screenshot", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .accessibilityHint("Opens your photos to pick a ticket screenshot.")

                HStack(spacing: 12) {
                    Button {
                        showingFiles = true
                        TicketExtractionService.prewarm()
                    } label: {
                        Label("Choose File", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .accessibilityHint("Pick a ticket image or PDF from Files.")

                    if canPaste {
                        // The system paste button reads the pasteboard without a permission prompt.
                        PasteButton(payloadType: TicketFile.self) { files in
                            if let file = files.first { model.open(file.input) }
                        }
                        .buttonBorderShape(.capsule)
                        .labelStyle(.titleAndIcon)
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .controlSize(.large)
                .animation(.smooth, value: canPaste)
            }
            .fontWeight(.semibold)
        }
    }

    private var tips: some View {
        VStack(spacing: 12) {
            TipCard(
                symbol: "square.and.arrow.up",
                tint: .blue,
                title: "Share from any app",
                message: "In Photos, Files, Mail, or Safari, tap Share and choose Tical."
            )
            if model.signing.isReady {
                TipCard(
                    symbol: "wallet.pass.fill",
                    tint: .green,
                    title: "Wallet passes are on",
                    message: "Tical signs passes with your certificate, on this iPhone."
                )
            } else {
                Button {
                    showingWalletSetup = true
                } label: {
                    TipCard(
                        symbol: "wallet.pass.fill",
                        tint: .orange,
                        title: "Add tickets to Wallet",
                        message: "Wallet needs a pass certificate from an Apple Developer account. Set it up once."
                    ) {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the Wallet setup.")
            }
            TipCard(
                symbol: "lock.shield.fill",
                tint: .purple,
                title: "Private by design",
                message: "Tickets are read on this iPhone and never uploaded."
            )
        }
    }

    private func load(_ item: PhotosPickerItem) async {
        do {
            guard let file = try await item.loadTransferable(type: TicketFile.self) else {
                model.show(String(localized: "Couldn't Open Photo"), String(localized: "Tical couldn't read that photo."))
                return
            }
            model.open(file.input)
        } catch {
            model.show(String(localized: "Couldn't Open Photo"), error.localizedDescription)
        }
    }
}

private struct TipCard<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var accessory: Accessory

    init(
        symbol: String,
        tint: Color,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.message = message
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint.gradient, in: .rect(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

/// Three tickets fanned out, the one in front turning into a calendar day.
private struct HeroTickets: View {
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ticket(colors: [Color(red: 1.0, green: 0.62, blue: 0.35), Color(red: 0.96, green: 0.38, blue: 0.36)])
                .rotationEffect(.degrees(appeared ? -16 : -4))
                .offset(x: appeared ? -78 : -20, y: appeared ? 18 : 6)
            ticket(colors: [Color(red: 0.36, green: 0.78, blue: 0.98), Color(red: 0.22, green: 0.52, blue: 0.95)])
                .rotationEffect(.degrees(appeared ? 14 : 4))
                .offset(x: appeared ? 80 : 20, y: appeared ? 12 : 4)
            front
                .rotationEffect(.degrees(-3))
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.9, bounce: 0.35).delay(0.1)) {
                appeared = true
            }
        }
        .accessibilityHidden(true)
    }

    private func ticket(colors: [Color]) -> some View {
        TicketShape(perforated: true)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 170, height: 110)
            .shadow(color: colors.last!.opacity(0.35), radius: 14, y: 8)
    }

    private var front: some View {
        ZStack(alignment: .top) {
            TicketShape()
                .fill(LinearGradient(
                    colors: [Color(red: 0.55, green: 0.42, blue: 1.0), Color(red: 0.33, green: 0.22, blue: 0.86)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
            VStack(spacing: 6) {
                Text(Date.now.formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.85))
                Text(Date.now.formatted(.dateTime.day()))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            .padding(.top, 14)
        }
        .frame(width: 180, height: 130)
        .shadow(color: Color(red: 0.33, green: 0.22, blue: 0.86).opacity(0.45), radius: 20, y: 10)
    }
}
