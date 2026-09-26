import CoreGraphics
import Foundation
import FoundationModels
import os

@Generable
nonisolated struct GeneratedTicket {
    @Guide(description: "The event, show, match, or trip name as printed. Not the date, venue, or ticket vendor. Empty if not printed.")
    var title: String

    @Guide(description: "Venue name, and the city or address if printed. Empty if not printed.")
    var location: String

    @Guide(description: "When the event starts, in local time, as yyyy-MM-dd'T'HH:mm. Use yyyy-MM-dd if only the day is printed. Prefer the show or kickoff time over doors or entry. Empty if no date is printed.")
    var start: String

    @Guide(description: "When the event ends, as yyyy-MM-dd'T'HH:mm, only if an end time is printed. Otherwise empty.")
    var end: String

    @Guide(description: "Doors, gates, or entry time as HH:mm if printed separately from the start. Otherwise empty.")
    var doors: String

    @Guide(description: "Organizer, promoter, or presenter. Empty if not printed.")
    var organizer: String

    @Guide(description: "Seat, row, section, block, entrance, or gate as a short phrase, for example \"Block C · Row 12 · Seat 7\". Empty if not printed.")
    var seat: String

    @Guide(description: "The short order, booking, or confirmation reference exactly as printed. Never a barcode payload or a URL. Empty if not printed.")
    var confirmationCode: String
}

nonisolated enum ExtractionMethod: Equatable, Sendable {
    case model(sawImage: Bool)
    case textParser(reason: String)

    var summary: String {
        switch self {
        case .model(true):
            String(localized: "Read on this iPhone with Apple Intelligence, which looked at the ticket and its text.")
        case .model(false):
            String(localized: "Read on this iPhone with Apple Intelligence.")
        case .textParser(let reason):
            reason
        }
    }
}

nonisolated struct ExtractionResult: Sendable {
    var draft: TicketDraft
    var method: ExtractionMethod
}

/// Turns the scan into ticket fields with the on-device language model, and falls back to
/// the local text parser when the model is unavailable, slow, or unsure.
nonisolated enum TicketExtractionService {
    private static let timeout: Duration = .seconds(20)

    struct TimedOut: Error {}

    /// Loads the model ahead of a likely import. Returns right away.
    static func prewarm() {
        Task.detached(priority: .utility) {
            guard case .available = SystemLanguageModel.default.availability else { return }
            LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions).prewarm()
        }
    }

    @concurrent
    static func extract(from scan: ScanResult, image: CGImage) async -> ExtractionResult {
        let parsed = HeuristicTicketParser.parse(lines: scan.lines, barcodePayload: scan.barcode?.text ?? "")
        if scan.isEmpty {
            return ExtractionResult(
                draft: draft(from: parsed),
                method: .textParser(reason: String(localized: "No text or code was found. You can type the details yourself."))
            )
        }
        if let reason = modelUnavailableReason() {
            return ExtractionResult(draft: draft(from: parsed), method: .textParser(reason: reason))
        }

        let model = SystemLanguageModel.default
        let canSeeImages = model.capabilities.contains(.vision)
        var attempts = [false]
        if canSeeImages { attempts.insert(true, at: 0) }
        for withImage in attempts {
            do {
                let generated = try await withTimeout(timeout) {
                    try await generate(from: scan, image: withImage ? image : nil)
                }
                let merged = merge(generated, into: parsed, scan: scan)
                return ExtractionResult(draft: draft(from: merged), method: .model(sawImage: withImage))
            } catch is TimedOut {
                // A model that doesn't answer won't answer a second request either.
                break
            } catch {
                // For example, a request with an image the model refused. Try the text alone.
                continue
            }
        }
        return ExtractionResult(
            draft: draft(from: parsed),
            method: .textParser(reason: String(localized: "Apple Intelligence couldn't read this ticket, so Tical used its text parser. Check the details."))
        )
    }

    // MARK: - Model

    private static let instructions = """
        You read event tickets: concerts, sports, theater, museums, cinema, trains, and flights. \
        Use only what the ticket shows. Never invent a venue, a time, a seat, or a code. \
        Return an empty string for anything the ticket doesn't show. Times are local to the event.
        """

    private static func modelUnavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return String(localized: "Read on this iPhone with Tical's text parser. This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Read on this iPhone with Tical's text parser. Turn on Apple Intelligence in Settings for better results.")
        case .unavailable(.modelNotReady):
            return String(localized: "Read on this iPhone with Tical's text parser. Apple Intelligence is still getting ready.")
        case .unavailable:
            return String(localized: "Read on this iPhone with Tical's text parser.")
        }
    }

    private static func generate(from scan: ScanResult, image: CGImage?) async throws -> GeneratedTicket {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        let today = Date().formatted(.iso8601.year().month().day())
        let text = recognizedText(scan)
        let barcode = scan.barcode.map { "\($0.symbology.displayName): \($0.displayPayload.prefix(300))" } ?? "none"
        let response = try await session.respond(
            generating: GeneratedTicket.self,
            options: GenerationOptions(samplingMode: .greedy)
        ) {
            "Today is \(today). If the ticket leaves out the year, pick the next upcoming date."
            if let image {
                "Here is the ticket:"
                Attachment(image).label("ticket")
            }
            "Text recognized on the ticket, from top to bottom:"
            text
            "Barcode, read separately: \(barcode)"
        }
        return response.content
    }

    private static func recognizedText(_ scan: ScanResult) -> String {
        let body = scan.orderedLines.prefix(80).map(\.text).joined(separator: "\n")
        if body.isEmpty { return "(no text recognized)" }
        return String(body.prefix(4000))
    }

    /// Returns the operation's result, or throws `TimedOut` once the duration passes.
    ///
    /// A task group can't do this: it waits for every child before returning, and a model
    /// request that hangs doesn't always stop when cancelled. This races the two instead and
    /// stops waiting for the loser.
    static func withTimeout<T: Sendable>(
        _ duration: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<T, Error>?>(initialState: nil)
        let finish = { @Sendable (result: Result<T, Error>) in
            let continuation = pending.withLock { state in
                defer { state = nil }
                return state
            }
            continuation?.resume(with: result)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.withLock { $0 = continuation }
            let work = Task {
                do {
                    finish(.success(try await operation()))
                } catch {
                    finish(.failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: duration)
                work.cancel()
                finish(.failure(TimedOut()))
            }
        }
    }

    // MARK: - Merging

    private static func merge(_ generated: GeneratedTicket, into parsed: ParsedTicket, scan: ScanResult) -> ParsedTicket {
        var merged = parsed
        merged.title = prefer(generated.title, over: parsed.title, limit: 140)
        merged.location = prefer(generated.location, over: parsed.location, limit: 120)
        merged.organizer = prefer(generated.organizer, over: parsed.organizer, limit: 80)
        merged.seatInfo = prefer(generated.seat, over: parsed.seatInfo, limit: 120)

        // The model sometimes invents references. Keep one only if it is printed somewhere.
        let code = clean(generated.confirmationCode)
        if !code.isEmpty, !code.lowercased().hasPrefix("http"), code.count <= 32, appears(code, in: scan) {
            merged.confirmationCode = code
        }

        if let start = parseDate(generated.start) {
            if hasClockTime(generated.start) {
                merged.start = start
                merged.startTimeIsAssumed = false
            } else if let parsedStart = parsed.start, Calendar.current.isDate(parsedStart, inSameDayAs: start) {
                // Same day; the parser may have found the time.
            } else {
                merged.start = compose(day: start, hour: TicketDefaults.assumedStartHour, minute: TicketDefaults.assumedStartMinute)
                merged.startTimeIsAssumed = true
            }
        }
        if let end = parseDate(generated.end), hasClockTime(generated.end) {
            merged.end = end
            merged.endIsAssumed = false
        }
        if let start = merged.start {
            if let end = merged.end, end > start {
                // keep
            } else {
                merged.end = start.addingTimeInterval(TicketDefaults.assumedDuration)
                merged.endIsAssumed = true
            }
        }

        let doors = clean(generated.doors)
        // The parser already notes the doors time when it finds one.
        if !doors.isEmpty, doors.count <= 12, parsed.notes.isEmpty {
            let line = String(localized: "Doors: \(doors)")
            merged.notes = merged.notes.isEmpty ? line : "\(line)\n\(merged.notes)"
        }
        return merged
    }

    private static func draft(from parsed: ParsedTicket) -> TicketDraft {
        TicketDraft(
            title: parsed.title,
            location: parsed.location,
            start: parsed.start,
            end: parsed.end,
            startTimeIsAssumed: parsed.startTimeIsAssumed,
            endIsAssumed: parsed.endIsAssumed,
            organizer: parsed.organizer,
            seatInfo: parsed.seatInfo,
            confirmationCode: parsed.confirmationCode,
            notes: parsed.notes
        )
    }

    private static func prefer(_ modelValue: String, over fallback: String, limit: Int) -> String {
        let cleaned = clean(modelValue)
        let chosen = cleaned.isEmpty ? fallback : cleaned
        return String(chosen.prefix(limit))
    }

    private static func clean(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders: Set<String> = ["n/a", "na", "none", "unknown", "not found", "not printed", "empty", "null", "-", "—", "n.a."]
        return placeholders.contains(trimmed.lowercased()) ? "" : trimmed
    }

    private static func appears(_ code: String, in scan: ScanResult) -> Bool {
        func normalized(_ text: String) -> String {
            text.uppercased().filter { $0.isLetter || $0.isNumber }
        }
        let needle = normalized(code)
        guard !needle.isEmpty else { return false }
        let haystack = normalized(scan.lines.map(\.text).joined(separator: " ") + " " + (scan.barcode?.text ?? ""))
        return haystack.contains(needle)
    }

    private static func hasClockTime(_ raw: String) -> Bool {
        raw.contains("T") || raw.contains(":")
    }

    private static func compose(day: Date, hour: Int, minute: Int) -> Date? {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)
    }

    private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return try? Date(trimmed, strategy: .iso8601)
    }
}
