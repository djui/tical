import Foundation
import UIKit

/// Everything on the pass, captured from the review screen.
nonisolated struct PassContent: Sendable {
    var draft: TicketDraft
    var barcode: WalletBarcode?
    var color: RGBColor
    var serialNumber = UUID().uuidString
}

/// Builds and signs an event ticket pass on this iPhone.
nonisolated enum PassBuilder {
    static func archive(for content: PassContent, credentials: PassCredentials) throws -> Data {
        var files = PassArtwork.files(foreground: content.color.foreground)
        files["pass.json"] = try passJSON(for: content, signing: credentials.signing)
        return try PassPackage(files: files).signedArchive(
            signer: credentials.signing.certificate,
            intermediates: credentials.signing.intermediates
        ) { try Keychain.sign($0, with: credentials.privateKey) }
    }

    static func passJSON(for content: PassContent, signing: SigningCertificate) throws -> Data {
        let draft = content.draft
        let title = draft.displayTitle
        let location = draft.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let organizer = draft.organizer.trimmingCharacters(in: .whitespacesAndNewlines)
        let seat = draft.seatInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        let booking = draft.confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)

        var pass: [String: Any] = [
            "formatVersion": 1,
            "passTypeIdentifier": signing.passTypeIdentifier,
            "teamIdentifier": signing.teamIdentifier,
            "serialNumber": content.serialNumber,
            "organizationName": organizer.isEmpty ? "Tical" : organizer,
            "description": String(localized: "Ticket for \(title)"),
            "logoText": organizer.isEmpty ? (location.isEmpty ? String(localized: "Ticket") : location) : organizer,
            "backgroundColor": content.color.passJSONValue,
            "foregroundColor": content.color.foreground.passJSONValue,
            "labelColor": content.color.label.passJSONValue,
        ]

        var header: [[String: Any]] = []
        let primary: [[String: Any]] = [field("event", String(localized: "EVENT"), title)]
        var secondary: [[String: Any]] = []
        var auxiliary: [[String: Any]] = []
        var back: [[String: Any]] = []

        if let start = draft.start {
            header.append(field("date", String(localized: "DATE"), iso(start), dateStyle: "PKDateStyleShort", timeStyle: "PKDateStyleNone"))
            secondary.append(field(
                "starts",
                draft.startTimeIsAssumed ? String(localized: "DAY") : String(localized: "STARTS"),
                iso(start),
                dateStyle: "PKDateStyleMedium",
                timeStyle: draft.startTimeIsAssumed ? "PKDateStyleNone" : "PKDateStyleShort"
            ))
            pass["relevantDate"] = iso(start)
            let expiry = draft.endIsAssumed ? start.addingTimeInterval(2 * 86_400) : (draft.effectiveEnd ?? start).addingTimeInterval(86_400)
            pass["expirationDate"] = iso(expiry)
        }
        if !location.isEmpty {
            secondary.append(field("venue", String(localized: "VENUE"), location))
        }
        if !seat.isEmpty {
            auxiliary.append(field("seat", String(localized: "SEAT"), seat))
        }
        if !booking.isEmpty {
            auxiliary.append(field("booking", String(localized: "BOOKING"), booking))
        }

        if let start = draft.start, let end = draft.effectiveEnd {
            let interval = DateIntervalFormatter()
            interval.dateStyle = .full
            interval.timeStyle = draft.startTimeIsAssumed ? .none : .short
            back.append(field("when", String(localized: "When"), interval.string(from: start, to: end)))
        }
        if !organizer.isEmpty { back.append(field("organizer", String(localized: "Organizer"), organizer)) }
        if !notes.isEmpty { back.append(field("notes", String(localized: "Notes"), notes)) }
        back.append(field(
            "about",
            String(localized: "About this pass"),
            String(localized: "Made with Tical from a ticket image. The code is a copy of the code on the original ticket; keep the original in case a venue needs it.")
        ))

        pass["eventTicket"] = [
            "headerFields": header,
            "primaryFields": primary,
            "secondaryFields": secondary,
            "auxiliaryFields": auxiliary,
            "backFields": back,
        ]

        if let barcode = content.barcode {
            var entry: [String: Any] = [
                "format": barcode.format.rawValue,
                "message": barcode.message,
                "messageEncoding": barcode.encoding.rawValue,
            ]
            if let altText = altText(for: barcode, booking: booking) {
                entry["altText"] = altText
            }
            pass["barcodes"] = [entry]
        }

        var semantics: [String: Any] = ["eventName": title]
        if !location.isEmpty { semantics["venueName"] = location }
        if let start = draft.start { semantics["eventStartDate"] = iso(start) }
        if let end = draft.effectiveEnd { semantics["eventEndDate"] = iso(end) }
        pass["semantics"] = semantics

        return try JSONSerialization.data(withJSONObject: pass, options: [.prettyPrinted, .sortedKeys])
    }

    private static func field(
        _ key: String,
        _ label: String,
        _ value: String,
        dateStyle: String? = nil,
        timeStyle: String? = nil
    ) -> [String: Any] {
        var field: [String: Any] = ["key": key, "label": label, "value": value]
        if let dateStyle { field["dateStyle"] = dateStyle }
        if let timeStyle { field["timeStyle"] = timeStyle }
        return field
    }

    private static func altText(for barcode: WalletBarcode, booking: String) -> String? {
        if !booking.isEmpty { return booking }
        let message = barcode.message
        let printable = message.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F }
        return printable && message.count <= 24 ? message : nil
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// The small images every pass carries, drawn with Tical's ticket glyph.
nonisolated enum PassArtwork {
    static func files(foreground: RGBColor) -> [String: Data] {
        var files: [String: Data] = [:]
        for scale in 1...3 {
            let suffix = scale == 1 ? "" : "@\(scale)x"
            files["icon\(suffix).png"] = icon(scale: CGFloat(scale))
            files["logo\(suffix).png"] = logo(color: foreground, scale: CGFloat(scale))
        }
        return files
    }

    /// Shown in notifications and on the lock screen.
    private static func icon(scale: CGFloat) -> Data {
        let size = CGSize(width: 29, height: 29)
        return render(size: size, scale: scale, opaque: true) { context in
            let colors = [
                UIColor(red: 0.54, green: 0.40, blue: 1.00, alpha: 1).cgColor,
                UIColor(red: 0.29, green: 0.19, blue: 0.84, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: -0.2)
            let glyph = CGRect(x: -10, y: -7, width: 20, height: 14)
            context.addPath(TicketGlyph.path(in: glyph))
            context.setFillColor(UIColor.white.cgColor)
            context.fillPath()
        }
    }

    /// Shown at the top left of the pass, next to the logo text.
    private static func logo(color: RGBColor, scale: CGFloat) -> Data {
        let size = CGSize(width: 34, height: 26)
        return render(size: size, scale: scale, opaque: false) { context in
            context.addPath(TicketGlyph.path(in: CGRect(x: 1, y: 4, width: 32, height: 20), perforated: true))
            context.setFillColor(UIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1).cgColor)
            context.fillPath()
        }
    }

    private static func render(size: CGSize, scale: CGFloat, opaque: Bool, draw: (CGContext) -> Void) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            draw(context.cgContext)
        }
    }
}

/// Tical's ticket: a rounded rectangle with a notch in each short side.
nonisolated enum TicketGlyph {
    static func path(in rect: CGRect, perforated: Bool = false) -> CGPath {
        let corner = min(rect.width, rect.height) * 0.18
        let notch = rect.height * 0.16
        let outline = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let cutouts = CGMutablePath()
        for x in [rect.minX, rect.maxX] {
            cutouts.addEllipse(in: CGRect(x: x - notch, y: rect.midY - notch, width: notch * 2, height: notch * 2))
        }
        if perforated {
            let holes = 5
            let radius = rect.height * 0.045
            let x = rect.minX + rect.width * 0.68
            for index in 0..<holes {
                let y = rect.minY + rect.height * (CGFloat(index) + 0.5) / CGFloat(holes)
                cutouts.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
        }
        return outline.subtracting(cutouts)
    }
}
