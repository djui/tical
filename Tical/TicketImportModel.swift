import EventKit
import UIKit

@MainActor
@Observable
final class TicketImportModel {
    enum Phase: Equatable {
        case ready
        case extracting
        case review
    }

    enum Notice: Identifiable {
        case message(String)
        case calendarDenied
        case calendarSaved

        var id: String {
            switch self {
            case .message(let text):
                return "message-\(text)"
            case .calendarDenied:
                return "calendar-denied"
            case .calendarSaved:
                return "calendar-saved"
            }
        }
    }

    var phase: Phase = .ready
    var draft: TicketDraft?
    var screenshot: UIImage?
    var barcodeImage: UIImage?
    var notice: Notice?
    var isSavingCalendar = false

    private var isImporting = false
    private var eventStore: EKEventStore?

    func importImageData(_ data: Data) async {
        guard !isImporting else { return }
        guard let preview = UIImage(data: data) else {
            notice = .message("Tical couldn't open that image.")
            return
        }

        isImporting = true
        screenshot = preview
        barcodeImage = nil
        draft = nil
        phase = .extracting

        let scan = await Task.detached(priority: .userInitiated) {
            VisionTicketScanner.scan(imageData: data)
        }.value
        let nextDraft = await TicketExtractionService.makeDraft(from: scan)
        draft = nextDraft
        if let jpeg = scan.barcodeImageJPEG {
            barcodeImage = UIImage(data: jpeg)
        }
        phase = .review
        isImporting = false
        await consumePendingImport()
    }

    func consumePendingImport() async {
        guard !isImporting else { return }
        guard let data = AppGroupImport.takePendingImageData() else { return }
        await importImageData(data)
    }

    func dismissReview() {
        phase = .ready
    }

    func addToCalendar() async {
        guard let draft, !isSavingCalendar else { return }
        if draft.start == nil {
            notice = .message("Add a start date before saving to Calendar.")
            return
        }
        isSavingCalendar = true
        defer { isSavingCalendar = false }
        do {
            try await CalendarService.add(draft, store: calendarStore())
            notice = .calendarSaved
        } catch let error as CalendarError {
            switch error {
            case .denied:
                notice = .calendarDenied
            default:
                notice = .message(error.localizedDescription)
            }
        } catch {
            notice = .message(error.localizedDescription)
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func copyBarcodePayload() {
        guard let payload = draft?.barcodePayload, !payload.isEmpty else { return }
        UIPasteboard.general.string = payload
        notice = .message("Copied the barcode payload.")
    }

    private func calendarStore() -> EKEventStore {
        if let eventStore { return eventStore }
        let store = EKEventStore()
        eventStore = store
        return store
    }
}
