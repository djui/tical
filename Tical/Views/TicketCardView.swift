import SwiftUI

/// Tical's ticket glyph as a SwiftUI shape.
struct TicketShape: Shape {
    var perforated = false

    nonisolated func path(in rect: CGRect) -> Path {
        Path(TicketGlyph.path(in: rect, perforated: perforated))
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
    let codeImage: UIImage?
    let codeCaption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    TicketShape(perforated: true)
                        .frame(width: 24, height: 15)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(logoText)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if let start = draft.start {
                    field("DATE", start.formatted(.dateTime.day().month(.abbreviated)), alignment: .trailing)
                }
            }

            field("EVENT", draft.displayTitle, font: .title2.weight(.bold), lineLimit: 3)

            HStack(alignment: .top, spacing: 16) {
                if let start = draft.start {
                    field(
                        draft.startTimeIsAssumed ? "DAY" : "STARTS",
                        draft.startTimeIsAssumed
                            ? start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
                            : start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    )
                }
                Spacer(minLength: 0)
                if !location.isEmpty {
                    field("VENUE", location, alignment: .trailing, lineLimit: 2)
                }
            }

            if !seat.isEmpty || !booking.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    if !seat.isEmpty {
                        field("SEAT", seat, lineLimit: 2)
                    }
                    Spacer(minLength: 0)
                    if !booking.isEmpty {
                        field("BOOKING", booking, alignment: .trailing, monospaced: true)
                    }
                }
            }

            if let codeImage {
                VStack(spacing: 6) {
                    Image(uiImage: codeImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 180, maxHeight: 180)
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
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .foregroundStyle(Color(color.foreground))
        .background {
            PassShape()
                .fill(Color(color).gradient)
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
        .animation(.smooth, value: color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wallet pass preview")
    }

    private var logoText: String {
        if !draft.organizer.isEmpty { return draft.organizer }
        if !location.isEmpty { return location }
        return String(localized: "Ticket")
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
}
