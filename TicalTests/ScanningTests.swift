import CoreGraphics
import Foundation
import Testing
@testable import Tical

struct HeuristicTicketParserTests {
    private func line(_ text: String, y: Double, x: Double, h: Double) -> RecognizedLine {
        RecognizedLine(text: text, midY: y, minX: x, height: h)
    }

    private func components(_ date: Date?) -> DateComponents? {
        date.map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0) }
    }

    /// Labels in one column and values in the next, and block, row, and seat stacked above
    /// their values: the layout Vision reports for most ticket apps.
    @Test func readsColumnLayout() {
        let lines = [
            line("My Tickets", y: 0.907, x: 0.047, h: 0.028),
            line("E-TICKET • ADMIT ONE", y: 0.848, x: 0.095, h: 0.016),
            line("The Midnight Owls", y: 0.813, x: 0.098, h: 0.031),
            line("Aurora World Tour 2026", y: 0.785, x: 0.095, h: 0.020),
            line("DATE", y: 0.723, x: 0.095, h: 0.016),
            line("Sat, 17 Oct 2026", y: 0.719, x: 0.309, h: 0.025),
            line("DOORS", y: 0.693, x: 0.091, h: 0.018),
            line("18:30", y: 0.690, x: 0.306, h: 0.020),
            line("SHOW", y: 0.664, x: 0.095, h: 0.016),
            line("20:00", y: 0.662, x: 0.312, h: 0.020),
            line("VENUE", y: 0.633, x: 0.098, h: 0.011),
            line("Uber Arena, Berlin", y: 0.629, x: 0.312, h: 0.017),
            line("BLOCK", y: 0.591, x: 0.098, h: 0.010),
            line("ROW", y: 0.590, x: 0.344, h: 0.012),
            line("SEAT", y: 0.590, x: 0.590, h: 0.012),
            line("C", y: 0.570, x: 0.098, h: 0.020),
            line("12", y: 0.570, x: 0.344, h: 0.020),
            line("7", y: 0.569, x: 0.593, h: 0.019),
            line("Order no. TKT-8842-XK", y: 0.299, x: 0.334, h: 0.013),
            line("Presented by Nightline Concerts", y: 0.274, x: 0.101, h: 0.010),
        ]
        let ticket = HeuristicTicketParser.parse(lines: lines, barcodePayload: "MOWL-2026-1017-C12-07-8842XK")

        #expect(ticket.title.hasPrefix("The Midnight Owls"))
        #expect(ticket.location == "Uber Arena, Berlin")
        #expect(ticket.organizer == "Nightline Concerts")
        #expect(ticket.seatInfo == "Block C · Row 12 · Seat 7")
        #expect(ticket.confirmationCode == "TKT-8842-XK")
        // The show time, not the doors time, starts the event; doors become a note.
        #expect(components(ticket.start) == DateComponents(year: 2026, month: 10, day: 17, hour: 20, minute: 0))
        #expect(!ticket.startTimeIsAssumed)
        #expect(ticket.notes.contains("Doors"))
        #expect(ticket.endIsAssumed)
        #expect(ticket.end == ticket.start?.addingTimeInterval(TicketDefaults.assumedDuration))
    }

    @Test func readsGermanLabels() {
        let lines = [
            line("Philharmonie Berlin", y: 0.90, x: 0.1, h: 0.02),
            line("Beethoven: Neunte Sinfonie", y: 0.84, x: 0.1, h: 0.035),
            line("Samstag, 17. Oktober 2026", y: 0.76, x: 0.1, h: 0.02),
            line("Einlass 18:30 Uhr", y: 0.72, x: 0.1, h: 0.02),
            line("Beginn 20:00 Uhr", y: 0.68, x: 0.1, h: 0.02),
            line("Reihe 5 Platz 12", y: 0.60, x: 0.1, h: 0.02),
            line("Bestellnummer: 123456789", y: 0.30, x: 0.1, h: 0.015),
        ]
        let ticket = HeuristicTicketParser.parse(lines: lines, barcodePayload: "")

        #expect(ticket.title == "Beethoven: Neunte Sinfonie")
        #expect(ticket.location == "Philharmonie Berlin")
        #expect(ticket.seatInfo == "Row 5 · Seat 12")
        #expect(ticket.confirmationCode == "123456789")
        #expect(components(ticket.start) == DateComponents(year: 2026, month: 10, day: 17, hour: 20, minute: 0))
        #expect(ticket.notes.contains("Doors"))
    }

    /// A time on its own gets today's date from the date detector, which must not become the
    /// end of an event on another day.
    @Test func endsTwoHoursAfterAPastStart() {
        let lines = [
            line("Summer Beats", y: 0.80, x: 0.1, h: 0.03),
            line("DATE", y: 0.70, x: 0.1, h: 0.013),
            line("Fri, 7 Aug 2020", y: 0.70, x: 0.3, h: 0.02),
            line("START", y: 0.66, x: 0.1, h: 0.013),
            line("14:00", y: 0.66, x: 0.3, h: 0.016),
        ]
        let ticket = HeuristicTicketParser.parse(lines: lines, barcodePayload: "")
        #expect(components(ticket.start) == DateComponents(year: 2020, month: 8, day: 7, hour: 14, minute: 0))
        #expect(ticket.endIsAssumed)
        #expect(ticket.end == ticket.start?.addingTimeInterval(TicketDefaults.assumedDuration))
    }

    @Test func readsATimeRange() {
        let lines = [
            line("Jazz Night", y: 0.80, x: 0.1, h: 0.03),
            line("Sat, 17 Oct 2026, 19:00 – 22:00", y: 0.70, x: 0.1, h: 0.02),
        ]
        let ticket = HeuristicTicketParser.parse(lines: lines, barcodePayload: "")
        #expect(components(ticket.start) == DateComponents(year: 2026, month: 10, day: 17, hour: 19, minute: 0))
        #expect(components(ticket.end) == DateComponents(year: 2026, month: 10, day: 17, hour: 22, minute: 0))
        #expect(!ticket.endIsAssumed)
    }

    @Test func assumesEveningForDateOnlyTickets() {
        let lines = [
            line("Museum of Modern Art", y: 0.8, x: 0.1, h: 0.04),
            line("Valid on 3 November 2026", y: 0.7, x: 0.1, h: 0.02),
        ]
        let ticket = HeuristicTicketParser.parse(lines: lines, barcodePayload: "")
        let start = components(ticket.start)
        #expect(start?.day == 3)
        #expect(start?.month == 11)
        #expect(start?.hour == TicketDefaults.assumedStartHour)
        #expect(ticket.startTimeIsAssumed)
    }
}

struct ExtractionSummaryTests {
    @Test func namesTheDevice() {
        #expect(ExtractionMethod.model(sawImage: true).summary(on: "iPad").contains("this iPad"))
        #expect(ExtractionMethod.textParser(.deviceNotEligible).summary(on: "iPad").contains("This iPad doesn't support"))
        #expect(!ExtractionMethod.textParser(.modelUnavailable).summary(on: "iPad").contains("iPhone"))
    }
}

struct TextOnCodeTests {
    private let code = CGRect(x: 0.32, y: 0.43, width: 0.36, height: 0.17)

    @Test func dropsTextReadOffTheCode() {
        // What the simulator reads off a QR code's corner: "n An".
        #expect(VisionTicketScanner.isMostlyOnCode(CGRect(x: 0.325, y: 0.44, width: 0.1, height: 0.03), barcode: code))
    }

    @Test func keepsTextNextToTheCode() {
        #expect(!VisionTicketScanner.isMostlyOnCode(CGRect(x: 0.30, y: 0.62, width: 0.40, height: 0.015), barcode: code))
        #expect(!VisionTicketScanner.isMostlyOnCode(CGRect(x: 0.05, y: 0.45, width: 0.30, height: 0.02), barcode: code))
    }
}

struct QRSegmentDecoderTests {
    // Codewords as Vision reports them in `payloadData` for codes Core Image generated.
    @Test func decodesByteMode() {
        let decoded = QRSegmentDecoder.decode(Data(hex: "40c2355540001ff807f109ac3280ec11"), version: 1)
        #expect(decoded == Data(hex: "2355540001ff807f109ac328"))
    }

    @Test func decodesAlphanumericMode() {
        let decoded = QRSegmentDecoder.decode(Data(hex: "20752b460a4f9e96c1077840ec11ec11"), version: 1)
        #expect(decoded.map { String(decoding: $0, as: UTF8.self) } == "TICKET-8842-XK")
    }

    @Test func rejectsKanji() {
        #expect(QRSegmentDecoder.decode(Data(hex: "80"), version: 1) == nil)
    }
}

struct WalletBarcodeTests {
    private func barcode(_ symbology: DetectedBarcode.Symbology, text: String? = nil, bytes: Data? = nil) -> WalletBarcode? {
        WalletBarcode(DetectedBarcode(symbology: symbology, text: text, bytes: bytes, bounds: .zero))
    }

    @Test func keepsASCIIAsLatin1() throws {
        let code = try #require(barcode(.qr, text: "ABC-123"))
        #expect(code.format == .qr)
        #expect(code.encoding == .latin1)
        #expect(code.messageData == Data("ABC-123".utf8))
    }

    @Test func encodesNonASCIIQRTextAsUTF8() throws {
        #expect(try #require(barcode(.qr, text: "Müller")).encoding == .utf8)
    }

    @Test func keepsBinaryAztecBytes() throws {
        let text = String(String.UnicodeScalarView([0x23, 0x00, 0xFF, 0x80].map { Unicode.Scalar($0) }))
        let code = try #require(barcode(.aztec, text: text))
        #expect(code.encoding == .latin1)
        #expect(code.messageData == Data([0x23, 0x00, 0xFF, 0x80]))
    }

    @Test func carriesBinaryQRBytes() throws {
        let code = try #require(barcode(.qr, bytes: Data([0x23, 0x00, 0xFF])))
        #expect(code.encoding == .latin1)
        #expect(code.messageData == Data([0x23, 0x00, 0xFF]))
    }

    @Test func swapsDataMatrixForQR() throws {
        let code = try #require(barcode(.dataMatrix, text: "X1"))
        #expect(code.format == .qr)
        #expect(code.changesSymbology)
    }

    @Test func refusesNonASCIICode128() {
        #expect(barcode(.code128, text: "Ünïcode") == nil)
    }

    @Test func redrawnCodeReadsBack() throws {
        let original = DetectedBarcode(symbology: .qr, text: "MOWL-2026-1017-C12-07-8842XK", bytes: nil, bounds: .zero)
        let code = try #require(WalletBarcode(original))
        #expect(BarcodeRenderer.verify(code, matches: original))
    }
}

struct TimeoutTests {
    @Test func returnsResultBeforeDeadline() async throws {
        let value = try await TicketExtractionService.withTimeout(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func passesErrorsThrough() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await TicketExtractionService.withTimeout(.seconds(5)) { () async throws -> Int in throw Boom() }
        }
    }

    /// A model request can hang and ignore cancellation. The timeout must not wait for it.
    @Test(.timeLimit(.minutes(1))) func givesUpOnOperationsThatIgnoreCancellation() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: TicketExtractionService.TimedOut.self) {
            try await TicketExtractionService.withTimeout(.milliseconds(200)) { () async -> Int in
                // Never resumes, and doesn't observe cancellation.
                await withUnsafeContinuation { (_: UnsafeContinuation<Int, Never>) in }
            }
        }
        #expect(clock.now - start < .seconds(3))
    }
}
