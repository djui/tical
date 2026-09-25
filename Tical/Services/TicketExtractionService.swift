import Foundation
import FoundationModels

@Generable
struct GeneratedTicket {
    @Guide(description: "Event or show title printed on the ticket. Empty string if it is not printed.")
    var title: String

    @Guide(description: "Venue, hall, or address printed on the ticket. Empty string if it is not printed.")
    var location: String

    @Guide(description: "Start in local time as yyyy-MM-dd'T'HH:mm. If only a calendar day is printed, return yyyy-MM-dd. Empty string if no date is printed.")
    var startISO: String

    @Guide(description: "End in local time as yyyy-MM-dd'T'HH:mm, or empty if the ticket does not print an end.")
    var endISO: String

    @Guide(description: "Organizer, promoter, or presenter printed on the ticket. Empty string if it is not printed.")
    var organizer: String

    @Guide(description: "Seat, row, section, block, or gate as a short phrase. Empty string if it is not printed.")
    var seatInfo: String

    @Guide(description: "Short confirmation, order, or booking code. Empty string if it is not printed. Do not copy a long barcode payload or a URL.")
    var confirmationCode: String

    @Guide(description: "One short factual note that is printed and does not fit the other fields. Empty string if there is nothing else.")
    var notes: String
}

@MainActor
enum TicketExtractionService {
    static func makeDraft(from scan: ScanResult) async -> TicketDraft {
        let heuristic = HeuristicTicketParser.parse(
            lines: scan.lines,
            barcodePayload: scan.barcodePayload
        )
        let availabilityNote = modelUnavailableNote()
        if let availabilityNote {
            return draft(
                from: heuristic,
                scan: scan,
                source: .heuristic,
                detail: availabilityNote
            )
        }

        do {
            let generated = try await generate(from: scan)
            let merged = merge(generated: generated, heuristic: heuristic)
            return draft(
                from: merged,
                scan: scan,
                source: .onDeviceModel,
                detail: "Read with the on-device model. Change anything that looks wrong."
            )
        } catch {
            return draft(
                from: heuristic,
                scan: scan,
                source: .heuristic,
                detail: "The on-device model couldn't structure this ticket, so Tical used the text parser."
            )
        }
    }

    private static func modelUnavailableNote() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This device can't run the on-device model, so Tical used the text parser."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off, so Tical used the text parser."
            case .modelNotReady:
                return "The on-device model isn't ready yet, so Tical used the text parser."
            default:
                return "The on-device model isn't available, so Tical used the text parser."
            }
        }
    }

    private static func generate(from scan: ScanResult) async throws -> GeneratedTicket {
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                instructions: """
                You extract fields from a ticket screenshot that was already OCR'd on this device. \
                Use only the text you are given. Do not invent a venue, time, seat, or code. \
                If a field is missing, return an empty string. Do not browse and do not call a service.
                """
            )
        let response = try await session.respond(to: prompt(for: scan), generating: GeneratedTicket.self)
        return response.content
    }

    private static func prompt(for scan: ScanResult) -> String {
        let ordered = scan.lines.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > 0.015 { return lhs.midY > rhs.midY }
            return lhs.minX < rhs.minX
        }
        var body = ordered.prefix(80).enumerated().map { index, line in
            "\(index + 1). \(line.text)"
        }.joined(separator: "\n")
        if body.count > 4000 {
            body = String(body.prefix(4000))
        }
        let code = scan.barcodePayload.isEmpty ? "None" : scan.barcodePayload
        let kind = scan.barcodeSymbology.isEmpty ? "None" : scan.barcodeSymbology
        return """
        Barcode symbology: \(kind)
        Barcode payload, already captured separately: \(code)

        OCR lines from top to bottom:
        \(body.isEmpty ? "(no text recognized)" : body)
        """
    }

    private static func merge(generated: GeneratedTicket, heuristic: ParsedTicket) -> ParsedTicket {
        var merged = heuristic
        merged.title = prefer(generated.title, fallback: heuristic.title, limit: 140)
        merged.location = prefer(generated.location, fallback: heuristic.location, limit: 120)
        merged.organizer = prefer(generated.organizer, fallback: heuristic.organizer, limit: 80)
        merged.seatInfo = prefer(generated.seatInfo, fallback: heuristic.seatInfo, limit: 120)
        let code = prefer(generated.confirmationCode, fallback: heuristic.confirmationCode, limit: 32)
        merged.confirmationCode = code.lowercased().hasPrefix("http") ? heuristic.confirmationCode : code
        let note = prefer(generated.notes, fallback: heuristic.notes, limit: 280)
        merged.notes = note

        if let modelStart = parseDate(generated.startISO) {
            let modelHasTime = generated.startISO.contains("T") || generated.startISO.contains(":")
            if modelHasTime {
                merged.start = modelStart
                merged.startTimeIsAssumed = false
            } else if heuristic.start != nil {
                merged.start = heuristic.start
                merged.startTimeIsAssumed = heuristic.startTimeIsAssumed
            } else {
                merged.start = assumedEvening(on: modelStart)
                merged.startTimeIsAssumed = true
            }
        }

        if let modelEnd = parseDate(generated.endISO), generated.endISO.contains(":") || generated.endISO.contains("T") {
            merged.end = modelEnd
            merged.endIsAssumed = false
        }

        if let start = merged.start, let end = merged.end, end <= start {
            merged.end = start.addingTimeInterval(TicketDefaults.assumedDuration)
            merged.endIsAssumed = true
        } else if merged.end == nil, let start = merged.start {
            merged.end = start.addingTimeInterval(TicketDefaults.assumedDuration)
            merged.endIsAssumed = true
        }
        return merged
    }

    private static func draft(
        from parsed: ParsedTicket,
        scan: ScanResult,
        source: ExtractionSource,
        detail: String
    ) -> TicketDraft {
        var draft = TicketDraft()
        draft.title = parsed.title
        draft.location = parsed.location
        draft.start = parsed.start
        draft.end = parsed.end
        draft.startTimeIsAssumed = parsed.startTimeIsAssumed
        draft.endIsAssumed = parsed.endIsAssumed
        draft.organizer = parsed.organizer
        draft.seatInfo = parsed.seatInfo
        draft.confirmationCode = parsed.confirmationCode
        draft.notes = parsed.notes
        draft.barcodePayload = scan.barcodePayload
        draft.barcodeSymbology = scan.barcodeSymbology
        draft.extractionSource = source
        var parts = [detail]
        if let warning = scan.warning, !warning.isEmpty {
            parts.append(warning)
        }
        draft.extractionDetail = parts.joined(separator: " ")
        return draft
    }

    private static func prefer(_ modelValue: String, fallback: String, limit: Int) -> String {
        let cleaned = sanitize(modelValue)
        let chosen = cleaned.isEmpty ? fallback : cleaned
        if chosen.count <= limit { return chosen }
        return String(chosen.prefix(limit))
    }

    private static func sanitize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let placeholders: Set<String> = [
            "n/a", "na", "none", "unknown", "not found", "not present",
            "empty", "null", "-", "—", "n.a."
        ]
        if placeholders.contains(lowered) { return "" }
        return trimmed
    }

    private static func assumedEvening(on day: Date) -> Date? {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        components.hour = TicketDefaults.assumedStartHour
        components.minute = TicketDefaults.assumedStartMinute
        components.second = 0
        return Calendar.current.date(from: components)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}
