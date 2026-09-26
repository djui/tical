import Foundation

/// The ticket fields you review and edit before adding the ticket to Calendar or Wallet.
nonisolated struct TicketDraft: Equatable, Sendable {
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

    /// The end Calendar and Wallet use: the printed end, or the start plus the default duration.
    var effectiveEnd: Date? {
        guard let start else { return nil }
        if let end, end > start { return end }
        return start.addingTimeInterval(TicketDefaults.assumedDuration)
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Ticket") : trimmed
    }
}

nonisolated enum TicketDefaults {
    /// Keep the App Group, inbox, and scheme identical in the share extension (`ShareHandoff`).
    static let appGroupID = "group.com.tical.app"
    static let inboxFolder = "Inbox"
    static let urlScheme = "tical"

    enum Keys {
        static let eventDurationMinutes = "eventDurationMinutes"
        static let dateOnlyStartMinutes = "dateOnlyStartMinutes"
    }

    static let defaultEventDurationMinutes = 120
    static let defaultDateOnlyStartMinutes = 19 * 60

    /// How long an event lasts when the ticket prints no end. Changed in Settings.
    static var assumedDuration: TimeInterval {
        TimeInterval(storedInt(Keys.eventDurationMinutes) ?? defaultEventDurationMinutes) * 60
    }

    /// The start time used when a ticket prints a date without a time. Changed in Settings.
    static var assumedStartHour: Int { dateOnlyStartMinutes / 60 }
    static var assumedStartMinute: Int { dateOnlyStartMinutes % 60 }

    private static var dateOnlyStartMinutes: Int {
        storedInt(Keys.dateOnlyStartMinutes) ?? defaultDateOnlyStartMinutes
    }

    private static func storedInt(_ key: String) -> Int? {
        UserDefaults.standard.object(forKey: key) as? Int
    }
}

/// A pass background color, stored as sRGB components from 0 to 1.
nonisolated struct RGBColor: Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    /// The Tical violet, used when the ticket has no usable color of its own.
    static let brand = RGBColor(red: 0.36, green: 0.27, blue: 0.86)

    static let presets: [RGBColor] = [
        .brand,
        RGBColor(red: 0.12, green: 0.14, blue: 0.20),
        RGBColor(red: 0.07, green: 0.36, blue: 0.62),
        RGBColor(red: 0.04, green: 0.45, blue: 0.40),
        RGBColor(red: 0.74, green: 0.22, blue: 0.20),
        RGBColor(red: 0.80, green: 0.40, blue: 0.08),
        RGBColor(red: 0.62, green: 0.16, blue: 0.45),
    ]

    /// WCAG relative luminance.
    var luminance: Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// Light backgrounds get dark text on the pass.
    var prefersDarkText: Bool { luminance > 0.4 }

    var foreground: RGBColor {
        prefersDarkText ? RGBColor(red: 0.08, green: 0.08, blue: 0.10) : RGBColor(red: 1, green: 1, blue: 1)
    }

    /// Field labels: the text color, pulled toward the background.
    var label: RGBColor {
        mixed(with: foreground, amount: 0.62)
    }

    /// The `rgb(r, g, b)` string pass.json uses.
    var passJSONValue: String {
        "rgb(\(Int((red * 255).rounded())), \(Int((green * 255).rounded())), \(Int((blue * 255).rounded())))"
    }

    func mixed(with other: RGBColor, amount: Double) -> RGBColor {
        RGBColor(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }
}
