import EventKit
import Foundation

enum CalendarError: LocalizedError {
    case missingStart
    case denied
    case noCalendar
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingStart:
            return "Add a start date before saving to Calendar."
        case .denied:
            return "Calendar access is off for Tical."
        case .noCalendar:
            return "This iPhone has no calendar that can take a new event."
        case .failed(let message):
            return message
        }
    }
}

@MainActor
enum CalendarService {
    static func add(_ draft: TicketDraft, store: EKEventStore) async throws {
        guard let start = draft.start else { throw CalendarError.missingStart }
        try await authorize(store)
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw CalendarError.noCalendar
        }

        var end = draft.end ?? start.addingTimeInterval(TicketDefaults.assumedDuration)
        if end <= start {
            end = start.addingTimeInterval(TicketDefaults.assumedDuration)
        }

        let event = EKEvent(eventStore: store)
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.title = title.isEmpty ? "Ticket" : title
        let location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        event.location = location.isEmpty ? nil : location
        event.startDate = start
        event.endDate = end
        event.timeZone = .current
        let noteText = notes(for: draft)
        event.notes = noteText.isEmpty ? nil : noteText
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw CalendarError.failed(error.localizedDescription)
        }
    }

    private static func authorize(_ store: EKEventStore) async throws {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .writeOnly, .authorized:
            return
        case .notDetermined:
            let granted = try await store.requestWriteOnlyAccessToEvents()
            if !granted { throw CalendarError.denied }
        case .denied, .restricted:
            throw CalendarError.denied
        @unknown default:
            let granted = try await store.requestWriteOnlyAccessToEvents()
            if !granted { throw CalendarError.denied }
        }
    }

    static func notes(for draft: TicketDraft) -> String {
        var lines: [String] = []
        let confirmation = draft.confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !confirmation.isEmpty {
            lines.append("Confirmation: \(confirmation)")
        }
        let seat = draft.seatInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seat.isEmpty {
            lines.append("Seat: \(seat)")
        }
        let organizer = draft.organizer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !organizer.isEmpty {
            lines.append("Organizer: \(organizer)")
        }
        let payload = draft.barcodePayload.trimmingCharacters(in: .whitespacesAndNewlines)
        if !payload.isEmpty,
           payload.count <= 80,
           !payload.contains("\n"),
           payload != confirmation {
            lines.append("Code: \(payload)")
        }
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append(notes)
        }
        return lines.joined(separator: "\n")
    }
}
