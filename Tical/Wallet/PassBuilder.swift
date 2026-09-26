import Foundation
import UIKit

/// Everything on the pass, captured from the review screen.
nonisolated struct PassContent: Sendable {
    var draft: TicketDraft
    var barcode: WalletBarcode?
    /// With a background photo, the photo's color.
    var color: RGBColor
    var symbol: PassSymbol = .ticket
    var background: PassBackground?
    var serialNumber = UUID().uuidString
}

/// Builds and signs an event ticket pass on this iPhone.
nonisolated enum PassBuilder {
    static func archive(for content: PassContent, credentials: PassCredentials) throws -> Data {
        var files = PassArtwork.files(for: content)
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
            // The header shows the day, so this shows just the time, and only if the ticket gives one.
            if !draft.startTimeIsAssumed {
                secondary.append(field("starts", String(localized: "STARTS"), iso(start), dateStyle: "PKDateStyleNone", timeStyle: "PKDateStyleShort"))
            }
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

        if content.background?.style == .poster {
            // Wallet prefers the poster style where it has it and shows the event ticket elsewhere.
            // Below the photo, a poster has room for two primary fields and one footer line.
            // Posters write labels in title case, which Wallet also lists under the pass.
            var posterPrimary = [field("event", String(localized: "Event"), title)]
            var rest: [[String: Any]] = []
            let venue = location.isEmpty ? nil : field("venue", String(localized: "Venue"), location)
            if let start = draft.start, !draft.startTimeIsAssumed {
                posterPrimary.append(field("starts", String(localized: "Starts"), iso(start), dateStyle: "PKDateStyleNone", timeStyle: "PKDateStyleShort"))
                if let venue { rest.append(venue) }
            } else if let venue {
                posterPrimary.append(venue)
            }
            if !seat.isEmpty { rest.insert(field("seat", String(localized: "Seat"), seat), at: 0) }
            if !booking.isEmpty { rest.append(field("booking", String(localized: "Booking"), booking)) }
            pass["posterGeneric"] = [
                "headerFields": header,
                "primaryFields": posterPrimary,
                "footerFields": Array(rest.prefix(1)),
                // Shown in the Additional Info section under the pass.
                "additionalInfoFields": Array(rest.dropFirst()),
                "backFields": back,
            ]
        }

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

/// The images on a pass: the symbol as its logo and icon, and the background photo.
nonisolated enum PassArtwork {
    /// Wallet's sizes, in points.
    static let backgroundSize = CGSize(width: 343, height: 503)
    static let artworkSize = CGSize(width: 358, height: 448)

    static func files(for content: PassContent) -> [String: Data] {
        var files: [String: Data] = [:]
        for scale in 1...3 {
            let suffix = scale == 1 ? "" : "@\(scale)x"
            files["icon\(suffix).png"] = icon(content.symbol, color: content.color, scale: CGFloat(scale))
            files["logo\(suffix).png"] = logo(content.symbol, color: content.color.foreground, scale: CGFloat(scale))
        }
        guard let background = content.background else { return files }

        // Wallet blurs the background, which hides the difference to a 3x image.
        files["background.png"] = photo(background, size: backgroundSize, scale: 1)
        files["background@2x.png"] = photo(background, size: backgroundSize, scale: 2)
        if background.style == .poster {
            files["artwork@2x.png"] = photo(background, size: artworkSize, scale: 2)
            files["artwork@3x.png"] = photo(background, size: artworkSize, scale: 3)
            // Posters show `primaryLogo` where other passes show `logo`.
            for scale in 1...3 {
                let suffix = scale == 1 ? "" : "@\(scale)x"
                files["primaryLogo\(suffix).png"] = files["logo\(suffix).png"]
            }
        }
        return files
    }

    /// Shown in notifications and on the lock screen: the symbol on the pass color.
    private static func icon(_ symbol: PassSymbol, color: RGBColor, scale: CGFloat) -> Data {
        let size = CGSize(width: 38, height: 38)
        return render(size: size, scale: scale, opaque: true) { context in
            context.setFillColor(color.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            let side: CGFloat = symbol == .ticket ? 26 : 20
            context.addPath(symbol.path(in: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)))
            context.setFillColor(color.foreground.cgColor)
            context.fillPath()
        }
    }

    /// Shown at the top left of the pass, next to the logo text.
    private static func logo(_ symbol: PassSymbol, color: RGBColor, scale: CGFloat) -> Data {
        let glyph = symbol.logoSize
        let size = CGSize(width: glyph.width + 2, height: 26)
        return render(size: size, scale: scale, opaque: false) { context in
            context.addPath(symbol.path(in: CGRect(x: 1, y: (size.height - glyph.height) / 2, width: glyph.width, height: glyph.height)))
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
    }

    /// The photo, filling `size` and cropped to it around its center.
    private static func photo(_ background: PassBackground, size: CGSize, scale: CGFloat) -> Data {
        render(size: size, scale: scale, opaque: true) { _ in
            let image = background.image
            let fill = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
            let drawn = CGSize(width: CGFloat(image.width) * fill, height: CGFloat(image.height) * fill)
            UIImage(cgImage: image).draw(in: CGRect(
                x: (size.width - drawn.width) / 2,
                y: (size.height - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            ))
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

private extension RGBColor {
    nonisolated var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
