import SwiftUI

/// Tical's ticket glyph as a SwiftUI shape.
struct TicketShape: Shape {
    var perforated = false

    nonisolated func path(in rect: CGRect) -> Path {
        Path(TicketGlyph.path(in: rect, perforated: perforated))
    }
}

/// A pass symbol as a SwiftUI shape.
struct PassSymbolShape: Shape {
    var symbol: PassSymbol

    nonisolated func path(in rect: CGRect) -> Path {
        Path(symbol.path(in: rect))
    }
}

/// A Wallet event ticket's outline: rounded corners and a notch at the top.
struct PassShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        let corner: CGFloat = 18
        let notch: CGFloat = 16
        let outline = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        let cutout = CGPath(
            ellipseIn: CGRect(x: rect.midX - notch, y: rect.minY - notch, width: notch * 2, height: notch * 2),
            transform: nil
        )
        return Path(outline.subtracting(cutout))
    }
}

extension Color {
    init(_ color: RGBColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}

/// A live preview of the Wallet pass, updated as you edit.
struct TicketCardView: View {
    let draft: TicketDraft
    let color: RGBColor
    let symbol: PassSymbol
    let background: PassBackground?
    let codeImage: UIImage?
    let codeCaption: String?

    var body: some View {
        Group {
            if let background, background.style == .poster {
                poster(background.image)
            } else {
                ticket
            }
        }
        .foregroundStyle(Color(color.foreground))
        .animation(.smooth, value: color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wallet pass preview")
    }

    /// An event ticket, with the background photo blurred behind the details as Wallet does.
    private var ticket: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                logo
                Spacer(minLength: 12)
                if let start = draft.start {
                    // The same style as the pass, which Wallet formats for the region, like "17/10/2026" or "10/17/26".
                    field("DATE", DateFormatter.localizedString(from: start, dateStyle: .short, timeStyle: .none), alignment: .trailing)
                }
            }

            field("EVENT", draft.displayTitle, font: .title2.weight(.bold), lineLimit: 3)

            // Like Wallet, a row's first field sits on the left and its last on the right, each aligned to its leading edge.
            if startTime != nil || !location.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    if let startTime {
                        field("STARTS", startTime)
                        Spacer(minLength: 0)
                    }
                    if !location.isEmpty {
                        field("VENUE", location, lineLimit: 2)
                    }
                }
            }

            if !seat.isEmpty || !booking.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    if !seat.isEmpty {
                        field("SEAT", seat, lineLimit: 2)
                        Spacer(minLength: 0)
                    }
                    if !booking.isEmpty {
                        field("BOOKING", booking, monospaced: true)
                    }
                }
            }

            if let codeImage {
                code(codeImage, maxSize: 180)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .background {
            PassShape()
                .fill(Color(color).gradient)
                .overlay {
                    if let background {
                        Image(decorative: background.image, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 28, opaque: true)
                    }
                }
                .clipShape(PassShape())
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
    }

    /// A poster pass: the photo sharp and full size, the code on it, and the details on a strip
    /// along the bottom.
    private func poster(_ image: CGImage) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                logo
                Spacer(minLength: 12)
                if let start = draft.start {
                    field("DATE", DateFormatter.localizedString(from: start, dateStyle: .short, timeStyle: .none), alignment: .trailing, monospaced: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer(minLength: 16)

            if let codeImage {
                code(codeImage, maxSize: 120)
                    .padding(.bottom, -32)
                    .zIndex(1)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    posterField("Event", draft.displayTitle)
                    Spacer(minLength: 0)
                    if let startTime {
                        posterField("Starts", startTime, alignment: .trailing)
                    } else if !location.isEmpty {
                        posterField("Venue", location, alignment: .trailing)
                    }
                }
                if !posterFooter.isEmpty {
                    Text(posterFooter)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, codeImage == nil ? 14 : 44)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, color.prefersDarkText ? .light : .dark)
        }
        .aspectRatio(PassArtwork.artworkSize.width / PassArtwork.artworkSize.height, contentMode: .fit)
        .background {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
        }
        .clipShape(.rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    /// Wallet shows one footer line: the seat, or else the venue when the start time took its
    /// place above, or else the booking code.
    private var posterFooter: String {
        if !seat.isEmpty { return seat }
        if startTime != nil, !location.isEmpty { return location }
        return booking
    }

    private var logo: some View {
        HStack(spacing: 8) {
            PassSymbolShape(symbol: symbol)
                .frame(width: symbol.logoSize.width * 0.75, height: symbol.logoSize.height * 0.75)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(logoText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
    }

    private func code(_ image: UIImage, maxSize: CGFloat) -> some View {
        VStack(spacing: 6) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: maxSize, maxHeight: maxSize)
                .accessibilityLabel("Ticket code")
            if let codeCaption {
                Text(codeCaption)
                    .font(.caption.monospaced())
                    .foregroundStyle(.black.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .background(.white, in: .rect(cornerRadius: 10))
        .frame(maxWidth: .infinity)
    }

    private var logoText: String {
        if !draft.organizer.isEmpty { return draft.organizer }
        if !location.isEmpty { return location }
        return String(localized: "Ticket")
    }

    /// The start time, if the ticket gives one; the header shows the day.
    private var startTime: String? {
        guard let start = draft.start, !draft.startTimeIsAssumed else { return nil }
        return DateFormatter.localizedString(from: start, dateStyle: .none, timeStyle: .short)
    }

    private var location: String { draft.location.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var seat: String { draft.seatInfo.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var booking: String { draft.confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func field(
        _ label: LocalizedStringKey,
        _ value: String,
        alignment: HorizontalAlignment = .leading,
        font: Font = .body.weight(.medium),
        lineLimit: Int = 1,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(color.label))
            Text(value)
                .font(font)
                .monospaced(monospaced)
                .lineLimit(lineLimit)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
        }
    }

    private func posterField(_ label: LocalizedStringKey, _ value: String, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(Color(color.label))
            Text(value)
                .font(.callout.monospaced())
                .lineLimit(2)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
        }
    }
}
