import PassKit
import SwiftUI

/// One ticket, from the moment it arrives until it's in Calendar or Wallet.
@Observable
final class TicketImport: Identifiable, Hashable {
    enum Phase: Equatable {
        case reading(ReadingStep)
        case ready
        case failed(String)
    }

    enum ReadingStep: Int, CaseIterable, Comparable {
        case opening
        case findingCode
        case readingText
        case understanding

        var title: LocalizedStringKey {
            switch self {
            case .opening: "Opening the ticket"
            case .findingCode: "Finding the code"
            case .readingText: "Reading the text"
            case .understanding: "Understanding the details"
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Whether Wallet will show the same code as the ticket.
    enum CodeStatus: Equatable {
        /// The ticket has no code Tical could read.
        case missing
        /// Tical redrew the code and read back the same content.
        case verified
        /// Wallet can't show this symbology; the pass shows a QR code with the same content.
        case changedSymbology
        /// Tical couldn't confirm that the redrawn code matches.
        case unverified
        /// Wallet can't carry this code.
        case unsupported
    }

    struct PassError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let id = UUID()
    private(set) var phase: Phase = .reading(.opening)
    private(set) var image: UIImage?
    private(set) var pdfPage: TicketPage.PDFPosition?
    var draft = TicketDraft()
    private(set) var barcode: DetectedBarcode?
    private(set) var walletBarcode: WalletBarcode?
    private(set) var codeStatus: CodeStatus = .missing
    private(set) var codeImage: UIImage?
    private(set) var method: ExtractionMethod?
    /// The color Tical picked from the ticket.
    private(set) var sampledColor: RGBColor = .brand
    var passColor: RGBColor = .brand
    var addedToCalendar = false
    var walletPassURL: URL?

    var isReady: Bool { phase == .ready }

    nonisolated static func == (lhs: TicketImport, rhs: TicketImport) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Reading

    func read(_ input: ImportInput) async {
        phase = .reading(.opening)
        guard let page = await Self.load(input) else {
            phase = .failed(String(localized: "Tical couldn't open that file. Try a screenshot, a photo, or a PDF."))
            return
        }
        image = UIImage(cgImage: page.image)
        pdfPage = page.pdfPage
        sampledColor = await Self.passColor(page.image)
        passColor = sampledColor

        phase = .reading(.findingCode)
        let barcode = await Self.detectBarcode(page.image)
        self.barcode = barcode

        phase = .reading(.readingText)
        let lines = await Self.recognizeText(page.image)

        phase = .reading(.understanding)
        let scan = ScanResult(lines: lines, barcode: barcode)
        async let prepared = Self.prepareCode(barcode)
        let result = await TicketExtractionService.extract(from: scan, image: page.image)
        let code = await prepared

        draft = result.draft
        method = result.method
        walletBarcode = code.barcode
        codeStatus = code.status
        codeImage = code.image.map { UIImage(cgImage: $0) }
        withAnimation(.smooth) {
            phase = .ready
        }
    }

    @concurrent
    private nonisolated static func load(_ input: ImportInput) async -> TicketPage? {
        TicketPageLoader.load(input)
    }

    @concurrent
    private nonisolated static func passColor(_ image: CGImage) async -> RGBColor {
        ColorSampler.passColor(from: image)
    }

    @concurrent
    private nonisolated static func detectBarcode(_ image: CGImage) async -> DetectedBarcode? {
        VisionTicketScanner.detectBarcode(in: image)
    }

    @concurrent
    private nonisolated static func recognizeText(_ image: CGImage) async -> [RecognizedLine] {
        VisionTicketScanner.recognizeText(in: image)
    }

    private struct PreparedCode: @unchecked Sendable {
        var barcode: WalletBarcode?
        var status: CodeStatus
        var image: CGImage?
    }

    @concurrent
    private nonisolated static func prepareCode(_ barcode: DetectedBarcode?) async -> PreparedCode {
        guard let barcode else { return PreparedCode(status: .missing) }
        guard let walletBarcode = WalletBarcode(barcode) else { return PreparedCode(status: .unsupported) }
        let image = BarcodeRenderer.image(for: walletBarcode)
        let status: CodeStatus
        if walletBarcode.changesSymbology {
            status = .changedSymbology
        } else if BarcodeRenderer.verify(walletBarcode, matches: barcode) {
            status = .verified
        } else {
            status = .unverified
        }
        return PreparedCode(barcode: walletBarcode, status: status, image: image)
    }

    // MARK: - Wallet

    /// What goes on the pass, as the review screen shows it now.
    var passContent: PassContent {
        PassContent(
            draft: draft,
            barcode: codeStatus == .unsupported ? nil : walletBarcode,
            color: passColor
        )
    }

    /// Builds and signs the pass on this iPhone.
    func makePass(signing: PassSigningStore) async throws -> PKPass {
        let credentials = try signing.credentials()
        let data = try await Self.buildPass(passContent, credentials: credentials)
        do {
            return try PKPass(data: data)
        } catch {
            throw PassError(message: PKPass.explanation(for: error))
        }
    }

    @concurrent
    private nonisolated static func buildPass(_ content: PassContent, credentials: PassCredentials) async throws -> Data {
        try PassBuilder.archive(for: content, credentials: credentials)
    }
}
