import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A ticket file from Photos, Files, drag and drop, or the pasteboard.
nonisolated struct TicketFile: Transferable {
    let input: ImportInput

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .pdf) { TicketFile(input: .pdf($0)) }
        DataRepresentation(importedContentType: .image) { TicketFile(input: .image($0)) }
    }
}

@Observable
final class AppModel {
    struct Notice: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    /// The ticket on the review screen.
    var activeImport: TicketImport?
    var notice: Notice?
    let signing = PassSigningStore()

    func open(_ input: ImportInput) {
        // Vision needs a moment first, which gives the language model time to load.
        TicketExtractionService.prewarm()
        let ticket = TicketImport()
        activeImport = ticket
        Task { await ticket.read(input) }
    }

    /// Picks up a ticket the share extension left in the App Group.
    func openInbox() {
        guard let input = AppGroupInbox.takeLatest() else { return }
        open(input)
    }

    func open(fileAt url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            open(ImportInput(data: data, contentType: UTType(filenameExtension: url.pathExtension)))
        } catch {
            show(String(localized: "Couldn't Open File"), String(localized: "Tical couldn't read that file."))
        }
    }

    func show(_ title: String, _ message: String) {
        notice = Notice(title: title, message: message)
    }
}
