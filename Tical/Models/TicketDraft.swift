import Foundation

enum ExtractionSource: Equatable {
    case onDeviceModel
    case heuristic
}

struct TicketDraft: Equatable {
    var id = UUID()
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
    var barcodePayload = ""
    var barcodeSymbology = ""
    var extractionSource: ExtractionSource = .heuristic
    var extractionDetail = ""
}

enum TicketDefaults {
    /// Keep these three values identical in the share extension.
    static let appGroupID = "group.com.tical.app"
    static let pendingFilename = "pending-ticket.jpg"
    static let urlScheme = "tical"

    static let assumedDuration: TimeInterval = 2 * 60 * 60
    static let assumedStartHour = 19
    static let assumedStartMinute = 0
}
