import Foundation

struct ParsedTicket: Equatable {
    var title = ""
    var location = ""
    var start: Date?
    var end: Date?
    var startTimeIsAssumed = false
    var endIsAssumed = false
    var organizer = ""
    var seatInfo = ""
    var confirmationCode = ""
    var notes = ""
}

/// On-device fallback when the system language model is unavailable or fails.
/// Dates use `NSDataDetector` plus English and German label heuristics. No network.
enum HeuristicTicketParser {
    static func parse(lines: [RecognizedLine], barcodePayload: String) -> ParsedTicket {
        let ordered = lines.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > 0.015 {
                return lhs.midY > rhs.midY
            }
            return lhs.minX < rhs.minX
        }
        let texts = ordered
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var ticket = ParsedTicket()
        let schedule = extractSchedule(from: texts)
        ticket.start = schedule.start
        ticket.end = schedule.end
        ticket.startTimeIsAssumed = schedule.startTimeIsAssumed
        ticket.endIsAssumed = schedule.endIsAssumed
        ticket.notes = schedule.note
        ticket.seatInfo = extractSeat(from: texts)
        ticket.confirmationCode = extractConfirmation(from: texts, barcodePayload: barcodePayload)
        ticket.organizer = extractOrganizer(from: texts)
        ticket.location = extractLocation(from: texts, organizer: ticket.organizer)
        ticket.title = extractTitle(
            from: ordered,
            payload: barcodePayload,
            blocked: [ticket.location, ticket.organizer, ticket.seatInfo, ticket.confirmationCode]
        )

        if ticket.end == nil, let start = ticket.start {
            ticket.end = start.addingTimeInterval(TicketDefaults.assumedDuration)
            ticket.endIsAssumed = true
        }
        return ticket
    }

    // MARK: - Schedule

    private struct Schedule {
        var start: Date?
        var end: Date?
        var startTimeIsAssumed = false
        var endIsAssumed = false
        var note = ""
    }

    private enum ClockRole {
        case start
        case end
        case doors
        case unspecified
    }

    private static func extractSchedule(from lines: [String]) -> Schedule {
        let joined = lines.joined(separator: "\n")
        var day = firstCalendarDay(in: joined, lines: lines)
        var absoluteStart: Date?
        var absoluteEnd: Date?
        var startClock: (Int, Int)?
        var endClock: (Int, Int)?
        var doorsClock: (Int, Int)?

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = joined as NSString
            detector.enumerateMatches(in: joined, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, let date = match.date else { return }
                let snippet = ns.substring(with: match.range)
                let hasClock = containsClock(snippet)
                let hasDay = containsDay(snippet)
                if hasDay && hasClock {
                    if absoluteStart == nil {
                        absoluteStart = date
                    } else if absoluteEnd == nil, date > absoluteStart ?? date {
                        absoluteEnd = date
                    }
                } else if hasDay && day == nil {
                    day = date
                }
                if match.duration >= 60, match.duration < 18 * 60 * 60, absoluteEnd == nil {
                    absoluteEnd = date.addingTimeInterval(match.duration)
                }
            }
        }

        if day == nil {
            day = manualDay(in: lines)
        }

        for line in lines {
            let clocks = clocks(in: line)
            guard !clocks.isEmpty else { continue }
            let role = clockRole(for: line)
            if clocks.count >= 2 {
                switch role {
                case .doors:
                    if doorsClock == nil { doorsClock = clocks[0] }
                    if startClock == nil { startClock = clocks[1] }
                case .end:
                    if startClock == nil { startClock = clocks[0] }
                    if endClock == nil { endClock = clocks[1] }
                case .start, .unspecified:
                    if startClock == nil { startClock = clocks[0] }
                    if endClock == nil { endClock = clocks[1] }
                }
            } else if let clock = clocks.first {
                switch role {
                case .end:
                    if endClock == nil { endClock = clock }
                case .doors:
                    if doorsClock == nil { doorsClock = clock }
                case .start:
                    if startClock == nil { startClock = clock }
                case .unspecified:
                    if startClock == nil {
                        startClock = clock
                    } else if endClock == nil {
                        endClock = clock
                    }
                }
            }
        }

        var schedule = Schedule()
        if let absoluteStart {
            schedule.start = absoluteStart
        } else if let day, let startClock {
            schedule.start = compose(day: day, hour: startClock.0, minute: startClock.1)
        } else if let day, let doorsClock {
            schedule.start = compose(day: day, hour: doorsClock.0, minute: doorsClock.1)
            schedule.note = "The only time printed was labeled as doors or entry."
        } else if let day {
            schedule.start = compose(
                day: day,
                hour: TicketDefaults.assumedStartHour,
                minute: TicketDefaults.assumedStartMinute
            )
            schedule.startTimeIsAssumed = true
        }

        if let absoluteEnd {
            schedule.end = absoluteEnd
        } else if let day, let endClock, let start = schedule.start,
                  var end = compose(day: day, hour: endClock.0, minute: endClock.1) {
            if end <= start, let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: end) {
                end = nextDay
            }
            schedule.end = end
        }

        if let start = schedule.start, let end = schedule.end, end <= start {
            schedule.end = nil
        }
        return schedule
    }

    private static func firstCalendarDay(in joined: String, lines: [String]) -> Date? {
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = joined as NSString
            var found: Date?
            detector.enumerateMatches(in: joined, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, stop in
                guard let match, let date = match.date else { return }
                let snippet = ns.substring(with: match.range)
                if containsDay(snippet) {
                    found = date
                    stop.pointee = true
                }
            }
            if let found { return found }
        }
        return manualDay(in: lines)
    }

    private static func compose(day: Date, hour: Int, minute: Int) -> Date? {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.date(from: components)
    }

    private static func containsClock(_ text: String) -> Bool {
        text.range(
            of: #"(?i)\d{1,2}[:.]\d{2}|\d{1,2}\s*(am|pm|uhr)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func containsDay(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"\b\d{4}\b"#, options: .regularExpression) != nil,
           monthIndex(in: lower) != nil {
            return true
        }
        if monthIndex(in: lower) != nil,
           lower.range(of: #"\b\d{1,2}\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func clocks(in line: String) -> [(Int, Int)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\b(\d{1,2})[:.](\d{2})\s*(am|pm|uhr)?\b|\b(\d{1,2})\s*(am|pm|uhr)\b"#
        ) else { return [] }
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        var results: [(Int, Int)] = []
        for match in matches {
            let hourRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 4)
            guard hourRange.location != NSNotFound, let hour = Int(ns.substring(with: hourRange)) else { continue }
            var minute = 0
            if match.range(at: 2).location != NSNotFound {
                minute = Int(ns.substring(with: match.range(at: 2))) ?? 0
            }
            let markerRange = match.range(at: 3).location != NSNotFound ? match.range(at: 3) : match.range(at: 5)
            var marker = ""
            if markerRange.location != NSNotFound {
                marker = ns.substring(with: markerRange).lowercased()
            }
            guard var adjusted = adjust(hour: hour, minute: minute, marker: marker) else { continue }
            if marker != "am" && marker != "pm" && marker != "uhr" && matchLooksLikeDateFragment(match, in: ns) {
                continue
            }
            if marker == "pm" && adjusted.0 < 12 { adjusted.0 += 12 }
            if marker == "am" && adjusted.0 == 12 { adjusted.0 = 0 }
            results.append(adjusted)
        }
        return results
    }

    private static func matchLooksLikeDateFragment(_ match: NSTextCheckingResult, in text: NSString) -> Bool {
        let start = max(0, match.range.location - 2)
        let end = min(text.length, match.range.location + match.range.length + 6)
        let window = text.substring(with: NSRange(location: start, length: end - start))
        return window.range(of: #"\d{1,2}\.\d{1,2}\.\d{2,4}"#, options: .regularExpression) != nil
    }

    private static func adjust(hour: Int, minute: Int, marker: String) -> (Int, Int)? {
        guard (0...23).contains(hour) || ((1...12).contains(hour) && (marker == "am" || marker == "pm")) else {
            return nil
        }
        guard (0...59).contains(minute) else { return nil }
        if hour > 23 { return nil }
        if marker.isEmpty && hour > 23 { return nil }
        return (hour, minute)
    }

    private static func clockRole(for line: String) -> ClockRole {
        let lower = line.lowercased()
        if containsWord(lower, any: ["end", "ends", "until", "ende", "schluss"]) { return .end }
        if containsWord(lower, any: ["door", "doors", "einlass", "entry", "admission", "oeffnung", "öffnung"]) {
            return .doors
        }
        if containsWord(lower, any: ["start", "starts", "show", "beginn", "anfang", "begin"]) { return .start }
        return .unspecified
    }

    private static func manualDay(in lines: [String]) -> Date? {
        for line in lines {
            if let date = parseNamedMonth(line) ?? parseNumericDate(line) ?? parseISODate(line) {
                return date
            }
        }
        return nil
    }

    private static func parseISODate(_ text: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{4})-(\d{2})-(\d{2})\b"#) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let year = Int(ns.substring(with: match.range(at: 1))) ?? 0
        let month = Int(ns.substring(with: match.range(at: 2))) ?? 0
        let day = Int(ns.substring(with: match.range(at: 3))) ?? 0
        return makeDate(year: year, month: month, day: day)
    }

    private static func parseNumericDate(_ text: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2})([./])(\d{1,2})\2(\d{2,4})\b"#) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let first = Int(ns.substring(with: match.range(at: 1))) ?? 0
        let separator = ns.substring(with: match.range(at: 2))
        let second = Int(ns.substring(with: match.range(at: 3))) ?? 0
        var year = Int(ns.substring(with: match.range(at: 4))) ?? 0
        if year < 100 { year += 2000 }
        let dayFirst = separator == "." || !Locale.current.identifier.hasPrefix("en_US")
        let day = dayFirst ? first : second
        let month = dayFirst ? second : first
        return makeDate(year: year, month: month, day: day)
    }

    private static func parseNamedMonth(_ text: String) -> Date? {
        let lower = text.lowercased()
        guard let month = monthIndex(in: lower) else { return nil }
        let stripped = lower.replacingOccurrences(
            of: #"(?i)\d{1,2}[:.]\d{2}\s*(am|pm|uhr)?|\b\d{1,2}\s*(am|pm|uhr)\b"#,
            with: " ",
            options: .regularExpression
        )
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(\d{1,2})(?:st|nd|rd|th)?\b|\b(19|20)\d{2}\b"#
        ) else { return nil }
        let ns = stripped as NSString
        let matches = regex.matches(in: stripped, range: NSRange(location: 0, length: ns.length))
        var day: Int?
        var year: Int?
        for match in matches {
            let token = ns.substring(with: match.range)
            if token.count == 4, let value = Int(token) {
                year = value
            } else if day == nil, let value = Int(token.prefix { $0.isNumber }), (1...31).contains(value) {
                day = value
            }
        }
        guard let day else { return nil }
        let resolvedYear = year ?? inferredYear(month: month, day: day)
        return makeDate(year: resolvedYear, month: month, day: day)
    }

    private static func inferredYear(month: Int, day: Int) -> Int {
        let calendar = Calendar.current
        let today = Date()
        let year = calendar.component(.year, from: today)
        guard let candidate = makeDate(year: year, month: month, day: day) else { return year }
        if candidate < calendar.date(byAdding: .day, value: -2, to: today) ?? today {
            return year + 1
        }
        return year
    }

    private static func monthIndex(in lowercased: String) -> Int? {
        let months: [(String, Int)] = [
            ("september", 9), ("november", 11), ("december", 12), ("dezember", 12),
            ("january", 1), ("januar", 1), ("february", 2), ("februar", 2),
            ("october", 10), ("oktober", 10), ("august", 8), ("march", 3),
            ("märz", 3), ("marz", 3), ("april", 4), ("june", 6), ("juni", 6),
            ("july", 7), ("juli", 7), ("mai", 5), ("may", 5),
            ("sept", 9), ("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4),
            ("jun", 6), ("jul", 7), ("aug", 8), ("sep", 9), ("oct", 10),
            ("okt", 10), ("nov", 11), ("dec", 12), ("dez", 12)
        ]
        for (name, index) in months where containsWord(lowercased, any: [name]) {
            return index
        }
        return nil
    }

    private static func makeDate(year: Int, month: Int, day: Int) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar.current.date(from: components)
    }

    // MARK: - Fields

    private static func extractSeat(from lines: [String]) -> String {
        let blob = lines.joined(separator: "\n")
        let section = capture(#"(?i:\b(?:section|sektion|bereich|sektor|sec\.?))\b[ \t]*[:#]?[ \t]*([A-Za-z0-9][A-Za-z0-9\-]{0,10})"#, in: blob)
        let block = capture(#"(?i:\bblock)\b[ \t]*[:#]?[ \t]*([A-Za-z0-9][A-Za-z0-9\-]{0,10})"#, in: blob)
        let row = capture(#"(?i:\b(?:row|reihe))\b[ \t]*[:#]?[ \t]*([A-Za-z0-9]{1,6})"#, in: blob)
        let seat = capture(#"(?i:\b(?:seat|sitzplatz|sitz|platz))\b[ \t]*[:#]?[ \t]*([A-Za-z0-9]{1,6})"#, in: blob)
        let gate = capture(#"(?i:\b(?:gate|eingang|tor))\b[ \t]*[:#]?[ \t]*([A-Za-z0-9]{1,8})"#, in: blob)
        var parts: [String] = []
        if let section { parts.append("Section \(section)") }
        if let block { parts.append("Block \(block)") }
        if let row { parts.append("Row \(row)") }
        if let seat { parts.append("Seat \(seat)") }
        if let gate { parts.append("Gate \(gate)") }
        return parts.joined(separator: " · ")
    }

    private static func extractConfirmation(from lines: [String], barcodePayload: String) -> String {
        let blob = lines.joined(separator: "\n")
        let pattern = #"(?i:\b(?:confirmation(?:[ \t]+code)?|order(?:[ \t]+(?:code|id|number|no))?|booking(?:[ \t]+(?:code|ref|reference|id|number))?|reservation(?:[ \t]+code)?|bestell(?:nummer|nr\.?|code)?|buchungs(?:code|nummer|nr\.?)|ticket(?:[ \t]+(?:code|number|id)|nummer|nr\.?)|auftrags(?:nummer|nr\.?)|code))\b[ \t]*[:#]?[ \t]*([A-Za-z0-9][A-Za-z0-9\-]{3,31})"#
        if let value = capture(pattern, in: blob), acceptableCode(value, payload: barcodePayload) {
            return value
        }
        let labels = ["confirmation", "order", "booking", "bestellnummer", "bestellnr", "buchungscode", "buchungsnummer", "ticketnummer", "code"]
        for (index, line) in lines.enumerated() where index + 1 < lines.count {
            let lower = line.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if labels.contains(where: { lower == $0 || lower == "\($0):" }),
               acceptableCode(lines[index + 1], payload: barcodePayload),
               codeToken(lines[index + 1]) {
                return lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let payload = barcodePayload.trimmingCharacters(in: .whitespacesAndNewlines)
        if codeToken(payload), payload.count <= 20, payload.range(of: #"\d"#, options: .regularExpression) != nil {
            return payload
        }
        return ""
    }

    private static func acceptableCode(_ value: String, payload: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.count > 32 { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http") || lower.contains("www.") { return false }
        if !payload.isEmpty && trimmed == payload && payload.count > 20 { return false }
        return trimmed.range(of: #"\d"#, options: .regularExpression) != nil
    }

    private static func codeToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^[A-Za-z0-9][A-Za-z0-9\-]{4,31}$"#, options: .regularExpression) != nil
    }

    private static func extractOrganizer(from lines: [String]) -> String {
        let pattern = #"(?i:\b(?:presented by|organized by|organised by|veranstalter|organizer|promoter|host))\b[ \t]*[:\-]?[ \t]*(.+)$"#
        for line in lines {
            if let value = capture(pattern, in: line) {
                let cleaned = clip(value, limit: 80)
                if cleaned.count >= 2 { return cleaned }
            }
        }
        return ""
    }

    private static func extractLocation(from lines: [String], organizer: String) -> String {
        let labels = ["veranstaltungsort", "venue", "location", "address", "adresse", "spielort", "where", "ort"]
        if let labeled = valueAfterLabel(lines: lines, labels: labels) {
            return clip(labeled, limit: 120)
        }
        let keywords = [
            "arena", "stadium", "stadion", "theatre", "theater", "halle", "hall", "saal",
            "garden", "center", "centre", "zentrum", "philharmonie", "opera", "oper",
            "pavilion", "auditorium", "coliseum", "colosseum", "forum", "palace", "palais"
        ]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            if lower == organizer.lowercased() { continue }
            if isLabelOnly(trimmed) { continue }
            if keywords.contains(where: { containsWord(lower, any: [$0]) }) {
                return clip(trimmed, limit: 120)
            }
        }
        return ""
    }

    private static func extractTitle(
        from lines: [RecognizedLine],
        payload: String,
        blocked: [String]
    ) -> String {
        let blockedLower = Set(blocked.map { $0.lowercased() }.filter { !$0.isEmpty })
        let ranked = lines.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > 0.015 { return lhs.midY > rhs.midY }
            return lhs.minX < rhs.minX
        }
        func score(_ line: RecognizedLine, allowLocation: Bool) -> Double? {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count < 3 || text.count > 80 { return nil }
            if text == payload { return nil }
            if !allowLocation && blockedLower.contains(text.lowercased()) { return nil }
            if isLabelOnly(text) { return nil }
            if text.lowercased().hasPrefix("http") { return nil }
            if looksLikeSeatOrCodeLine(text) { return nil }
            if containsDay(text) && text.count < 40 { return nil }
            if containsClock(text) && text.count < 28 { return nil }
            if text.range(of: #"^\d+$"#, options: .regularExpression) != nil { return nil }
            return line.height * 12 + line.midY
        }
        let preferred = ranked.compactMap { line -> (RecognizedLine, Double)? in
            guard let value = score(line, allowLocation: false), value > 0 else { return nil }
            return (line, value)
        }
        let fallback = ranked.compactMap { line -> (RecognizedLine, Double)? in
            guard let value = score(line, allowLocation: true), value > 0 else { return nil }
            return (line, value)
        }
        guard let best = (preferred.max(by: { $0.1 < $1.1 }) ?? fallback.max(by: { $0.1 < $1.1 }))?.0 else {
            return ""
        }
        var title = best.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = ranked.firstIndex(of: best), index + 1 < ranked.count {
            let next = ranked[index + 1]
            let close = abs(best.midY - next.midY) < 0.045
            if close, score(next, allowLocation: false) != nil, next.text.count < 40 {
                title += " " + next.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return clip(title, limit: 140)
    }

    private static func looksLikeSeatOrCodeLine(_ text: String) -> Bool {
        let lower = text.lowercased()
        let seatWords = ["section", "sektion", "bereich", "sektor", "reihe", "row", "seat", "sitz", "platz", "block", "gate", "eingang"]
        let hits = seatWords.filter { containsWord(lower, any: [$0]) }
        let hasDigit = text.range(of: #"\d"#, options: .regularExpression) != nil
        if text.count < 48 && (hits.count >= 2 || (hits.count == 1 && hasDigit)) {
            return true
        }
        let codePattern = #"(?i:\b(?:confirmation|buchungscode|buchungsnummer|bestellnummer|ticketnummer|order|booking|code)\b)[ \t]*[:#]?[ \t]*([A-Za-z0-9][A-Za-z0-9\-]{3,})"#
        return capture(codePattern, in: text) != nil
    }

    private static func valueAfterLabel(lines: [String], labels: [String]) -> String? {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            for label in labels.sorted(by: { $0.count > $1.count }) {
                if lower == label {
                    guard index + 1 < lines.count else { return nil }
                    let next = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    return next.isEmpty ? nil : next
                }
                let prefix = label + ":"
                if lower.hasPrefix(prefix) {
                    let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    if rest.count >= 2 { return String(rest) }
                }
            }
        }
        return nil
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        let value = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func containsWord(_ text: String, any words: [String]) -> Bool {
        for word in words {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            if text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    private static func isLabelOnly(_ text: String) -> Bool {
        let labels: Set<String> = [
            "venue", "location", "date", "time", "start", "end", "doors", "seat", "row",
            "section", "gate", "order", "ticket", "confirmation", "name", "ort", "datum",
            "uhrzeit", "reihe", "platz", "block", "einlass", "beginn", "ende",
            "veranstaltungsort", "bestellnummer", "buchungscode", "address", "adresse"
        ]
        return labels.contains(text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func clip(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit))
    }
}
