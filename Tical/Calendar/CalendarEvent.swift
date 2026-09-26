import EventKit
import EventKitUI
import SwiftUI

enum CalendarEvent {
    /// A new, unsaved event for the system editor. The editor runs outside Tical, so Tical
    /// needs no calendar access and never sees your other events.
    static func make(from draft: TicketDraft, barcode: DetectedBarcode?, in store: EKEventStore) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = draft.displayTitle
        let location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        event.location = location.isEmpty ? nil : location
        let start = draft.start ?? nextFullHour()
        event.startDate = start
        event.endDate = draft.effectiveEnd ?? start.addingTimeInterval(TicketDefaults.assumedDuration)
        event.timeZone = .current
        let notes = notes(for: draft, barcode: barcode)
        event.notes = notes.isEmpty ? nil : notes
        return event
    }

    static func notes(for draft: TicketDraft, barcode: DetectedBarcode?) -> String {
        var lines: [String] = []
        let confirmation = draft.confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if !confirmation.isEmpty {
            lines.append(String(localized: "Booking: \(confirmation)"))
        }
        let seat = draft.seatInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seat.isEmpty {
            lines.append(String(localized: "Seat: \(seat)"))
        }
        let organizer = draft.organizer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !organizer.isEmpty {
            lines.append(String(localized: "Organizer: \(organizer)"))
        }
        if let payload = barcode?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !payload.isEmpty, payload.count <= 80, !payload.contains("\n"), payload != confirmation {
            lines.append(String(localized: "Code: \(payload)"))
        }
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            lines.append(notes)
        }
        return lines.joined(separator: "\n")
    }

    private static func nextFullHour() -> Date {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        return hour
    }
}

/// The system's event editor, filled in from the ticket.
struct EventEditorSheet: UIViewControllerRepresentable {
    let event: EKEvent
    let store: EKEventStore
    var onFinish: (EKEventEditViewAction) -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: (EKEventEditViewAction) -> Void

        init(onFinish: @escaping (EKEventEditViewAction) -> Void) {
            self.onFinish = onFinish
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onFinish(action)
        }
    }
}
